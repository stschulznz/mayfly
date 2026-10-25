#!/bin/bash
# Native rootless two-VM build and disposable session CLI.
set +x
set -euo pipefail
export LC_ALL=C
umask 077
ulimit -S -c 0
ulimit -H -c 0

project=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
source "$project/lib/policy.sh"
source "$project/lib/host.sh"
source "$project/lib/runtime.sh"
source "$project/lib/attach.sh"
source "$project/lib/build.sh"
source "$project/lib/preflight.sh"
source "$project/lib/state.sh"
source "$project/lib/pins.sh"
source "$project/lib/corepolicy.sh"
root=$(git -C "$project" rev-parse --show-toplevel 2>/dev/null) || root=$project

usage() {
    printf '%s\n' \
        'First run: mayfly preflight, then mayfly setup, then mayfly launch.' \
        'Usage: bash mayfly.sh preflight' \
        '       bash mayfly.sh setup [--core-policy] [--yes]' \
        '       bash mayfly.sh fetch-pins [--yes] [--debian DATE-BUILD] [--tor X.Y.Z] [PINS-FILE]' \
        '       bash mayfly.sh build [PINS-FILE] [NAME | NEW-BASE-DIRECTORY]' \
        '       bash mayfly.sh launch [--attach FILE] [--core-policy] [NAME]' \
        '       bash mayfly.sh check-profile [--core-policy] [PROFILE-FILE]' \
        '       bash mayfly.sh core-policy apply|restore|status' \
        '       bash mayfly.sh doctor ABSOLUTE-RAM-DIRECTORY' \
        '       bash mayfly.sh launch [--attach FILE] [--core-policy] BASE-DIRECTORY PROFILE-FILE [RAM-PARENT]' \
        'Defaults live in the state directory: MAYFLY_HOME, else $XDG_STATE_HOME/mayfly,' \
        'else ~/.local/state/mayfly (pins/build.pins, secrets/wireguard.conf, bases/NAME).' \
        'launch uses the newest base. build names a new base base-YYYYMMDD and never overwrites.' \
        'PINS-FILE, BASE-DIRECTORY and PROFILE-FILE given in full must be absolute paths.' \
        '--core-policy applies the host core-dump policy if needed (uses sudo, host-wide) and' \
        'restores it on exit only when this command applied it and no QEMU process runs.' \
        'RAM-PARENT defaults to /dev/shm. A private 0700 session subdirectory is created.' \
        '--attach FILE gives the browser VM one read-only text file (1 byte to 1 MiB, no NUL bytes,' \
        'owned by you) as a disk; open file:///mnt/transfer/NAME in the guest. One way, needs a rebuilt base.' \
        'Build pins: IMAGE_URL, IMAGE_SHA256, TOR_URL, TOR_SHA256 (literal key=value).' \
        'fetch-pins verifies the Debian image against Debian'\''s published SHA512SUMS (Debian' \
        'publishes no detached signature) and Tor Browser against Tor'\''s pinned signing key.' \
        'Build uses internet but no VPN keys. Launch never downloads or installs.' \
        'Native QEMU >=8 (GTK, user/stream networking), KVM, qemu-img, an ISO tool (genisoimage, mkisofs or xorriso), jq, awk and prlimit required.' \
        'Build additionally needs virt-customize, virt-resize, curl, gpg and gpgv.' \
        'No Flatpak qualification. Installing packages and any reboot are your own actions.'
}

(( $# > 0 )) || { usage; exit 64; }
case $1 in
    preflight)
        (( $# == 1 )) || { usage; exit 64; }
        mf_preflight ;;
    doctor)
        (( $# == 2 )) || { usage; exit 64; }
        failed=0
        if mf_host_snapshot "$2"; then
            mf_check_host_snapshot || failed=1
        else
            failed=1
        fi
        mf_native || failed=1
        printf '%s\n' \
            'Doctor checks prerequisites only, never live routing or full operational readiness.' \
            'No install, host reconfiguration, VM startup or reboot attempted.' >&2
        (( failed == 0 )) || exit 78 ;;
    check-profile)
        shift
        mf_cmd_check_profile "$@" ;;
    build)
        shift
        mf_cmd_build "$@" ;;
    launch)
        shift
        mf_cmd_launch "$@" ;;
    setup)
        shift
        for arg in "$@"; do
            [[ $arg == --core-policy || $arg == --yes ]] || { usage; exit 64; }
        done
        mf_setup "$@" ;;
    fetch-pins)
        shift
        mf_fetch_pins "$@" ;;
    core-policy)
        shift
        (( $# == 1 )) && [[ $1 == apply || $1 == restore || $1 == status ]] || { usage; exit 64; }
        mf_core_cmd "$1" ;;
    *) usage; exit 64 ;;
esac
