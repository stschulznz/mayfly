#!/bin/bash
# Native runtime only. No host configuration, package installation or Flatpak.

mf_path() {
    [[ $1 =~ ^/[A-Za-z0-9_./-]+$ && $1 != *'/../'* && $1 != */.. &&
       $1 != *'/./'* && $1 != */. && $1 != *'//'*
    ]] || { mf_error 'path must be absolute and use simple canonical characters'; return 1; }
    [[ $(realpath -e -- "$1") == "$1" && ! -L $1 ]] ||
        { mf_error 'path must exist without symlink components'; return 1; }
}

mf_tools() {
    local cmd
    for cmd in "$@"; do
        command -v "$cmd" >/dev/null 2>&1 ||
            { mf_error "missing explicitly installed native tool: $cmd"; return 1; }
    done
    [[ ! -e /.flatpak-info && ${FLATPAK_ID:-} == '' ]] ||
        { mf_error 'Flatpak runtime is not qualified'; return 1; }
}

mf_native() {
    mf_tools qemu-system-x86_64 qemu-img prlimit jq awk || return 1
    mf_iso_tool >/dev/null || { mf_error 'an ISO tool (genisoimage, mkisofs or xorriso) is required'; return 1; }
    local version
    version=$(qemu-system-x86_64 --version) || return 1
    [[ $version =~ version[[:space:]]([0-9]+)\. ]] &&
        (( BASH_REMATCH[1] >= 8 )) ||
        { mf_error 'native QEMU >= 8 required for qualified UNIX stream command line'; return 1; }
    local feature help
    help=$(qemu-system-x86_64 -netdev help) || return 1
    for feature in user stream; do
        grep -qw "$feature" <<< "$help" ||
            { mf_error 'native QEMU needs both user and stream network backends'; return 1; }
    done
    qemu-system-x86_64 -display help | grep -qw gtk ||
        { mf_error 'native QEMU GTK display backend required'; return 1; }
    qemu-system-x86_64 -accel help | grep -qw kvm ||
        { mf_error 'native QEMU KVM accelerator required'; return 1; }
}

mf_base_check() {
    local dir=$1 role file hash expected mode links owner
    mf_path "$dir" || return 1
    [[ -d $dir && $(stat -c %u "$dir") == "$UID" &&
       $(stat -c %a "$dir") == 700 ]] ||
        { mf_error 'base directory requires current owner and mode 0700'; return 1; }
    for role in gateway browser; do
        file=$dir/$role.qcow2
        mf_path "$file" || return 1
        read -r mode links owner < <(stat -c '%a %h %u' "$file")
        [[ $mode == 444 && $links == 1 && $owner == "$UID" ]] ||
            { mf_error 'base image must be owned, single-link and mode 0444'; return 1; }
        mf_path "$dir/$role.sha256" || return 1
        IFS= read -r expected < "$dir/$role.sha256"
        [[ $expected =~ ^[a-f0-9]{64}$ ]] ||
            { mf_error 'invalid base digest'; return 1; }
        hash=$(sha256sum -- "$file"); hash=${hash%% *}
        [[ $hash == "$expected" ]] || { mf_error 'base digest mismatch'; return 1; }
        qemu-img info --output=json -f qcow2 "$file" |
            jq -e '.format == "qcow2" and .["backing-filename"] == null
                and .["data-file"] == null
                and .["format-specific"].data["data-file"] == null
                and .["virtual-size"] == 17179869184' >/dev/null ||
            { mf_error 'base must be a standalone 16 GiB qcow2 image'; return 1; }
    done
    mf_base_age_warning "$dir"
}

# Browsers cannot update inside a session, so warn when the base is stale.
mf_base_age_warning() {
    local built age limit=${MAYFLY_MAX_BASE_AGE_DAYS:-35}
    [[ $limit =~ ^[0-9]+$ ]] || limit=35
    built=$(stat -c %Y -- "$1/browser.sha256") || return 0
    age=$(( ($(date +%s) - built) / 86400 ))
    (( age <= limit )) ||
        printf 'WARNING: browser base is %s days old and cannot update; rebuild it.\n' \
            "$age" >&2
    return 0
}

