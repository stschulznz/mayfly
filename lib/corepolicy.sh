#!/bin/bash
# Opt-in, host-wide core-dump policy: apply, restore, status and a guard that
# restores on exit only what this process applied. See DEPLOYMENT.md step 9.
# The saved baseline is data and is never sourced or evaluated.

MF_CORE_OURS=0
MF_REMINDER='Mayfly: until every session ends, do not hibernate, do not restore the core-dump policy, and close other work.'

mf_core_value() {
    mf_read_state "${MF_PROC_SYS:-/proc/sys}/$1"
}

# The requirement doctor, check-profile and launch enforce for the host.
mf_core_satisfied() {
    local pattern suid
    pattern=$(mf_core_value kernel/core_pattern)
    suid=$(mf_core_value fs/suid_dumpable)
    [[ -n $pattern && $pattern != unknown && $pattern != \|* && $suid == 0 ]]
}

mf_core_sysctl() {
    if (( EUID == 0 )); then
        sysctl "$@"
    else
        sudo sysctl "$@"
    fi
}

mf_core_can_escalate() {
    (( EUID == 0 )) && return 0
    command -v sudo >/dev/null 2>&1 ||
        { mf_error 'sudo is not available, so nothing was changed. Run as root: sysctl -w kernel.core_pattern=/dev/null fs.suid_dumpable=0'; return 1; }
}

# 0 when a QEMU process exists or the check itself failed (fail closed).
mf_core_sessions_running() {
    local rc=0
    pgrep -f '[q]emu-system-' >/dev/null 2>&1 || rc=$?
    (( rc != 1 ))
}

# Prepare <state>/core-policy/<boot_id> (0700, ours) and print the snapshot path.
mf_core_snapshot_path() (
    set -euo pipefail
    umask 077
    local base boot dir
    if [[ -n ${MF_CORE_STATE:-} ]]; then
        base=$MF_CORE_STATE
    else
        base=$(mf_state_init create) || exit 1
    fi
    boot=$(mf_read_state "${MF_PROC_SYS:-/proc/sys}/kernel/random/boot_id")
    [[ $boot =~ ^[0-9a-f-]{36}$ ]] || { mf_error 'cannot read a valid boot id'; exit 1; }
    for dir in "$base/core-policy" "$base/core-policy/$boot"; do
        if [[ ! -e $dir && ! -L $dir ]]; then
            mkdir -m 700 -- "$dir" || exit 1
        fi
        [[ -d $dir && ! -L $dir && $(stat -c '%u:%a' -- "$dir") == "$EUID:700" ]] ||
            { mf_error 'core-policy directory has the wrong type, owner or mode'; exit 1; }
    done
    printf '%s\n' "$base/core-policy/$boot/original.conf"
)

# Create the per-boot snapshot once. An existing snapshot is kept untouched.
mf_core_snapshot_ensure() {
    local file=$1 pattern suid
    [[ ! -e $file && ! -L $file ]] && {
        pattern=$(mf_core_value kernel/core_pattern)
        suid=$(mf_core_value fs/suid_dumpable)
        [[ -n $pattern && $pattern != unknown && $pattern != *[[:cntrl:]]* && $suid =~ ^[012]$ ]] ||
            { mf_error 'cannot read the current core-dump settings'; return 1; }
        (set -o noclobber
            printf 'kernel.core_pattern=%s\nfs.suid_dumpable=%s\n' "$pattern" "$suid" > "$file") ||
            { mf_error 'could not create the core-policy snapshot'; return 1; }
        chmod 600 -- "$file"
    }
    return 0
}

