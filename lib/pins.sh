#!/bin/bash
# Verified download of the two pinned artifacts, then a new pins file.
# Same checks as DEPLOYMENT.md step 2. Fetched text is data only: it is
# matched against strict patterns and never executed or sourced.

# Tor Browser Developers primary signing key, as published by Tor's
# signature-verification instructions. Keep identical to lib/build.sh.
MF_TOR_FPR=EF6E286DDA85EA2A4BA7DE684E2C6E8793298290
MF_DEBIAN_INDEX=https://cloud.debian.org/images/cloud/trixie/
MF_TOR_JSON=https://aus1.torproject.org/torbrowser/update_3/release/downloads.json
MF_DEBIAN_VER_RE='^[0-9]{8}-[0-9]{1,9}$'
MF_TOR_VER_RE='^[0-9]+(\.[0-9]+)+$'

mf_pins_valid_debian() { [[ ${1:-} =~ $MF_DEBIAN_VER_RE ]]; }
mf_pins_valid_tor() { [[ ${1:-} =~ $MF_TOR_VER_RE && ${#1} -le 24 ]]; }

# stdin: Debian autoindex HTML. stdout: the highest DATE-BUILD directory name.
# Only href="DATE-BUILD/" links qualify; anything else is ignored.
mf_pins_parse_debian_index() {
    local best
    best=$(grep -oE 'href="[0-9]{8}-[0-9]{1,9}/"' | sed -E 's/^href="//; s,/"$,,' |
        sort -u | sort -t- -k1,1n -k2,2n | tail -n 1) || return 1
    mf_pins_valid_debian "$best" || return 1
    printf '%s\n' "$best"
}

# stdin: Tor downloads.json. stdout: the stable version. The linux-x86_64
# archive URL in the same document must agree with that version.
mf_pins_parse_tor_json() {
    local json version binary
    json=$(head -c 1048576) || return 1
    version=$(jq -er 'if (.version | type) == "string" then .version else empty end' <<< "$json" 2>/dev/null) || return 1
    mf_pins_valid_tor "$version" || return 1
    binary=$(jq -er '.downloads["linux-x86_64"].ALL.binary | select(type == "string")' <<< "$json" 2>/dev/null) || return 1
    [[ $binary == "https://dist.torproject.org/torbrowser/$version/tor-browser-linux-x86_64-$version.tar.xz" ]] ||
        return 1
    printf '%s\n' "$version"
}

mf_stdin_is_tty() { [[ -t 0 ]]; }

mf_pins_confirm() {
    local answer=''
    mf_stdin_is_tty ||
        { mf_error 'fetch-pins needs a terminal to confirm; rerun with --yes to accept the versions shown'; return 1; }
    printf 'Continue? [y/N] ' >&2
    IFS= read -r answer || answer=''
    [[ $answer == y || $answer == Y || $answer == yes ]]
}

# mf_fetch_pins [--yes] [--debian DATE-BUILD] [--tor X.Y.Z] [PINS-FILE]
mf_fetch_pins() (
    set -euo pipefail
    umask 077
    local yes=0 debian='' tor='' pins='' state parent work='' created=0 ok=0
    local image archive image_dir tor_url expected actual image_sha tor_sha
    fail() { mf_error "fetch-pins: $1" || :; exit 1; }
    while (( $# )); do
        case $1 in
            --yes) yes=1; shift ;;
            --debian)
                (( $# >= 2 )) && mf_pins_valid_debian "$2" || fail '--debian needs DATE-BUILD such as 20260101-1234'
                debian=$2; shift 2 ;;
            --tor)
                (( $# >= 2 )) && mf_pins_valid_tor "$2" || fail '--tor needs a numeric stable version such as 15.0.1'
                tor=$2; shift 2 ;;
            -*) fail "unknown option $1" ;;
            *) [[ -z $pins ]] || fail 'only one pins file may be given'
                pins=$1; shift ;;
        esac
    done
    mf_tools curl gpg gpgv jq awk sha256sum sha512sum mktemp || exit 1
    state=$(mf_state_init create) || exit 1
    [[ -n $pins ]] || pins=$(mf_state_pins_file "$state")
    [[ $pins == /* ]] || fail 'the pins file path must be absolute'
    parent=${pins%/*}
    mf_path "$parent" && [[ $(stat -c %u -- "$parent") == "$UID" ]] ||
        fail 'the pins directory must exist, be yours and contain no symlinks'
    [[ ! -e $pins && ! -L $pins ]] ||
        fail "$pins already exists; keep it with its provenance or delete it to fetch again"
    work=$(mktemp -d "$state/downloads/verified.XXXXXXXX") || fail 'could not create a download directory'
    cleanup() {
        if (( ok != 1 )); then
            (( created == 1 )) && rm -f -- "$pins"
            [[ $work == "$state"/downloads/verified.* ]] && rm -rf --one-file-system -- "$work"
        fi
        return 0
    }
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM HUP
    cd -- "$work" || fail 'could not enter the download directory'
    if [[ -z $debian ]]; then
        mf_fetch "$MF_DEBIAN_INDEX" index.html || fail 'could not download the Debian image index'
        debian=$(head -c 1048576 index.html | mf_pins_parse_debian_index) ||
            fail 'no valid DATE-BUILD directory found in the Debian index'
    fi
    if [[ -z $tor ]]; then
        mf_fetch "$MF_TOR_JSON" downloads.json || fail 'could not download the Tor Browser version list'
        tor=$(mf_pins_parse_tor_json < downloads.json) ||
            fail 'no valid stable Tor Browser version found (alpha, rc and malformed values are refused)'
    fi
    mf_pins_valid_debian "$debian" && mf_pins_valid_tor "$tor" || fail 'a discovered version failed validation'
    image=debian-13-generic-amd64-$debian.qcow2
    archive=tor-browser-linux-x86_64-$tor.tar.xz
    image_dir=https://cloud.debian.org/images/cloud/trixie/$debian
    tor_url=https://dist.torproject.org/torbrowser/$tor/$archive
    printf '%s\n' \
        'Mayfly will download and verify:' \
        "  Debian image:   $image_dir/$image" \
        "  Debian sums:    $image_dir/SHA512SUMS" \
        "  Tor Browser:    $tor_url" \
        "  Tor signature:  $tor_url.asc" \
        "  Tor signing key fingerprint (pinned): $MF_TOR_FPR" \
        '                  fetched from https://keys.openpgp.org and compared to that fingerprint' \
        'Debian publishes no detached signature for these images. Trust here is HTTPS plus' \
        "Debian's published SHA512SUMS, not signed provenance. Tor Browser is verified" \
        'against the pinned Tor signing key. The downloads expose your IP address to the mirror hosts.' \
        'Versions are chosen automatically from upstream. If you need to guard against a downgrade,' \
        'compare them with the official download pages first. --yes skips this review.'
    if (( yes != 1 )); then
        mf_pins_confirm || fail 'not confirmed; nothing was downloaded or written'
    fi
    mf_fetch "$image_dir/$image" "$image" || fail 'Debian image download failed'
    mf_fetch "$image_dir/SHA512SUMS" SHA512SUMS || fail 'Debian SHA512SUMS download failed'
    expected=$(awk -v name="$image" '
        NF == 2 && ($2 == name || $2 == "*" name) {count++; digest=$1}
        END {if (count != 1) exit 1; print digest}' SHA512SUMS) ||
        fail 'SHA512SUMS does not list the image exactly once'
    [[ $expected =~ ^[a-fA-F0-9]{128}$ ]] || fail 'SHA512SUMS entry is not a SHA-512 digest'
    printf '%s  %s\n' "$expected" "$image" | sha512sum --check --strict - >/dev/null ||
        fail 'Debian SHA-512 check failed'
    printf '%s\n' 'ok: Debian image matches the published SHA512SUMS'
    mf_fetch "$tor_url" "$archive" || fail 'Tor Browser download failed'
    mf_fetch "$tor_url.asc" "$archive.asc" || fail 'Tor Browser signature download failed'
    mkdir -m 700 gnupg || fail 'could not create the key directory'
    mf_fetch "https://keys.openpgp.org/vks/v1/by-fingerprint/$MF_TOR_FPR" tor-key.asc ||
        fail 'Tor signing key download failed'
    gpg --batch --homedir gnupg --import tor-key.asc >/dev/null 2>&1 || fail 'Tor signing key import failed'
    actual=$(gpg --batch --homedir gnupg --with-colons --fingerprint "$MF_TOR_FPR" |
        awk -F: '$1 == "fpr" {print $10; exit}') || fail 'Tor signing key lookup failed'
    [[ $actual == "$MF_TOR_FPR" ]] || fail 'Tor signing key fingerprint mismatch'
    gpg --batch --homedir gnupg --output "$work/tor-keyring.gpg" --export "$MF_TOR_FPR" ||
        fail 'Tor signing key export failed'
    gpgv --homedir gnupg --keyring "$work/tor-keyring.gpg" "$archive.asc" "$archive" >/dev/null 2>&1 ||
        fail 'Tor Browser signature check failed'
    printf '%s\n' 'ok: Tor Browser signature verified against the pinned key'
    image_sha=$(sha256sum -- "$image") || fail 'could not hash the image'; image_sha=${image_sha%% *}
    tor_sha=$(sha256sum -- "$archive") || fail 'could not hash the archive'; tor_sha=${tor_sha%% *}
    (set -o noclobber
        printf 'IMAGE_URL=%s\nIMAGE_SHA256=%s\nTOR_URL=%s\nTOR_SHA256=%s\n' \
            "$image_dir/$image" "$image_sha" "$tor_url" "$tor_sha" > "$pins") ||
        fail 'could not create the pins file'
    created=1
    chmod 600 -- "$pins" || fail 'could not set the pins file mode'
    mf_build_config "$pins" || fail 'the written pins file failed validation and was removed'
    ok=1
    printf 'Verified at %s in %s\nPins written: %s\n' "$(date -u +%FT%TZ)" "$work" "$pins"
)
