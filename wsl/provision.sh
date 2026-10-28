#!/bin/bash
# Runs ONLY in the temporary build distro "mayfly-build", as root, from
# mayfly.ps1 setup. $1 is the Mayfly source directory as the distro sees it.
# The distro is exported afterwards as the checksummed base rootfs.
set -euo pipefail
umask 022
export LC_ALL=C DEBIAN_FRONTEND=noninteractive
src=${1:?source directory required}
lib=/usr/local/lib/mayfly

apt-get update -qq
apt-get install -y -qq --no-install-recommends \
    firefox-esr i2pd nftables bubblewrap wireguard-tools wireguard-go \
    iproute2 util-linux procps jq curl ca-certificates fonts-dejavu-core gnupg gpgv xz-utils

id -u browser >/dev/null 2>&1 || useradd --uid 1000 --create-home --shell /bin/bash browser
[[ $(id -u browser) == 1000 ]]
passwd -l browser >/dev/null

# Shared files are copied, never edited; CR is stripped in case of a CRLF checkout.
install -d -m 755 "$lib"
# Install one repo file into the distro, stripping CR from a CRLF checkout.
copy() { tr -d '\r' < "$src/$1" | dd of="$lib/${1##*/}" status=none; chmod "$2" "$lib/${1##*/}"; }
copy lib/policy.sh 644
copy wsl/netpolicy.sh 644
copy wsl/preflight.sh 644
copy wsl/entry-i2p.sh 644
copy wsl/session.sh 700
copy guest/i2pd.conf 644
copy guest/i2p-tunnels.conf 644
copy guest/i2p-user.js 644

# Firefox hardening: the same policy file and merge function the Linux build uses.
# The function is read out of guest/browser-prepare.sh, which runs only in the VM build.
source <(tr -d '\r' < "$src/guest/browser-prepare.sh" | sed -n '/^mf_browser_update_policies() {/,/^}/p')
declare -F mf_browser_update_policies >/dev/null
jq -e . "$src/guest/firefox-policies.json" >/dev/null
install -d -m 755 /etc/firefox/policies
tr -d '\r' < "$src/guest/firefox-policies.json" | dd of=/etc/firefox/policies/policies.json status=none
chmod 644 /etc/firefox/policies/policies.json
mf_browser_update_policies /etc/firefox/policies/policies.json
# Tor Browser, verified the way lib/pins.sh and lib/build.sh do: the version comes from
# Tor's list through mf_pins_parse_tor_json, and the archive must verify against the
# pinned signing key fingerprint (MF_TOR_FPR). Those pieces are read from the Linux files.
source <(tr -d '\r' < "$src/lib/policy.sh")
source <(tr -d '\r' < "$src/lib/pins.sh")
source <(tr -d '\r' < "$src/lib/build.sh" | sed -n '/^mf_fetch() {/,/^}/p')
declare -F mf_fetch mf_pins_parse_tor_json >/dev/null
work=$(mktemp -d)
mf_fetch "$MF_TOR_JSON" "$work/downloads.json"
tor=$(mf_pins_parse_tor_json < "$work/downloads.json")
archive=tor-browser-linux-x86_64-$tor.tar.xz
url=https://dist.torproject.org/torbrowser/$tor/$archive
mf_fetch "$url" "$work/$archive"
mf_fetch "$url.asc" "$work/$archive.asc"
mkdir -m 700 "$work/gnupg"
mf_fetch "https://keys.openpgp.org/vks/v1/by-fingerprint/$MF_TOR_FPR" "$work/tor-key.asc"
gpg --batch --homedir "$work/gnupg" --import "$work/tor-key.asc" 2>/dev/null
[[ $(gpg --batch --homedir "$work/gnupg" --with-colons --fingerprint "$MF_TOR_FPR" |
    awk -F: '$1=="fpr" {print $10; exit}') == "$MF_TOR_FPR" ]]
gpg --batch --homedir "$work/gnupg" --export "$MF_TOR_FPR" | dd of="$work/tor-keyring.gpg" status=none
gpgv --homedir "$work/gnupg" --keyring "$work/tor-keyring.gpg" "$work/$archive.asc" "$work/$archive" 2>/dev/null
printf 'ok: Tor Browser %s verified against the pinned signing key (sha256 %s)\n' "$tor" \
    "$(sha256sum "$work/$archive" | cut -d' ' -f1)"
tar --extract --xz --file "$work/$archive" --directory /opt --no-same-owner
test -f /opt/tor-browser/Browser/start-tor-browser
chown -R browser:browser /opt/tor-browser
chown root:root /opt/tor-browser /opt/tor-browser/Browser
chmod 755 /opt/tor-browser /opt/tor-browser/Browser
mf_browser_update_policies /opt/tor-browser/Browser/distribution/policies.json
printf '%s\n' "$tor" | dd of="$lib/tor-version" status=none
rm -rf -- "$work"
# The router is started by the I2P entry only, as the browser user, in the sandbox.
install -d -m 755 /etc/systemd/system
ln -sf /dev/null /etc/systemd/system/i2pd.service

# No Windows drives, no Windows programs, no generated resolv.conf. The session
# bind-mounts its own over the empty file.
printf '%s\n' '[automount]' 'enabled=false' 'mountFsTab=false' \
    '[interop]' 'enabled=false' 'appendWindowsPath=false' \
    '[boot]' 'systemd=false' \
    '[network]' 'generateResolvConf=false' \
    '[user]' 'default=root' | dd of=/etc/wsl.conf status=none

for tool in gpgv xz firefox-esr i2pd nft bwrap wg wireguard-go jq curl setpriv nsenter flock; do
    command -v "$tool" >/dev/null
done
[[ -f $lib/session.sh && -f /etc/firefox/policies/policies.json ]]

apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/* /root/.bash_history
rm -f /etc/resolv.conf
: > /etc/resolv.conf
printf 'provisioned\n'