# Validate the snapshot as data and load MF_CORE_ORIG_PATTERN / MF_CORE_ORIG_SUID.
mf_core_snapshot_read() {
    local file=$1
    local -a original
    [[ -f $file && ! -L $file && $(stat -c '%u:%a:%h' -- "$file") == "$EUID:600:1" ]] ||
        { mf_error 'no valid core-policy snapshot for this boot; nothing to restore'; return 1; }
    mapfile -t original < "$file"
    [[ ${#original[@]} == 2 && ${original[0]} == kernel.core_pattern=?* &&
       ${original[1]} =~ ^fs\.suid_dumpable=[012]$ ]] ||
        { mf_error 'core-policy snapshot is malformed'; return 1; }
    MF_CORE_ORIG_PATTERN=${original[0]#kernel.core_pattern=}
    MF_CORE_ORIG_SUID=${original[1]#fs.suid_dumpable=}
}

mf_core_stat_info() { stat -c '%u %a' -- "$1"; }
# Owner a trusted file must have. A function, not a variable, so the
# environment cannot change it.
mf_core_trusted_owner() { printf '%s\n' 0; }

# True when the path and every ancestor are owned by the trusted owner and
# have no group or world write bit.
mf_core_path_trusted() {
    local path=$1 owner mode
    while :; do
        read -r owner mode < <(mf_core_stat_info "$path") || return 1
        [[ $owner == "$(mf_core_trusted_owner)" && $mode =~ ^[0-7]{3,4}$ ]] || return 1
        (( (8#$mode & 8#022) == 0 )) || return 1
        [[ $path == / ]] && return 0
        path=${path%/*}
        [[ -n $path ]] || path=/
    done
}

# Non-root restores hand the value to sudo, so a user-writable snapshot must
# never be able to make the kernel run something of the user's as root. A pipe
# pattern is accepted only for a known crash collector, found at a root-owned
# executable behind root-owned, non-writable directories, whose arguments are
# only core specifiers (%P), short options glued to a specifier (-p%p) and a
# bare "--". Interpreters such as env, bash or python3 are never collectors.
# Plain patterns use a conservative character set.
[[ -v MF_CORE_COLLECTORS ]] || readonly -a MF_CORE_COLLECTORS=(systemd-coredump apport abrt-hook-ccpp)

mf_core_collector_known() {
    local name
    for name in "${MF_CORE_COLLECTORS[@]}"; do
        [[ $1 == "$name" ]] && return 0
    done
    return 1
}

mf_core_pattern_safe() {
    local pattern=$1 rest helper token
    local -a tokens
    if [[ $pattern == \|* ]]; then
        rest=${pattern#|}
        [[ $rest =~ ^[^\ ]+(\ [^\ ]+)*$ && $rest =~ ^[A-Za-z0-9_./%+:@=,\ -]+$ ]] || return 1
        read -r -a tokens <<< "$rest"
        helper=${tokens[0]}
        [[ $helper =~ ^/[A-Za-z0-9_./+-]+$ ]] || return 1
        mf_core_collector_known "${helper##*/}" || return 1
        for token in "${tokens[@]:1}"; do
            [[ $token =~ ^(%[A-Za-z%]|-[A-Za-z]%[A-Za-z]|--)$ ]] || return 1
        done
        [[ $(realpath -e -- "$helper" 2>/dev/null) == "$helper" && -f $helper && -x $helper ]] || return 1
        mf_core_path_trusted "$helper"
    else
        [[ $pattern =~ ^[A-Za-z0-9_./%+:@=,-]+$ ]]
    fi
}

mf_core_values_show() {
    printf 'kernel.core_pattern = %s\nfs.suid_dumpable = %s\n' \
        "$(mf_core_value kernel/core_pattern)" "$(mf_core_value fs/suid_dumpable)"
}

mf_core_apply() {
    local file
    if mf_core_satisfied; then
        printf '%s\n' 'Core-dump policy already satisfies Mayfly. Nothing changed.'
        return 0
    fi
    mf_core_can_escalate || return 1
    file=$(mf_core_snapshot_path) || return 1
    mf_core_snapshot_ensure "$file" || return 1
    if (( EUID != 0 )); then
        printf '%s\n' 'Mayfly will now run sudo to set kernel.core_pattern=/dev/null and fs.suid_dumpable=0.' \
            'This changes crash-dump behaviour for the whole host and will be undone when the session ends.'
    fi
    MF_CORE_OURS=1
    mf_core_sysctl -w kernel.core_pattern=/dev/null fs.suid_dumpable=0 ||
        { mf_error 'sysctl failed; if only one value changed, run: mayfly core-policy restore'; return 1; }
    mf_core_satisfied ||
        { mf_error 'the core-dump policy is not in effect after sysctl; do not start a VM'; return 1; }
    mf_core_values_show
    printf '%s\n' "$MF_REMINDER" >&2
}

mf_core_restore() {
    local file
    file=$(mf_core_snapshot_path) || return 1
    mf_core_snapshot_read "$file" || return 1
    if mf_core_sessions_running; then
        mf_error 'a QEMU process exists or inspection failed; not restoring the core-dump policy'
        return 1
    fi
    if [[ $(mf_core_value kernel/core_pattern) == "$MF_CORE_ORIG_PATTERN" &&
          $(mf_core_value fs/suid_dumpable) == "$MF_CORE_ORIG_SUID" ]]; then
        printf '%s\n' 'Core-dump settings already match the saved values.'
        return 0
    fi
    mf_core_can_escalate || return 1
    if (( EUID != 0 )) && ! mf_core_pattern_safe "$MF_CORE_ORIG_PATTERN"; then
        mf_error 'the saved core_pattern is not a trusted value, so it will not be passed to sudo. Run: sudo mayfly core-policy restore (dedicated-user install), or restore your original values by hand with sysctl -w'
        return 1
    fi
    # Only the validated in-memory values reach sysctl, never the file.
    mf_core_sysctl -w "kernel.core_pattern=$MF_CORE_ORIG_PATTERN" "fs.suid_dumpable=$MF_CORE_ORIG_SUID" >/dev/null ||
        { mf_error 'sysctl could not restore the saved values'; return 1; }
    mf_core_values_show
}

mf_core_status() {
    local file=none base boot
    base=${MF_CORE_STATE:-$(mf_state_dir 2>/dev/null || :)}
    boot=$(mf_core_value kernel/random/boot_id)
    if [[ -n $base && $boot =~ ^[0-9a-f-]{36}$ ]]; then
        file=$base/core-policy/$boot/original.conf
    fi
    mf_core_values_show
    if mf_core_satisfied; then
        printf '%s\n' 'requirement: met'
    else
        printf '%s\n' 'requirement: not met (run: mayfly core-policy apply)'
    fi
    if [[ $file != none && -f $file ]]; then
        printf '%s\n' 'snapshot for this boot: present'
    else
        printf '%s\n' 'snapshot for this boot: none'
    fi
    if mf_core_sessions_running; then
        printf '%s\n' 'QEMU processes: running or unknown (restore would be refused)'
    else
        printf '%s\n' 'QEMU processes: none'
    fi
}

# Restore only when this process applied the policy and nothing is running.
mf_core_restore_ours() {
    (( MF_CORE_OURS == 1 )) || return 0
    if mf_core_sessions_running; then
        printf '%s\n' 'A QEMU process still runs, so the core-dump policy was left in place.' \
            'After every session ends, run: mayfly core-policy restore' >&2
        return 0
    fi
    if mf_core_restore; then
        MF_CORE_OURS=0
    else
        printf '%s\n' 'Could not restore the core-dump policy automatically. Run: mayfly core-policy restore' >&2
    fi
}

# mf_core_guarded COMMAND [ARG...]: run a command, then restore what we applied.
# EXIT, INT, TERM and HUP restore too. Ctrl+C reaches the foreground child
# directly, so the guard only keeps waiting for it to finish.
# Call it as a plain command, never after || or inside if: those contexts
# switch errexit off for everything the guarded command runs. The guard
# itself drops errexit only to collect the status and restore afterwards.
mf_core_guarded() {
    local rc=0 errexit=0
    [[ $- == *e* ]] && errexit=1
    MF_CORE_OURS=0
    trap 'mf_core_restore_ours || :' EXIT
    trap ':' INT
    trap 'exit 143' TERM HUP
    set +e
    mf_core_apply
    rc=$?
    if (( rc == 0 )); then
        "$@"
        rc=$?
    fi
    mf_core_restore_ours || :
    trap - EXIT INT TERM HUP
    (( errexit )) && set -e
    return "$rc"
}

mf_core_cmd() {
    case ${1:-} in
        apply) mf_core_apply ;;
        restore) mf_core_restore ;;
        status) mf_core_status ;;
        *) return 64 ;;
    esac
}
