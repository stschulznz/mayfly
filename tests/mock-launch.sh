#!/bin/bash
# MOCK ONLY: no QEMU, KVM, native cloud tool, socket, network or VM is used.
set -euo pipefail
set +x
umask 077
mode=$1
evidence=$2
project=$3
profile=$4
source "$project/lib/policy.sh"
source "$project/lib/host.sh"
source "$project/lib/runtime.sh"
mf_native() { :; }
mf_base_check() { :; }
mf_host_snapshot() { :; }
mf_check_host_snapshot() { :; }
mf_wait_gateway_socket() { sleep .1; }
qemu-img() {
    [[ $mode != image-failure ]] || return 1
    local last
    for last; do :; done
    printf 'MOCK overlay\n' | dd of="$last" status=none
}
mf_make_seed() {
    printf 'MOCK seed\n' | dd of="$1" status=none
}
prlimit() {
    local role=browser duration=30 pid=$BASHPID
    [[ " $* " != *' mayfly-gateway '* ]] || role=gateway
    printf '%s\n' "$pid" | dd of="$evidence/$role.pid" status=none
    # Record only nonsecret path/command shape, never profile contents.
    printf '%s\n' "$*" | dd of="$evidence/$role.args" status=none
    [[ $mode != "$role-first" ]] || duration=.4
    exec sleep "$duration"
}
mf_launch /mock/bases "$profile" "$evidence" "$project"
