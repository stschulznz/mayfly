#!/bin/bash
# Runs INSIDE the mayfly WSL distro as root, never on Windows directly.
# One RAM-only browser session: a tmpfs-backed overlay over the read-only base
# root, a private network namespace holding only wg0, and a bwrap sandbox.
# The WireGuard profile arrives on stdin and is never printed.
set +x
set -Eeuo pipefail
export LC_ALL=C
umask 077
ulimit -c 0
lib=${MF_WSL_LIB:-/usr/local/lib/mayfly}
source "$lib/policy.sh"
source "$lib/netpolicy.sh"
source "$lib/preflight.sh"

run_root=/run/mayfly-wsl
S='' holder='' wg_pid='' sbx_pid='' ifn='' lock_fd=''

# Print the usage and exit 64.
usage() {
    printf '%s\n' 'Usage: session.sh run firefox|i2p|tor  (WireGuard profile on stdin)' \
        '       session.sh check-profile            (profile on stdin)' \
        '       session.sh preflight' \
        '       session.sh cleanup' >&2
    exit 64
}

# Print a fixed BLOCKED message and exit 1 (the EXIT trap cleans up).
die() { mf_error "$1" || :; exit 1; }

# Unmount one session mount.
drop_mount() {
    # Unmount a session mount; never lazy, so a busy mount is reported, not hidden.
    mountpoint -q -- "$1" 2>/dev/null || return 0
    umount -- "$1" 2>/dev/null || { sleep 1; umount -- "$1" 2>/dev/null; }
}

# EXIT trap: stop the sandbox, tunnel and namespace holder, unmount, remove the session folder.
cleanup() {
    local status=0
    trap - EXIT INT TERM HUP ERR
    set +e
    [[ -z $sbx_pid ]] || { kill "$sbx_pid" 2>/dev/null; wait "$sbx_pid" 2>/dev/null; }
    [[ -z $wg_pid ]] || { kill "$wg_pid" 2>/dev/null; wait "$wg_pid" 2>/dev/null; }
    [[ -z $holder ]] || { kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null; }
    [[ -z $ifn ]] || ip link del "$ifn" 2>/dev/null
    if [[ -n $S && -d $S ]]; then
        drop_mount "$S/merged" || status=1
        drop_mount "$S/lower" || status=1
        drop_mount "$S" || status=1
        (( status == 0 )) && rmdir -- "$S" 2>/dev/null
    fi
    [[ -z $lock_fd ]] || exec {lock_fd}>&-
    (( status == 0 )) || printf 'WARNING: a session mount is still busy; run "mayfly.ps1 cleanup".\n' >&2
    return "$status"
}

# Remove session folders left by a session that ended badly.
cmd_cleanup() {
    local dir
    shopt -s nullglob
    for dir in "$run_root"/s.*; do
        drop_mount "$dir/merged" || :
        drop_mount "$dir/lower" || :
        drop_mount "$dir" && rmdir -- "$dir" 2>/dev/null || :
    done
    printf 'Stale session mounts removed.\n'
}

# Poll a command every 0.1 s for up to N seconds.
wait_for() { # seconds command...
    local limit=$(( $1 * 10 )) i=0
    shift
    until "$@"; do (( ++i <= limit )) || return 1; sleep 0.1; done
}

