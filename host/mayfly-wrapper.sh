#!/bin/bash
# Root-owned wrapper, installed as /usr/local/sbin/mayfly.
# Runs the unmodified project as the dedicated mayfly user so that other
# processes of your desktop user cannot read the VMs' memory, the WireGuard
# profile, or the base images. It never trusts the caller's environment, the
# caller's paths, or the caller-writable source checkout.
set +x
set -euo pipefail
export LC_ALL=C
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
umask 077
# Relative --attach paths are resolved against the directory sudo was run from.
MF_CALLER_PWD=$(pwd -P 2>/dev/null) || MF_CALLER_PWD=/
cd /

MF_USER=mayfly
MF_STATE=/var/lib/mayfly
MF_PROG=/usr/local/lib/mayfly
MF_SELF=/usr/local/sbin/mayfly
MF_RUN_DIR=/run/mayfly
MF_NAME_RE='^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$'
MF_WAYLAND_RE='^wayland-[0-9]+$'

mf_die() {
    printf 'mayfly: %s\n' "$1" >&2
    exit "${2:-1}"
}

mf_usage() {
    printf '%s\n' \
        'First run: sudo mayfly setup, then sudo mayfly launch --core-policy' \
        'Usage: sudo mayfly setup [--yes]' \
        '       sudo mayfly fetch-pins [--yes] [--debian DATE-BUILD] [--tor X.Y.Z]' \
        '       sudo mayfly doctor' \
        '       sudo mayfly check-profile [--core-policy]' \
        '       sudo mayfly build [NEW-BASE-NAME]' \
        '       sudo mayfly launch [--attach FILE] [--core-policy] [--diag] [--display wayland-N] [BASE-NAME]' \
        '       sudo mayfly core-policy apply|restore|status' \
        '       sudo mayfly status' \
        '       sudo mayfly stop' \
        '       sudo mayfly cleanup' \
        'Everything runs as the dedicated user. Base names are letters, digits, _ and -.' \
        'build without a name creates base-YYYYMMDD. launch without a name uses the newest base.' \
        '--core-policy applies the host-wide core-dump policy if needed and undoes it afterwards.' \
        'cleanup revokes leftover socket access and removes orphaned VMs when no session runs.' \
        '--diag writes nonsecret counters readable only by that user and root.' \
        '--attach FILE shows one text file (up to 1 MiB, owned by you) to the browser VM, read only.'
}

mf_valid_name() {
    [[ ${1:-} =~ $MF_NAME_RE ]]
}

# Print the invoking desktop user's numeric id, never root and never the service user.
mf_caller_uid() {
    local uid=${SUDO_UID:-} svc
    [[ $uid =~ ^[1-9][0-9]*$ ]] || return 1
    if svc=$(id -u "$MF_USER" 2>/dev/null); then
        [[ $uid != "$svc" ]] || return 1
    fi
    printf '%s\n' "$uid"
}

