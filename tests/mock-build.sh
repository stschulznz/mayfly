#!/bin/bash
# MOCK build orchestration only. No downloads, GPG verification, appliance or VM.
# Real digest checks are used on fixed nonsecret mock bytes.
set -euo pipefail
umask 077
mode=$1 evidence=$2 project=$3
source "$project/lib/policy.sh"
source "$project/lib/runtime.sh"
source "$project/lib/build.sh"
event() {
    printf '%s\n' "$*" | dd of="$evidence/events" oflag=append conv=notrunc status=none
}
mf_tools() { :; }
mf_fetch() {
    event fetch "$1"
    printf 'MOCK verified bytes\n' | dd of="$2" status=none
}
qemu-img() {
    event qemu-img "$@"
    case $1 in
        info) printf '%s\n' '{"format":"qcow2","virtual-size":3221225472}' ;;
        create) printf 'MOCK image\n' | dd of="$5" status=none ;;
        convert) printf 'MOCK image\n' | dd of="$7" status=none ;;
        *) return 1 ;;
    esac
}
jq() { cat >/dev/null; } # MOCK metadata acceptance, not qcow2 validation.
gpg() {
    event gpg "$@"
    if [[ " $* " == *' --with-colons '* ]]; then
        printf '%s\n' 'fpr:::::::::EF6E286DDA85EA2A4BA7DE684E2C6E8793298290:'
    elif [[ " $* " == *' --export '* ]]; then
        printf 'MOCK public keyring\n'
    fi
}
gpgv() {
    event gpgv "$@"
    [[ $mode != signature-failure ]]
}
virt-resize() { event virt-resize "$@"; }
virt-customize() { event virt-customize "$@"; }
hash=$(printf 'MOCK verified bytes\n' | sha256sum); hash=${hash%% *}
if [[ $mode == digest-failure ]]; then
    hash=1111111111111111111111111111111111111111111111111111111111111111
fi
sed -E "s/^(IMAGE_SHA256|TOR_SHA256)=.*/\\1=$hash/" \
    "$project/tests/fixtures/synthetic.pins" |
    dd of="$evidence/build.pins" status=none
mf_build "$evidence/build.pins" "$evidence/bases" "$project" "$project"