# One session: tmpfs, overlay, private namespace with wg0, kill-switch rules, then the sandboxed browser.
cmd_run() {
    local entry=$1 uid gid size_mb tmp_bytes mtu uplink uplink_mtu overhead=60
    [[ $entry == firefox || $entry == i2p || $entry == tor ]] || usage
    mf_wsl_preflight >&2 || die 'preflight failed; nothing was started'
    uid=$(id -u "$mf_wsl_user") gid=$(id -g "$mf_wsl_user")
    size_mb=${MF_WSL_TMP_MB:-1024}
    mf_uint "$size_mb" 16384 && (( size_mb >= 128 )) || die 'MF_WSL_TMP_MB must be 128..16384'
    tmp_bytes=$(( size_mb * 1024 * 1024 ))

    mkdir -p -m 755 "$run_root"
    exec {lock_fd}> "$run_root/lock"
    flock -n "$lock_fd" || die 'another Mayfly session is running in this distro'
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM HUP

    S=$(mktemp -d "$run_root/s.XXXXXXXX")
    chmod 755 "$S"
    mount -t tmpfs -o size=512m,mode=755,nosuid,nodev tmpfs "$S"
    mkdir -m 700 "$S/secret"
    mkdir -m 755 "$S/lower" "$S/up" "$S/work" "$S/merged"
    # Only RAM holds the profile and every session write from here on.
    head -c 16385 > "$S/secret/profile"
    mf_parse_profile < "$S/secret/profile" || die 'the WireGuard profile was refused'

    # Base root, read-only, as the lower layer; upper and work are on tmpfs.
    mount --bind / "$S/lower"
    mount -o remount,bind,ro "$S/lower"
    mount -t overlay overlay -o "lowerdir=$S/lower,upperdir=$S/up,workdir=$S/work" "$S/merged"
    mf_wsl_resolv > "$S/resolv.conf"
    chmod 644 "$S/resolv.conf"

    # A namespace with no interface but lo; wg0 is moved in once keyed.
    unshare --net sleep infinity < /dev/null &
    holder=$!
    ns_ready() { [[ $(readlink "/proc/$holder/ns/net" 2>/dev/null) != "$(readlink /proc/self/ns/net)" ]]; }
    wait_for 5 ns_ready || die 'could not create the network namespace'
    ns=(nsenter --net="/proc/$holder/ns/net" --)

    ifn=mfw$$
    # MF_WSL_USERSPACE=1 skips the kernel module so the wireguard-go path can be tested.
    if [[ ${MF_WSL_USERSPACE:-0} != 1 ]] && ip link add "$ifn" type wireguard 2>/dev/null; then
        :
    else
        [[ -c $mf_wsl_tun ]] && command -v wireguard-go >/dev/null 2>&1 ||
            die 'WireGuard is unavailable (no kernel module and no wireguard-go)'
        WG_PROCESS_FOREGROUND=1 wireguard-go -f "$ifn" < /dev/null > /dev/null 2>&1 &
        wg_pid=$!
        overhead=80
        wait_for 5 test -e "/sys/class/net/$ifn" || die 'wireguard-go did not start'
    fi
    mf_wsl_wg_conf < "$S/secret/profile" | wg setconf "$ifn" /dev/stdin 2>/dev/null ||
        die 'could not apply the WireGuard profile'
    mtu=$(mf_wsl_profile_mtu < "$S/secret/profile")
    uplink=$(ip -o route get "$MF_ENDPOINT" 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -n 1) || uplink=
    uplink_mtu=$(cat "/sys/class/net/${uplink:-none}/mtu" 2>/dev/null) || uplink_mtu=1500
    mtu=$(mf_wsl_tunnel_mtu "$mtu" "$uplink_mtu" "$overhead")
    printf 'Tunnel MTU %s (uplink %s has %s).\n' "$mtu" "${uplink:-unknown}" "$uplink_mtu" >&2
    rm -f -- "$S/secret/profile"
    ip link set "$ifn" netns "$holder" name wg0
    ifn=''

    "${ns[@]}" sysctl -q -w net.ipv6.conf.all.disable_ipv6=1 net.ipv6.conf.default.disable_ipv6=1
    "${ns[@]}" ip link set lo up
    # Default-deny is in place before wg0 comes up.
    mf_wsl_nft_rules "$uid" > "$S/policy.nft"
    "${ns[@]}" nft --check --file "$S/policy.nft"
    "${ns[@]}" nft --file "$S/policy.nft"
    "${ns[@]}" ip address add "$MF_ADDRESS" dev wg0
    "${ns[@]}" ip link set wg0 mtu "$mtu" up
    "${ns[@]}" ip route add default dev wg0

    # Wayland through WSLg froze Firefox on Windows 11 build 26300 (no GDK seat); X11 works.
    local -a box=(
        bwrap --bind "$S/merged" / --dev /dev --proc /proc
        --size "$tmp_bytes" --tmpfs /tmp --size "$tmp_bytes" --tmpfs /home/browser
        --tmpfs /run --dir "/run/user/$uid"
                --ro-bind "$S/resolv.conf" /etc/resolv.conf
        --unshare-pid --unshare-ipc --unshare-uts --unshare-cgroup-try
        --die-with-parent --new-session --clearenv
        --setenv HOME /home/browser --setenv PATH /usr/bin:/bin --setenv LANG C.UTF-8
        --setenv XDG_RUNTIME_DIR "/run/user/$uid"
        --setenv MOZ_ENABLE_WAYLAND 0 --setenv GDK_BACKEND x11 --setenv DISPLAY :0
    )
    [[ -d /tmp/.X11-unix ]] || die 'the WSLg X11 socket is missing; run "wsl --update" and "wsl --shutdown" from Windows'
    box+=(--dir /tmp/.X11-unix --bind /tmp/.X11-unix /tmp/.X11-unix)
    box+=(--dir /home/browser/.mayfly-profile)
    case $entry in
        firefox)
            box+=(firefox-esr --no-remote --new-instance --profile /home/browser/.mayfly-profile) ;;
        i2p)
            box+=(bash "$lib/entry-i2p.sh") ;;
        tor)
            [[ -x /opt/tor-browser/Browser/start-tor-browser ]] || die 'Tor Browser is not installed; run mayfly.ps1 setup -Rebuild'
            box+=(--chdir /opt/tor-browser /opt/tor-browser/Browser/start-tor-browser) ;;
    esac
    printf 'Session started (%s). Close the browser to end it.\n' "$entry" >&2
    "${ns[@]}" setpriv --reuid="$uid" --regid="$gid" --init-groups --no-new-privs -- \
        "${box[@]}" < /dev/null &
    sbx_pid=$!
    wait "$sbx_pid" || :
    sbx_pid=''
}

(( $# >= 1 )) || usage
case $1 in
    run) (( $# == 2 )) || usage; cmd_run "$2" ;;
    check-profile)
        (( $# == 1 )) || usage
        head -c 16385 | mf_parse_profile || exit 1
        printf 'ok: the profile is in the accepted format\n' ;;
    preflight) (( $# == 1 )) || usage; mf_wsl_preflight ;;
    cleanup) (( $# == 1 )) || usage; cmd_cleanup ;;
    *) usage ;;
esac