# Print the one Wayland socket name for a user, or the validated explicit name.
mf_wayland_name() {
    local uid=$1 want=${2:-} root=${3:-/run/user} socket
    local -a found=()
    if [[ -n $want ]]; then
        [[ $want =~ $MF_WAYLAND_RE && -S $root/$uid/$want && ! -L $root/$uid/$want ]] || return 1
        printf '%s\n' "$want"
        return 0
    fi
    for socket in "$root/$uid"/wayland-*; do
        if [[ -S $socket && ! -L $socket && ${socket##*/} =~ $MF_WAYLAND_RE ]]; then
            found+=("${socket##*/}")
        fi
    done
    (( ${#found[@]} == 1 )) || return 1
    printf '%s\n' "${found[0]}"
}

# Parse "launch" options into MF_ARG_DIAG, MF_ARG_DISPLAY, MF_ARG_CORE and
# MF_ARG_NAME. An empty name means the newest base.
mf_parse_launch() {
    MF_ARG_DIAG=0 MF_ARG_DISPLAY='' MF_ARG_NAME='' MF_ARG_CORE=0 MF_ARG_ATTACH=''
    while (( $# )); do
        case $1 in
            --diag) MF_ARG_DIAG=1; shift ;;
            --core-policy) MF_ARG_CORE=1; shift ;;
            --attach)
                (( $# >= 2 )) && [[ -n $2 && -z $MF_ARG_ATTACH && $2 != *[[:cntrl:]]* ]] || return 1
                MF_ARG_ATTACH=$2; shift 2 ;;
            --display)
                (( $# >= 2 )) || return 1
                MF_ARG_DISPLAY=$2; shift 2 ;;
            -*) return 1 ;;
            *)
                [[ -z $MF_ARG_NAME ]] || return 1
                MF_ARG_NAME=$1; shift ;;
        esac
    done
    [[ -z $MF_ARG_NAME ]] || mf_valid_name "$MF_ARG_NAME"
}

# Parse "fetch-pins" options into the MF_FP_ARGS array. Only fixed, validated
# words reach the service user; there is no caller-chosen path.
mf_parse_fetch_pins() {
    MF_FP_ARGS=()
    while (( $# )); do
        case $1 in
            --yes) MF_FP_ARGS+=(--yes); shift ;;
            --debian)
                (( $# >= 2 )) && [[ $2 =~ ^[0-9]{8}-[0-9]{1,9}$ ]] || return 1
                MF_FP_ARGS+=(--debian "$2"); shift 2 ;;
            --tor)
                (( $# >= 2 )) && [[ $2 =~ ^[0-9]+(\.[0-9]+)+$ && ${#2} -le 24 ]] || return 1
                MF_FP_ARGS+=(--tor "$2"); shift 2 ;;
            *) return 1 ;;
        esac
    done
}

# Print the newest base name: latest browser.sha256 time, then name. A base is
# a directory of the service user holding both images.
mf_newest_base() {
    local entry name svc stamp
    local -a rows=()
    svc=$(id -u "$MF_USER")
    for entry in "$MF_STATE/bases"/*; do
        name=${entry##*/}
        mf_valid_name "$name" && [[ -d $entry && ! -L $entry &&
            -f $entry/gateway.qcow2 && -f $entry/browser.qcow2 &&
            $(stat -c %u "$entry") == "$svc" ]] || continue
        stamp=$(stat -c %Y "$entry/browser.sha256" 2>/dev/null) ||
            stamp=$(stat -c %Y "$entry/browser.qcow2") || continue
        rows+=("$stamp $name")
    done
    (( ${#rows[@]} )) || return 1
    printf '%s\n' "${rows[@]}" | sort -k1,1nr -k2,2r | { read -r _ name; printf '%s\n' "$name"; }
}

# The core-policy helpers live in the verified install tree. Load them only
# after mf_check_install, and keep the snapshot under root-owned state.
mf_load_core_policy() {
    # Fixed values only: nothing inherited from the caller's environment.
    unset MF_PROC_SYS MF_CORE_STATE
    source "$MF_PROG/lib/policy.sh"
    source "$MF_PROG/lib/host.sh"
    source "$MF_PROG/lib/corepolicy.sh"
    MF_CORE_STATE=$MF_STATE
}

# Build the command that runs the project as the service user, with a clean
# environment. Extra KEY=VALUE words may follow the arguments listed in $@.
mf_env_cmd() {
    MF_CMD=(env -i LC_ALL=C PATH=/usr/bin:/bin "HOME=$MF_STATE/home" "$@")
}

mf_launch_cmd() {
    local name=$1 diag=$2 target=$3 staged=${4:-}
    local -a extra=("WAYLAND_DISPLAY=$target") attach=()
    # Only the wrapper's own copy under /run/mayfly is ever named here.
    [[ -z $staged ]] || attach=(--attach-staged "$staged")
    if [[ $diag == 1 ]]; then
        extra+=(MAYFLY_DIAG=1)
    fi
    [[ -z ${MF_REMINDER_SHOWN:-} ]] || extra+=(MF_REMINDER_SHOWN=1)
    mf_env_cmd "${extra[@]}" bash "$MF_PROG/mayfly.sh" launch \
        "${attach[@]}" "$MF_STATE/bases/$name" "$MF_STATE/secrets/wireguard.conf" /dev/shm
}

mf_run_as() {
    mf_env_cmd "$@"
    runuser -u "$MF_USER" -- "${MF_CMD[@]}"
}

# Refuse to run anything unless the installed tree is intact and root-owned.
mf_check_install() {
    local uid
    uid=$(id -u "$MF_USER" 2>/dev/null) ||
        mf_die "user $MF_USER is missing; run host/install-host.sh first"
    [[ $(stat -c '%u:%a' "$MF_PROG/mayfly.sh" 2>/dev/null) == 0:644 ]] ||
        mf_die 'program tree is missing or not root-owned; rerun the installer'
    (cd -- "$MF_PROG" && sha256sum --check --quiet --strict MANIFEST.sha256 >/dev/null 2>&1) ||
        mf_die 'installed program files do not match their manifest; rerun the installer'
    [[ $(stat -c '%u:%a' "$MF_STATE" 2>/dev/null) == 0:711 &&
       $(stat -c '%u:%a' "$MF_STATE/secrets" 2>/dev/null) == "$uid:700" ]] ||
        mf_die 'state directory has unexpected ownership; rerun the installer'
}

mf_cmd_doctor() {
    mf_check_install
    mf_run_as bash -c 'test -r /dev/kvm && test -w /dev/kvm' ||
        mf_die "$MF_USER cannot read and write /dev/kvm; check ls -l /dev/kvm and grant access first"
    if [[ $(sysctl -n dev.tty.legacy_tiocsti 2>/dev/null || printf 0) != 0 ]]; then
        printf '%s\n' 'WARNING: dev.tty.legacy_tiocsti is enabled, so a process sharing your' \
            'terminal could inject keystrokes. Set it to 0.' >&2
    fi
    mf_run_as bash -c 'set -euo pipefail
        scratch=$(mktemp -d /dev/shm/mayfly-check.XXXXXXXX)
        status=0
        bash "$1" doctor "$scratch" || status=$?
        rmdir -- "$scratch"
        printf "doctor exit: %s\n" "$status"
        exit "$status"' _ "$MF_PROG/mayfly.sh"
}

mf_cmd_check_profile() {
    local core=0
    while (( $# )); do
        case $1 in
            --core-policy) core=1; shift ;;
            *) mf_usage >&2; exit 64 ;;
        esac
    done
    mf_check_install
    if (( core )); then
        mf_load_core_policy
        mf_core_guarded mf_run_as bash "$MF_PROG/mayfly.sh" check-profile "$MF_STATE/secrets/wireguard.conf"
    else
        mf_run_as bash "$MF_PROG/mayfly.sh" check-profile "$MF_STATE/secrets/wireguard.conf"
    fi
}

mf_cmd_fetch_pins() {
    mf_parse_fetch_pins "$@" || { mf_usage >&2; exit 64; }
    mf_check_install
    mf_run_as "MAYFLY_HOME=$MF_STATE" bash "$MF_PROG/mayfly.sh" fetch-pins "${MF_FP_ARGS[@]}"
}

mf_cmd_build() {
    local name=${1:-}
    if [[ -z $name ]]; then
        # Default name: base-YYYYMMDD, then -2, -3 if that day's name is taken.
        local base=base-$(date +%Y%m%d) i=2
        name=$base
        while [[ -e $MF_STATE/bases/$name || -L $MF_STATE/bases/$name ]]; do
            name=$base-$i
            i=$((i + 1))
            (( i <= 99 )) || mf_die 'no free default base name; pass a name' 73
        done
    fi
    mf_valid_name "$name" || mf_die 'a valid new base name is required' 64
    mf_check_install
    [[ -f $MF_STATE/pins/build.pins ]] || mf_die 'no pins file; run: sudo mayfly fetch-pins'
    [[ ! -e $MF_STATE/bases/$name && ! -L $MF_STATE/bases/$name ]] ||
        mf_die "base $name already exists; builds never overwrite. Pick another name"
    mf_run_as LIBGUESTFS_BACKEND=direct bash "$MF_PROG/mayfly.sh" build \
        "$MF_STATE/pins/build.pins" "$MF_STATE/bases/$name"
}

mf_cmd_setup() {
    local arg
    local -a yes=()
    for arg in "$@"; do
        [[ $arg == --yes ]] || { mf_usage >&2; exit 64; }
        yes=(--yes)
    done
    mf_check_install
    [[ -f $MF_STATE/secrets/wireguard.conf ]] ||
        mf_die 'the WireGuard profile is missing; rerun the installer with --profile (or put it at ~/.local/state/mayfly/secrets/wireguard.conf first)'
    if [[ -f $MF_STATE/pins/build.pins ]]; then
        printf '%s\n' 'already done: pins file exists'
    else
        mf_run_as "MAYFLY_HOME=$MF_STATE" bash "$MF_PROG/mayfly.sh" fetch-pins "${yes[@]}"
    fi
    if mf_newest_base >/dev/null; then
        printf 'already done: base %s\n' "$(mf_newest_base)"
    else
        mf_cmd_build
    fi
    printf '%s\n' 'Setup finished. Next: sudo mayfly launch --core-policy'
}

mf_cmd_core_policy() {
    mf_check_install
    mf_load_core_policy
    mf_core_cmd "$1"
}

mf_cmd_launch() {
    local uid wl svc base attach=''
    local -a attach_arg=()
    mf_parse_launch "$@" || { mf_usage >&2; exit 64; }
    mf_check_install
    if [[ -n $MF_ARG_ATTACH ]]; then
        # Resolve in the caller's directory. The file is validated and read once,
        # as root on its open descriptor, inside the namespace.
        attach=$MF_ARG_ATTACH
        [[ $attach == /* ]] || attach=$MF_CALLER_PWD/$attach
        attach_arg=("$attach")
    fi
    svc=$(id -u "$MF_USER")
    if [[ -z $MF_ARG_NAME ]]; then
        MF_ARG_NAME=$(mf_newest_base) || mf_die 'no base found; run: sudo mayfly setup'
    fi
    base=$MF_STATE/bases/$MF_ARG_NAME
    [[ -d $base && $(stat -c '%u:%a' "$base") == "$svc:700" ]] ||
        mf_die "base $MF_ARG_NAME was not found or is not owned by $MF_USER"
    [[ $(stat -c '%u:%a' "$MF_STATE/secrets/wireguard.conf" 2>/dev/null) == "$svc:600" ]] ||
        mf_die 'the WireGuard profile is missing; run the installer with --profile'
    uid=$(mf_caller_uid) || mf_die 'run this with sudo from your desktop session'
    wl=$(mf_wayland_name "$uid" "$MF_ARG_DISPLAY") ||
        mf_die 'cannot pick exactly one Wayland socket; pass --display wayland-N'
    [[ ! -L /run/user/$uid/$wl && $(stat -c %u "/run/user/$uid/$wl") == "$uid" ]] ||
        mf_die 'the Wayland socket is not owned by the invoking user'
    # A private mount namespace keeps the socket bind mount invisible to the
    # rest of the system and removes it automatically when the session ends.
    if [[ $MF_ARG_CORE == 1 ]]; then
        # Not exec: this shell must outlive the session to undo the policy.
        mf_load_core_policy
        mf_core_guarded mf_launch_ns "$uid" "$wl" "$MF_ARG_DIAG" "$MF_ARG_NAME" "${attach_arg[@]}"
        return
    fi
    exec env MF_IN_NS=1 unshare --mount --propagation private -- \
        "$MF_SELF" __ns-launch "$uid" "$wl" "$MF_ARG_DIAG" "$MF_ARG_NAME" "${attach_arg[@]}"
}

mf_launch_ns() {
    env MF_IN_NS=1 ${MF_REMINDER_SHOWN:+MF_REMINDER_SHOWN=1} \
        unshare --mount --propagation private -- "$MF_SELF" __ns-launch "$@"
}

MF_NS_TARGET=''
MF_NS_ACL=0
MF_NS_ATTACH=''

# Revoke the service user's access to the shared socket. Uses globals because
# an EXIT trap runs after the function that set them has returned.
mf_ns_revoke() {
    if [[ $MF_NS_ACL == 1 && -S $MF_NS_TARGET ]]; then
        setfacl -x "u:$MF_USER" -- "$MF_NS_TARGET" 2>/dev/null || :
    fi
    MF_NS_ACL=0
    # The copy of the attach file goes with the session even if the tmpfs lingers.
    if [[ -n $MF_NS_ATTACH ]]; then
        rm -f -- "$MF_NS_ATTACH" 2>/dev/null || :
        MF_NS_ATTACH=''
    fi
    return 0
}

# Internal: copy the user's file into the namespace-private /run/mayfly tmpfs
# as a root-owned 0640 root:mayfly file, validated on its open descriptor.
# This is the only attach path the service-user launcher is ever given.
mf_ns_stage_attach() {
    local src=$1 uid=$2 name
    mf_check_install
    source "$MF_PROG/lib/policy.sh"
    source "$MF_PROG/lib/attach.sh"
    name=$(mf_attach_name "$src")
    install -d -m 0750 -o root -g "$MF_USER" -- "$MF_RUN_DIR/attach"
    MF_NS_ATTACH=$MF_RUN_DIR/attach/$name
    mf_attach_read "$src" "$uid" "$MF_NS_ATTACH" || mf_die 'the attach file was refused'
    chown "root:$MF_USER" -- "$MF_NS_ATTACH"
    chmod 0640 -- "$MF_NS_ATTACH"
}

# Internal: runs inside the private mount namespace as root.
mf_ns_launch() {
    local uid=${1:-} wl=${2:-} diag=${3:-} name=${4:-} attach=${5:-} src rc=0
    [[ $uid =~ ^[1-9][0-9]*$ && $wl =~ $MF_WAYLAND_RE && $diag =~ ^[01]$ ]] ||
        mf_die 'invalid internal arguments' 64
    [[ -z $attach || ( $attach == /* && $attach != *[[:cntrl:]]* ) ]] ||
        mf_die 'invalid internal arguments' 64
    mf_valid_name "$name" || mf_die 'invalid internal arguments' 64
    # Mounts here must never land in the real namespace.
    [[ ${MF_IN_NS:-} == 1 ]] || mf_die 'internal command; use: sudo mayfly launch' 78
    unset MF_IN_NS
    src=/run/user/$uid/$wl
    MF_NS_TARGET=$MF_RUN_DIR/wayland-0
    # The exit trap is set first, so no way out leaves access behind. TERM and
    # HUP keep their default action, which still runs it. Ctrl+C reaches the
    # whole foreground group and the launcher cleans up itself; the wrapper
    # ignores it only so the revoke below still runs. A wrapper killed alone
    # leaves the session running; end it with "stop".
    trap mf_ns_revoke EXIT
    trap : INT
    install -d -m 0755 -o root -g root -- "$MF_RUN_DIR"
    mount -t tmpfs -o mode=0755,nosuid,nodev,noexec,size=3m tmpfs "$MF_RUN_DIR"
    : > "$MF_NS_TARGET"
    mount --bind "$src" "$MF_NS_TARGET"
    # The user controls the directory that held the path, so validate the object
    # that was actually mounted, never the original path again.
    [[ -S $MF_NS_TARGET && ! -L $MF_NS_TARGET &&
       $(stat -c %u "$MF_NS_TARGET") == "$uid" ]] ||
        mf_die 'the Wayland socket changed or is not owned by the invoking user'
    # Only this one socket is shared; the user's runtime directory stays closed
    # because it holds other world-connectable sockets such as audio.
    MF_NS_ACL=1
    setfacl -m "u:$MF_USER:rw" -- "$MF_NS_TARGET"
    if [[ -n $attach ]]; then
        mf_ns_stage_attach "$attach" "$uid"
    fi
    mf_launch_cmd "$name" "$diag" "$MF_NS_TARGET" "$MF_NS_ATTACH"
    runuser -u "$MF_USER" -- "${MF_CMD[@]}" || rc=$?
    mf_ns_revoke
    return "$rc"
}

mf_cmd_stop() {
    local pid count=0
    local -a pids=()
    mapfile -t pids < <(pgrep -u "$MF_USER" -f "^bash $MF_PROG/mayfly.sh launch " || :)
    for pid in "${pids[@]}"; do
        [[ $pid =~ ^[1-9][0-9]*$ ]] || continue
        kill -INT "$pid"
        count=$((count + 1))
    done
    printf 'Sent a graceful stop to %s session launcher(s).\n' "$count"
}

mf_cmd_status() {
    local uid socket
    id "$MF_USER" 2>/dev/null || printf 'user %s: not installed\n' "$MF_USER"
    stat -c '%A %U %n' "$MF_STATE" 2>/dev/null || :
    if [[ -d $MF_STATE/bases ]]; then
        printf 'bases:'
        for socket in "$MF_STATE/bases"/*; do
            if [[ -d $socket ]] && mf_valid_name "${socket##*/}"; then
                printf ' %s' "${socket##*/}"
            fi
        done
        printf '\n'
    fi
    printf 'processes of %s:\n' "$MF_USER"
    ps -u "$MF_USER" -o pid=,etime=,comm= 2>/dev/null || :
    if uid=$(mf_caller_uid); then
        for socket in /run/user/"$uid"/wayland-*; do
            [[ -S $socket ]] && getfacl -c -- "$socket" 2>/dev/null | grep "user:$MF_USER" || :
        done
    fi
}

mf_cmd_cleanup() {
    local uid socket pid dir
    local -a pids=() dirs=()
    uid=$(mf_caller_uid) || mf_die 'run this with sudo from your desktop session'
    for socket in /run/user/"$uid"/wayland-*; do
        if [[ -S $socket && ! -L $socket && $(stat -c %u "$socket") == "$uid" ]]; then
            setfacl -x "u:$MF_USER" -- "$socket" 2>/dev/null || :
        fi
    done
    printf 'Removed any leftover %s access to your Wayland sockets.\n' "$MF_USER"
    if pgrep -u "$MF_USER" -f "^bash $MF_PROG/mayfly.sh launch " >/dev/null; then
        printf '%s\n' 'A session launcher is still running; run "stop" first. Left its files alone.'
        return 0
    fi
    # No launcher remains, so leftover VMs and session directories are orphans.
    mapfile -t pids < <(pgrep -u "$MF_USER" -x qemu-system-x86 || :)
    for pid in "${pids[@]}"; do
        [[ $pid =~ ^[1-9][0-9]*$ ]] && kill -TERM "$pid"
    done
    mapfile -t dirs < <(find /dev/shm -maxdepth 1 -mindepth 1 -type d -user "$MF_USER" -name 'mayfly.*' 2>/dev/null)
    for dir in "${dirs[@]}"; do
        [[ $dir =~ ^/dev/shm/mayfly\.[A-Za-z0-9]+$ ]] && rm -rf --one-file-system -- "$dir"
    done
    printf 'Stopped %s orphaned VM process(es) and removed %s leftover session director(ies).\n' \
        "${#pids[@]}" "${#dirs[@]}"
}

mf_main() {
    (( $# > 0 )) || { mf_usage; exit 64; }
    (( EUID == 0 )) || mf_die 'run with sudo: sudo mayfly COMMAND' 77
    local command=$1
    shift
    case $command in
        doctor) (( $# == 0 )) || { mf_usage >&2; exit 64; }; mf_cmd_doctor ;;
        check-profile) mf_cmd_check_profile "$@" ;;
        fetch-pins) mf_cmd_fetch_pins "$@" ;;
        setup) mf_cmd_setup "$@" ;;
        build) (( $# <= 1 )) || { mf_usage >&2; exit 64; }; mf_cmd_build "${1:-}" ;;
        core-policy)
            (( $# == 1 )) && [[ $1 == apply || $1 == restore || $1 == status ]] ||
                { mf_usage >&2; exit 64; }
            mf_cmd_core_policy "$1" ;;
        launch) mf_cmd_launch "$@" ;;
        status) mf_cmd_status ;;
        stop) mf_cmd_stop ;;
        cleanup) mf_cmd_cleanup ;;
        __ns-launch) mf_ns_launch "$@" ;;
        *) mf_usage >&2; exit 64 ;;
    esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    mf_main "$@"
fi