mf_seed() {
    local role=$1 dns=$2 dest=$3 work=$4
    [[ $role == gateway || $role == browser ]] && mf_ipv4 "$dns" || return 1
    # Seed is local NoCloud, read-only and RAM-resident. Autonomous networking
    # is disabled; the baked service configures fixed MAC-named devices only
    # after installing the gateway firewall. There are no keys in this seed.
    # Only exact task-owned paths are written.
    printf '%s\n' '#cloud-config' 'ssh_deletekeys: true' 'ssh_genkeytypes: []' \
        'growpart: {mode: off}' 'resize_rootfs: false' \
        'write_files:' '  - path: /run/mayfly-session' '    permissions: "0600"' \
        '    content: |' "      $role $dns" |
        dd of="$work/user-data" status=none
    printf '%s\n' 'instance-id: mayfly-disposable' 'local-hostname: disposable' |
        dd of="$work/meta-data" status=none
    printf '%s\n' 'version: 2' 'ethernets: {}' |
        dd of="$work/network-config" status=none
    mf_make_seed "$dest" "$work/user-data" "$work/meta-data" "$work/network-config"
}

# First available ISO builder. cloud-localds is not used: it needs genisoimage,
# which several distributions no longer package, and openSUSE omits it entirely.
mf_iso_tool() {
    local tool
    for tool in genisoimage mkisofs xorriso; do
        if command -v "$tool" >/dev/null 2>&1; then
            printf '%s\n' "$tool"
            return 0
        fi
    done
    return 1
}

# Build the NoCloud seed (volume label "cidata") from the given files.
mf_make_seed() {
    local dest=$1 tool
    shift
    tool=$(mf_iso_tool) ||
        { mf_error 'an ISO tool (genisoimage, mkisofs or xorriso) is required'; return 1; }
    if [[ $tool == xorriso ]]; then
        xorriso -no_rc -as mkisofs -quiet -output "$dest" -volid cidata -joliet -rock "$@" >/dev/null 2>&1
    else
        "$tool" -quiet -output "$dest" -volid cidata -joliet -rock "$@" >/dev/null 2>&1
    fi
}

mf_qemu_args() {
    local role=$1 bases=$2 run=$3
    [[ $role == gateway || $role == browser ]] || return 1
    MF_QEMU=(
        -name "mayfly-$role" -nodefaults -no-user-config
        -machine q35,accel=kvm,dump-guest-core=off,mem-merge=off,vmport=off
        -cpu host -smp 2 -m 1024 -no-reboot
        -sandbox on,obsolete=deny,elevateprivileges=deny,spawn=deny,resourcecontrol=deny
        -monitor none -parallel none
        -blockdev "driver=file,node-name=base-file,filename=$bases/$role.qcow2,read-only=on"
        -blockdev driver=qcow2,node-name=base,file=base-file,read-only=on
        -blockdev "driver=file,node-name=session-file,filename=$run/$role.qcow2"
        -blockdev driver=qcow2,node-name=session,file=session-file,backing=base
        -device virtio-blk-pci,drive=session
        -drive "file=$run/$role-seed.img,format=raw,media=cdrom,readonly=on"
        -device virtio-rng-pci
    )
    if [[ ${MAYFLY_DIAG:-0} == 1 ]]; then
        # Opt-in: nonsecret link counters to a file inside the 0700 RAM dir.
        MF_QEMU+=(-serial "file:$run/$role-diag.log"
            -fw_cfg 'name=opt/mayfly/diag,string=1')
    else
        MF_QEMU+=(-serial none)
    fi
    if [[ $role == gateway ]]; then
        MF_QEMU+=(
            -display none
            -netdev "stream,id=lan,server=on,addr.type=unix,addr.path=$run/lan.sock"
            -device virtio-net-pci,netdev=lan,mac=52:54:00:fa:00:01
            -netdev user,id=wan,ipv6=off
            -device virtio-net-pci,netdev=wan,mac=52:54:00:fa:00:03
            -fw_cfg "name=opt/mayfly/profile,file=$run/profile.conf"
        )
    else
        # Exactly ONE NIC, connected ONLY to the private filesystem socket.
        MF_QEMU+=(
            -m 4096 -display gtk,gl=off
            -device VGA -device qemu-xhci -device usb-kbd -device usb-tablet
            -netdev "stream,id=lan,server=off,addr.type=unix,addr.path=$run/lan.sock"
            -device virtio-net-pci,netdev=lan,mac=52:54:00:fa:00:02
        )
        # One-way transfer disk: read-only CD-ROM, browser VM only.
        if [[ -n ${MF_ATTACH_ISO:-} ]]; then
            MF_QEMU+=(-drive "file=$MF_ATTACH_ISO,format=raw,media=cdrom,readonly=on")
        fi
    fi
}

