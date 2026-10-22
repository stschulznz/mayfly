#!/bin/bash
# Run preflight and the offline suite inside distrobox containers.
# Usage: tests/distro/matrix.sh [container...]   (default: mayfly-test-*)
# Only containers whose names start with "mayfly-test-" are ever entered.
set -uo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
(( $# )) || set -- mayfly-test-debian mayfly-test-ubuntu mayfly-test-fedora mayfly-test-arch mayfly-test-opensuse
rc=0
for c in "$@"; do
    [[ $c == mayfly-test-* ]] || { printf 'refusing %s: not a mayfly-test container\n' "$c" >&2; exit 2; }
    printf '\n===== %s =====\n' "$c"
    distrobox enter -n "$c" -- bash -c '
        cd "$1" || exit 1
        . /etc/os-release; printf "%s %s\n" "$PRETTY_NAME" "$(uname -r)"
        out=$(bash mayfly.sh preflight 2>&1); pre=$?
        printf "%s\n" "$out" | grep -E "MISSING|WARNING|Install|^  sudo" 
        if (( pre != 0 )) && [[ ${MATRIX_INSTALL:-0} == 1 ]]; then
            cmd=$(printf "%s\n" "$out" | sed -n "/^Install the missing/{n;p}" | sed "s/^ *//; s/ *#.*//")
            printf "installing: %s\n" "$cmd"
            case $cmd in "sudo "*) $cmd -y >/dev/null 2>&1 || $cmd >/dev/null 2>&1 ;; esac
            out=$(bash mayfly.sh preflight 2>&1); pre=$?
            printf "%s\n" "$out" | grep -E "MISSING|WARNING"
        fi
        printf "preflight exit: %s\n" "$pre"
        bash tests/run.sh 2>&1 | grep -v "^ok" | tail -15
        exit "${PIPESTATUS[0]}"
    ' _ "$root" || rc=1
done
exit "$rc"
