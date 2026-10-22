#!/bin/bash
# Read-only host snapshot and conservative checks. No host settings are changed.

declare -A MF_HOST=()

mf_swap_record_safe() {
    # The backing value must come from this device's actual sysfs backing_dev.
    [[ $1 =~ ^/dev/zram[0-9]+$ && $2 == partition && $3 == none ]]
}

mf_read_state() {
    local value
    if [[ -r $1 ]] && IFS= read -r value < "$1"; then
        printf '%s\n' "$value"
    else
        printf '%s\n' unknown
    fi
}

mf_profile_dump_guard() {
    local pattern
    pattern=$(mf_read_state /proc/sys/kernel/core_pattern)
    [[ -n $pattern && $pattern != unknown && $pattern != \|* &&
       $(ulimit -S -c) == 0 && $(ulimit -H -c) == 0 ]] ||
        { mf_error 'profile parsing requires zero core limits and a non-piped core pattern; no proven shell-only process nondumpability mechanism'; return 1; }
}

mf_host_snapshot() {
    local dir=$1 device type rest backing canonical
    MF_HOST=()
    canonical=$(realpath -e -- "$dir") || return 1
    [[ $dir == /* && $dir == "$canonical" && -d $dir && ! -L $dir ]] ||
        { mf_error 'RAM directory must be absolute, canonical and nonsymlink'; return 1; }
    MF_HOST[ram_owner]=$(stat -c %u -- "$dir")
    MF_HOST[ram_mode]=$(stat -c %a -- "$dir")
    MF_HOST[ram_fs]=$(findmnt --target "$dir" --noheadings --raw --output FSTYPE)
    MF_HOST[ram_options]=$(findmnt --target "$dir" --noheadings --raw --output OPTIONS)
    MF_HOST[ram_size]=$(findmnt --target "$dir" --bytes --noheadings --raw --output SIZE)
    MF_HOST[ram_available]=$(findmnt --target "$dir" --bytes --noheadings --raw --output AVAIL)
    MF_HOST[mem_available]=$(awk '/^MemAvailable:/ {printf "%.0f\n", $2 * 1024}' /proc/meminfo)
    MF_HOST[power_state]=$(mf_read_state /sys/power/state)
    MF_HOST[resume]=$(mf_read_state /sys/power/resume)
    MF_HOST[resume_offset]=$(mf_read_state /sys/power/resume_offset)
    MF_HOST[resume_config]=unknown
    if [[ -r /proc/cmdline ]]; then
        MF_HOST[resume_config]=none
        local argument
        local -a kernel_args
        read -r -a kernel_args < /proc/cmdline
        for argument in "${kernel_args[@]}"; do
            case $argument in resume=*|resume_offset=*) MF_HOST[resume_config]=configured ;; esac
        done
    fi
    MF_HOST[crash_loaded]=$(mf_read_state /sys/kernel/kexec_crash_loaded)
    MF_HOST[crash_size]=$(mf_read_state /sys/kernel/kexec_crash_size)
    MF_HOST[core_pattern]=$(mf_read_state /proc/sys/kernel/core_pattern)
    MF_HOST[suid_dumpable]=$(mf_read_state /proc/sys/fs/suid_dumpable)
    MF_HOST[core_soft]=$(ulimit -S -c)
    MF_HOST[core_hard]=$(ulimit -H -c)
    MF_HOST[swap_safe]=unknown
    if [[ -r /proc/swaps ]]; then
        MF_HOST[swap_safe]=yes
        while read -r device type rest; do
            [[ $device == Filename ]] && continue
            backing=unknown
            if [[ $device =~ ^/dev/zram[0-9]+$ ]]; then
                backing=$(mf_read_state "/sys/block/${device##*/}/backing_dev")
            fi
            mf_swap_record_safe "$device" "$type" "$backing" || MF_HOST[swap_safe]=no
        done < /proc/swaps
    fi
    MF_HOST[kvm]=no
    [[ -c /dev/kvm && -r /dev/kvm && -w /dev/kvm ]] && MF_HOST[kvm]=yes
    return 0
}

mf_check_host_snapshot() {
    # Fixture-callable predicate, NOT a live acceptance proof or resource lease.
    local failed=0 option
    if [[ ${MF_HOST[ram_fs]:-} != tmpfs ||
          ${MF_HOST[ram_owner]:-} != "$UID" ||
          ${MF_HOST[ram_mode]:-} != 700 ]]; then
        mf_error 'RAM directory requires actual tmpfs, current owner and mode 0700' || :
        failed=1
    fi
    for option in nodev nosuid; do
        if [[ ,${MF_HOST[ram_options]:-}, != *,"$option",* ]]; then
            mf_error 'RAM mount requires nodev,nosuid (data files do not require noexec)' || :
            failed=1
            break
        fi
    done
    # Shared /dev/shm may be much larger than our session. Per-file overlay
    # limits are enforced by prlimit; do not mistake mount size for a quota.
    if [[ ! ${MF_HOST[ram_size]:-} =~ ^(0|[1-9][0-9]{0,11})$ ]] ||
        (( ${MF_HOST[ram_size]:-0} < 7516192768 )); then
        mf_error 'tmpfs capacity must be at least 7 GiB' || :
        failed=1
    fi
    if [[ ! ${MF_HOST[ram_available]:-} =~ ^(0|[1-9][0-9]{0,11})$ ]] ||
        (( ${MF_HOST[ram_available]:-0} < 7516192768 )); then
        mf_error 'tmpfs needs at least 7 GiB currently free' || :
        failed=1
    fi
    if [[ ! ${MF_HOST[mem_available]:-} =~ ^(0|[1-9][0-9]{0,11})$ ]] ||
        (( ${MF_HOST[mem_available]:-0} < 17179869184 )); then
        mf_error 'at least 16 GiB available memory required for 5 GiB guests, 6 GiB overlay ceilings and overhead/headroom' || :
        failed=1
    fi
    if [[ ${MF_HOST[swap_safe]:-} != yes ]]; then
        mf_error 'swap must be absent or exclusively zram with backing_dev none' || :
        failed=1
    fi
    if [[ -z ${MF_HOST[power_state]:-} ||
          ${MF_HOST[power_state]:-} == unknown ||
          ${MF_HOST[resume]:-} != 0:0 ||
          ${MF_HOST[resume_offset]:-} != 0 ||
          ${MF_HOST[resume_config]:-} != none ]]; then
        mf_error 'require unconfigured resume device/offset and no resume kernel arguments; disk capability alone is not configuration' || :
        failed=1
    fi
    if [[ ${MF_HOST[crash_loaded]:-} != 0 || ${MF_HOST[crash_size]:-} != 0 ]]; then
        mf_error 'kernel crash dump must be unloaded with zero reserved crash memory' || :
        failed=1
    fi
    if [[ ${MF_HOST[core_soft]:-} != 0 || ${MF_HOST[core_hard]:-} != 0 ||
          -z ${MF_HOST[core_pattern]:-} ||
          ${MF_HOST[core_pattern]:-} == unknown ||
          ${MF_HOST[core_pattern]:-} == \|* ||
          ${MF_HOST[suid_dumpable]:-} != 0 ]]; then
        mf_error 'require zero core limits and suid_dumpable=0; piped collector refused: shell-only launcher cannot establish QEMU process nondumpability (RLIMIT_CORE does not constrain pipes)' || :
        failed=1
    fi
    if [[ ${MF_HOST[kvm]:-} != yes ]]; then
        mf_error 'read/write access to the KVM character device required' || :
        failed=1
    fi
    (( failed == 0 ))
}