mf_child_start() {
    local pid=$1 record rest
    local -a fields
    [[ -r /proc/$pid/stat ]] || return 1
    IFS= read -r record < "/proc/$pid/stat" || return 1
    rest=${record##*) }
    read -r -a fields <<< "$rest"
    [[ ${fields[1]:-} == "${MF_SESSION_PID:-}" && ${fields[0]:-} != Z ]] || return 1
    printf '%s\n' "${fields[19]}"
}

mf_child_alive() {
    local start
    [[ -n $1 && -n $2 ]] || return 1
    start=$(mf_child_start "$1") || return 1
    [[ $start == "$2" ]]
}

mf_stop_child() {
    local pid=$1 start=$2 i
    [[ $pid =~ ^[1-9][0-9]*$ ]] || return 0
    # Only our unreaped direct children are recorded. No pidfiles, name scans,
    # process groups, detached daemons, QMP commands or broad kill operations.
    if mf_child_alive "$pid" "$start"; then
        kill -TERM "$pid" 2>/dev/null || :
        for ((i=0; i<50; i++)); do
            mf_child_alive "$pid" "$start" || break
            sleep .1
        done
        if mf_child_alive "$pid" "$start"; then
            kill -KILL "$pid" 2>/dev/null || :
        fi
    fi
    wait "$pid" 2>/dev/null || :
}

mf_session_cleanup() {
    trap - EXIT
    trap '' INT TERM HUP
    mf_stop_child "${MF_BROWSER_PID:-}" "${MF_BROWSER_START:-}"
    mf_stop_child "${MF_GATEWAY_PID:-}" "${MF_GATEWAY_START:-}"
    MF_BROWSER_PID='' MF_GATEWAY_PID=''
    if [[ -n ${MF_RUN:-} && -d $MF_RUN && ! -L $MF_RUN ]]; then
        # Only this freshly allocated task-owned subtree; never follow links,
        # sweep by filename/age, or remove any base, input or parent path.
        mf_remove_tree "$MF_RUN"
    fi
}

mf_remove_tree() (
    local dir=$1 path
    shopt -s nullglob dotglob
    for path in "$dir"/*; do
        if [[ -d $path && ! -L $path ]]; then
            mf_remove_tree "$path" || return 1
        else
            rm -f -- "$path" || return 1
        fi
    done
    rmdir -- "$dir"
)

mf_supervise() {
    local status=0
    # Observe both, including children already reaped by Bash before wait.
    # PID + start time + parent checks avoid stale pidfile/name-based signals.
    while :; do
        if ! mf_child_alive "$MF_GATEWAY_PID" "$MF_GATEWAY_START"; then
            wait "$MF_GATEWAY_PID" 2>/dev/null || :
            MF_GATEWAY_PID=''
            mf_error 'gateway exited; terminating browser (no fallback)' || :
            return 1
        fi
        if ! mf_child_alive "$MF_BROWSER_PID" "$MF_BROWSER_START"; then
            wait "$MF_BROWSER_PID" 2>/dev/null || status=$?
            MF_BROWSER_PID=''
            return "$status"
        fi
        sleep .1
    done
}

mf_wait_gateway_socket() {
    local i
    for ((i=0; i<300; i++)); do
        mf_child_alive "$MF_GATEWAY_PID" "$MF_GATEWAY_START" ||
            { mf_error 'gateway QEMU failed before socket creation'; return 1; }
        [[ -S $MF_RUN/lan.sock ]] && return 0
        sleep .1
    done
    mf_error 'gateway socket startup timeout'
}

mf_launch() {
    set -euo pipefail
    local bases=$1 profile=$2 parent=$3 root=$4 attach_mode=${5:-} attach_path=${6:-} role
    MF_RUN='' MF_BROWSER_PID='' MF_GATEWAY_PID='' MF_ATTACH_ISO=''
    MF_BROWSER_START='' MF_GATEWAY_START='' MF_SESSION_PID=$BASHPID
    mf_native
    mf_base_check "$bases"
    mf_path "$parent"
    [[ -d $parent ]] || return 1
    # Create private subdirectory even when /dev/shm itself is shared.
    MF_RUN=$(mktemp -d "$parent/mayfly.XXXXXXXX")
    trap mf_session_cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM HUP
    mf_host_snapshot "$MF_RUN"
    mf_check_host_snapshot
    # All tool scratch/config/cache writes belong to this RAM-only subtree.
    # Retain access only to the pre-existing graphical socket, not its cache.
    if [[ -n ${WAYLAND_DISPLAY:-} && $WAYLAND_DISPLAY != /* ]]; then
        [[ ${XDG_RUNTIME_DIR:-} == /* ]] ||
            { mf_error 'Wayland requires an absolute original runtime path'; return 1; }
        export WAYLAND_DISPLAY=$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY
    fi
    if [[ -n ${WAYLAND_DISPLAY:-} ]]; then
        # Never fall back to XWayland, where other X clients can capture the window.
        export GDK_BACKEND=wayland
        unset DISPLAY XAUTHORITY
    elif [[ -n ${DISPLAY:-} && -z ${XAUTHORITY:-} && -f ${HOME:-}/.Xauthority ]]; then
        export XAUTHORITY=$HOME/.Xauthority
    fi
    export HOME=$MF_RUN/home TMPDIR=$MF_RUN/tmp
    export XDG_CONFIG_HOME=$MF_RUN/config XDG_CACHE_HOME=$MF_RUN/cache
    export XDG_DATA_HOME=$MF_RUN/data XDG_STATE_HOME=$MF_RUN/state
    export XDG_RUNTIME_DIR=$MF_RUN/runtime
    export GTK_USE_PORTAL=0 NO_AT_BRIDGE=1
    unset DBUS_SESSION_BUS_ADDRESS
    mkdir -m 700 -- "$HOME" "$TMPDIR" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME" \
        "$XDG_DATA_HOME" "$XDG_STATE_HOME" "$XDG_RUNTIME_DIR"
    # Validate and build the one-way transfer disk before the profile is read.
    # It lives in the session directory and is removed with it.
    if [[ -n $attach_mode ]]; then
        mf_attach_prepare "$attach_mode" "$attach_path" "$MF_RUN" || return 1
    fi
    [[ ${#MF_RUN} -lt 75 ]] || { mf_error 'UNIX socket path too long'; return 1; }
    mf_open_profile "$profile" "$root"
    # Snapshot exact opened bytes into private RAM before parsing. The guest
    # receives this snapshot only; no source path or key value enters argv.
    dd status=none bs=16385 count=1 <&"$MF_PROFILE_FD" of="$MF_RUN/profile.conf"
    exec {MF_PROFILE_FD}<&-
    chmod 600 "$MF_RUN/profile.conf"
    mf_parse_profile < "$MF_RUN/profile.conf"
    for role in gateway browser; do
        qemu-img create -q -f qcow2 -F qcow2 -b "$bases/$role.qcow2" "$MF_RUN/$role.qcow2"
        mf_seed "$role" "$MF_DNS" "$MF_RUN/$role-seed.img" "$MF_RUN"
    done
    # Each overlay file has a hard 3 GiB growth ceiling; exhausted storage
    # fails the VM rather than falling back to host disk. 5 GiB guest RAM,
    # <=6 GiB overlays plus seed/QEMU overhead require 16 GiB headroom.
    mf_qemu_args gateway "$bases" "$MF_RUN"
    prlimit --core=0:0 --fsize=3221225472:3221225472 -- \
        qemu-system-x86_64 "${MF_QEMU[@]}" </dev/null >/dev/null 2>&1 &
    MF_GATEWAY_PID=$!
    MF_GATEWAY_START=$(mf_child_start "$MF_GATEWAY_PID") ||
        { mf_error 'gateway QEMU exited immediately'; return 1; }
    mf_wait_gateway_socket
    # QEMU read the firmware file at startup; do not leave the key on RAM disk.
    rm -f -- "$MF_RUN/profile.conf"
    mf_qemu_args browser "$bases" "$MF_RUN"
    prlimit --core=0:0 --fsize=3221225472:3221225472 -- \
        qemu-system-x86_64 "${MF_QEMU[@]}" </dev/null >/dev/null 2>&1 &
    MF_BROWSER_PID=$!
    MF_BROWSER_START=$(mf_child_start "$MF_BROWSER_PID") ||
        { mf_error 'browser QEMU exited immediately'; return 1; }
    mf_supervise
}
