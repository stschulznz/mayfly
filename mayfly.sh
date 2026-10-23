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
source "$project/lib/build.sh"
source "$project/lib/preflight.sh"
root=$(git -C "$project" rev-parse --show-toplevel 2>/dev/null) || root=$project

usage() {
    printf '%s\n' \
        'Usage: bash mayfly.sh preflight' \
        '       bash mayfly.sh doctor ABSOLUTE-RAM-DIRECTORY' \
        '       bash mayfly.sh check-profile ABSOLUTE-PROFILE-FILE' \
        '       bash mayfly.sh build ABSOLUTE-PINS-FILE NEW-BASE-DIRECTORY' \
        '       bash mayfly.sh launch BASE-DIRECTORY PROFILE-FILE [RAM-PARENT]' \
        'RAM-PARENT defaults to /dev/shm. A private 0700 session subdirectory is created.' \
        'Build pins: IMAGE_URL, IMAGE_SHA256, TOR_URL, TOR_SHA256 (literal key=value).' \
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
        (( $# == 2 )) || { usage; exit 64; }
        mf_profile_dump_guard
        mf_open_profile "$2" "$root"
        mf_parse_profile <&"$MF_PROFILE_FD"
        exec {MF_PROFILE_FD}<&-
        printf '%s\n' 'Profile syntax accepted. No keys printed, VM started or live route verified.' ;;
    build)
        (( $# == 3 )) || { usage; exit 64; }
        [[ $2 == /* && $3 == /* ]] || { usage; exit 64; }
        mf_build "$2" "$3" "$project" "$root" ;;
    launch)
        (( $# == 3 || $# == 4 )) || { usage; exit 64; }
        [[ $2 == /* && $3 == /* && ${4:-/dev/shm} == /* ]] || { usage; exit 64; }
        printf '%s\n' 'Mayfly: until every session ends, do not hibernate, do not restore the core-dump policy, and close other work.' >&2
        mf_launch "$2" "$3" "${4:-/dev/shm}" "$root" ;;
    *) usage; exit 64 ;;
esac
