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
        'Usage: sudo mayfly doctor' \
        '       sudo mayfly check-profile' \
        '       sudo mayfly build NEW-BASE-NAME' \
        '       sudo mayfly launch [--diag] [--display wayland-N] BASE-NAME' \
        '       sudo mayfly status' \
        '       sudo mayfly stop' \
        '       sudo mayfly cleanup' \
        'Everything runs as the dedicated user. Base names are letters, digits, _ and -.' \
        'cleanup revokes leftover socket access and removes orphaned VMs when no session runs.' \
        '--diag writes nonsecret counters readable only by that user and root.'
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

# Parse "launch" options into MF_ARG_DIAG, MF_ARG_DISPLAY and MF_ARG_NAME.
mf_parse_launch() {
    MF_ARG_DIAG=0 MF_ARG_DISPLAY='' MF_ARG_NAME=''
    while (( $# )); do
        case $1 in
            --diag) MF_ARG_DIAG=1; shift ;;
            --display)
                (( $# >= 2 )) || return 1
                MF_ARG_DISPLAY=$2; shift 2 ;;
            -*) return 1 ;;
            *)
                [[ -z $MF_ARG_NAME ]] || return 1
                MF_ARG_NAME=$1; shift ;;
        esac
    done
    mf_valid_name "$MF_ARG_NAME"
}

# Build the command that runs the project as the service user, with a clean
# environment. Extra KEY=VALUE words may follow the arguments listed in $@.
mf_env_cmd() {
    MF_CMD=(env -i LC_ALL=C PATH=/usr/bin:/bin "HOME=$MF_STATE/home" "$@")
}

mf_launch_cmd() {
    local name=$1 diag=$2 target=$3
    local -a extra=("WAYLAND_DISPLAY=$target")
    if [[ $diag == 1 ]]; then
        extra+=(MAYFLY_DIAG=1)
    fi
    mf_env_cmd "${extra[@]}" bash "$MF_PROG/mayfly.sh" launch \
        "$MF_STATE/bases/$name" "$MF_STATE/secrets/wireguard.conf" /dev/shm
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
    mf_check_install
    mf_run_as bash "$MF_PROG/mayfly.sh" check-profile "$MF_STATE/secrets/wireguard.conf"
}

mf_cmd_build() {
    local name=${1:-}
    mf_valid_name "$name" || mf_die 'a valid new base name is required' 64
    mf_check_install
    [[ -f $MF_STATE/pins/build.pins ]] || mf_die 'no pins file; run the installer with --pins'
    mf_run_as LIBGUESTFS_BACKEND=direct bash "$MF_PROG/mayfly.sh" build \
        "$MF_STATE/pins/build.pins" "$MF_STATE/bases/$name"
}

mf_cmd_launch() {
    local uid wl svc base
    mf_parse_launch "$@" || { mf_usage >&2; exit 64; }
    mf_check_install
    svc=$(id -u "$MF_USER")
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
    exec env MF_IN_NS=1 unshare --mount --propagation private -- \
        "$MF_SELF" __ns-launch "$uid" "$wl" "$MF_ARG_DIAG" "$MF_ARG_NAME"
}

MF_NS_TARGET=''
MF_NS_ACL=0

# Revoke the service user's access to the shared socket. Uses globals because
# an EXIT trap runs after the function that set them has returned.
mf_ns_revoke() {
    if [[ $MF_NS_ACL == 1 && -S $MF_NS_TARGET ]]; then
        setfacl -x "u:$MF_USER" -- "$MF_NS_TARGET" 2>/dev/null || :
    fi
    MF_NS_ACL=0
    return 0
}

# Internal: runs inside the private mount namespace as root.
mf_ns_launch() {
    local uid=${1:-} wl=${2:-} diag=${3:-} name=${4:-} src rc=0
    [[ $uid =~ ^[1-9][0-9]*$ && $wl =~ $MF_WAYLAND_RE && $diag =~ ^[01]$ ]] ||
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
    mount -t tmpfs -o mode=0755,nosuid,nodev,noexec,size=1m tmpfs "$MF_RUN_DIR"
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
    mf_launch_cmd "$name" "$diag" "$MF_NS_TARGET"
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
        check-profile) (( $# == 0 )) || { mf_usage >&2; exit 64; }; mf_cmd_check_profile ;;
        build) (( $# == 1 )) || { mf_usage >&2; exit 64; }; mf_cmd_build "$1" ;;
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
