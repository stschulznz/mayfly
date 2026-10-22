#!/bin/bash
# Explicit maintenance phase. Internet permitted, never accepts a VPN profile.

mf_build_config() {
    local file=$1 line key value
    declare -gA MF_BUILD=()
    mf_path "$file" || return 1
    [[ -f $file && $(stat -c %s "$file") -le 4096 ]] || return 1
    while IFS= read -r line || [[ -n $line ]]; do
        [[ -z $line || $line == \#* ]] && continue
        [[ $line == *=* ]] || { mf_error 'invalid build pin record'; return 1; }
        key=${line%%=*}; value=${line#*=}
        case $key in IMAGE_URL|IMAGE_SHA256|TOR_URL|TOR_SHA256) ;;
            *) mf_error 'unknown build pin field'; return 1 ;; esac
        [[ ! ${MF_BUILD[$key]+set} ]] ||
            { mf_error 'duplicate build pin field'; return 1; }
        case $key in
            IMAGE_URL)
                [[ $value =~ ^https://cloud\.debian\.org/images/cloud/trixie/[0-9][0-9A-Za-z/-]*/debian-13-generic-amd64-[0-9A-Za-z.-]+\.qcow2$ ]] ||
                    { mf_error 'require versioned official Debian 13 generic amd64 cloud image URL (full kernel for desktop)'; return 1; } ;;
            TOR_URL)
                [[ $value =~ ^https://dist\.torproject\.org/torbrowser/[0-9][0-9.]+/tor-browser-linux-x86_64-[0-9][0-9.]+\.tar\.xz$ ]] ||
                    { mf_error 'require versioned official stable Tor Browser Linux x86_64 URL'; return 1; } ;;
            *_SHA256)
                [[ $value =~ ^[a-f0-9]{64}$ ]] ||
                    { mf_error 'SHA256 pins must be 64 lowercase hex digits'; return 1; } ;;
        esac
        MF_BUILD[$key]=$value
    done < "$file"
    for key in IMAGE_URL IMAGE_SHA256 TOR_URL TOR_SHA256; do
        [[ ${MF_BUILD[$key]:-} ]] || { mf_error 'missing build pin field'; return 1; }
    done
}

mf_fetch() {
    # HTTPS only, including redirects (mirrors); no remote shell. Content is
    # accepted only after the pinned SHA-256 or signature check by the caller.
    curl --fail --silent --show-error --location --max-redirs 3 \
        --proto '=https' --proto-redir '=https' --tlsv1.2 \
        --max-time 1800 --output "$2" "$1"
}

mf_digest() {
    local hash
    hash=$(sha256sum -- "$1"); hash=${hash%% *}
    [[ $hash == "$2" ]] || { mf_error 'download digest mismatch'; return 1; }
}

mf_customize_args() {
    local image=$1 work=$2 project=$3
    MF_CUSTOMIZE=(
        --format qcow2 -a "$image" --network
        --install cloud-init,nftables,wireguard-tools,iproute2,kmod
        --mkdir /usr/local/lib/mayfly
        --upload "$project/lib/policy.sh:/usr/local/lib/mayfly/policy.sh"
        --upload "$project/guest/network.sh:/usr/local/lib/mayfly/network.sh"
        --upload "$project/guest/diag.sh:/usr/local/lib/mayfly/diag.sh"
        --upload "$project/guest/prepare.sh:/usr/local/lib/mayfly/prepare.sh"
        --upload "$project/guest/mayfly.service:/etc/systemd/system/mayfly.service"
        --run-command 'bash /usr/local/lib/mayfly/prepare.sh'
        --delete /root/.ssh --delete '/etc/ssh/ssh_host_*'
    )
    # work is retained in the signature for offline command-construction tests.
    [[ -n $work ]]
}

mf_build() (
    set -euo pipefail
    local config=$1 out=$2 project=$3 root=$4 parent name work role hash fpr
    mf_tools qemu-img virt-customize virt-resize curl gpg gpgv jq tar
    mf_build_config "$config"
    [[ $out =~ ^/[A-Za-z0-9_./-]+$ && ! -e $out && ! -L $out ]] ||
        { mf_error 'build destination must be a new absolute directory'; return 1; }
    parent=${out%/*}; name=${out##*/}
    mf_path "$parent"
    [[ -n $name && $name != . && $name != .. && $out != "$root/"* &&
       $(stat -c %u "$parent") == "$UID" && $(stat -c %a "$parent") == 700 ]] ||
        { mf_error 'build destination needs a private owned parent outside repository'; return 1; }
    # Never overwrite a previous build. Failure intentionally retains partial
    # nonsecret build artifacts; absent final hashes prevent session use.
    mkdir -m 700 -- "$out"
    work=$out/build
    mkdir -m 700 -- "$work" "$work/gnupg"
    export LIBGUESTFS_BACKEND=direct
    export TMPDIR=$work
    mf_fetch "${MF_BUILD[IMAGE_URL]}" "$work/debian.qcow2"
    mf_digest "$work/debian.qcow2" "${MF_BUILD[IMAGE_SHA256]}"
    qemu-img info --output=json -f qcow2 "$work/debian.qcow2" |
        jq -e '.format == "qcow2" and .["backing-filename"] == null
            and .["data-file"] == null
            and .["format-specific"].data["data-file"] == null
            and .["virtual-size"] <= 17179869184' >/dev/null
    mf_fetch "${MF_BUILD[TOR_URL]}" "$work/tor.tar.xz"
    mf_digest "$work/tor.tar.xz" "${MF_BUILD[TOR_SHA256]}"
    mf_fetch "${MF_BUILD[TOR_URL]}.asc" "$work/tor.tar.xz.asc"
    # Tor Browser Developers primary fingerprint, independently published by
    # Tor's signature-verification instructions. Subkeys must chain to it.
    fpr=EF6E286DDA85EA2A4BA7DE684E2C6E8793298290
    mf_fetch "https://keys.openpgp.org/vks/v1/by-fingerprint/$fpr" "$work/tor-key.asc"
    gpg --batch --homedir "$work/gnupg" --import "$work/tor-key.asc"
    [[ $(gpg --batch --homedir "$work/gnupg" --with-colons --fingerprint "$fpr" |
        awk -F: '$1=="fpr" {print $10; exit}') == "$fpr" ]] ||
        { mf_error 'Tor signing fingerprint mismatch'; return 1; }
    gpg --batch --homedir "$work/gnupg" --export "$fpr" |
        dd of="$work/tor-keyring.gpg" status=none
    gpgv --homedir "$work/gnupg" --keyring "$work/tor-keyring.gpg" \
        "$work/tor.tar.xz.asc" "$work/tor.tar.xz"
    # Debian generic cloud image: full kernel, BIOS boot, root /dev/sda1.
    qemu-img create -q -f qcow2 "$out/gateway.qcow2" 16G
    virt-resize --format qcow2 --output-format qcow2 --expand /dev/sda1 \
        "$work/debian.qcow2" "$out/gateway.qcow2"
    mf_customize_args "$out/gateway.qcow2" "$work" "$project"
    virt-customize "${MF_CUSTOMIZE[@]}"
    qemu-img convert -f qcow2 -O qcow2 "$out/gateway.qcow2" "$out/browser.qcow2"
    virt-customize --format qcow2 -a "$out/browser.qcow2" --network \
        --install xorg,lightdm,openbox,firefox-esr,zenity,dbus-x11,sudo,jq,libgtk-3-0t64,libasound2t64,libdbus-glib-1-2,libnss3,libxtst6,libpci3,fonts-liberation,i2pd,curl \
        --upload "$work/tor.tar.xz:/tmp/tor.tar.xz" \
        --upload "$project/guest/desktop.sh:/usr/local/lib/mayfly/desktop.sh" \
        --upload "$project/guest/browser-prepare.sh:/tmp/browser-prepare.sh" \
        --upload "$project/guest/firefox-policies.json:/tmp/firefox-policies.json" \
        --upload "$project/guest/i2pd.conf:/tmp/i2pd.conf" \
        --upload "$project/guest/i2p-tunnels.conf:/tmp/i2p-tunnels.conf" \
        --upload "$project/guest/i2p-user.js:/tmp/i2p-user.js" \
        --run-command 'bash /tmp/browser-prepare.sh' \
        --run-command 'dpkg-query -W firefox-esr i2pd' \
        --delete /tmp/browser-prepare.sh --delete /tmp/tor.tar.xz \
        --delete /tmp/firefox-policies.json --delete /tmp/i2pd.conf \
        --delete /tmp/i2p-tunnels.conf --delete /tmp/i2p-user.js
    # Publish hashes LAST, only after every maintenance step succeeds.
    for role in gateway browser; do
        chmod 444 "$out/$role.qcow2"
        hash=$(sha256sum "$out/$role.qcow2"); hash=${hash%% *}
        printf '%s\n' "$hash" | dd of="$out/$role.sha256" status=none
        chmod 400 "$out/$role.sha256"
    done
    printf '%s\n' 'Build finished. Bases pinned read-only; live route acceptance still required.' \
        'Nonsecret download/build cache retained in destination/build; never used by sessions.'
)
