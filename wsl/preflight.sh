#!/bin/bash
# Read-only qualification INSIDE the mayfly WSL distro. Prints what is wrong and
# the exact fix; changes nothing. Used by "preflight" and as the launch gate.
# Paths are overridable so the offline tests can use fixtures.

mf_wsl_swaps=${MF_WSL_SWAPS:-/proc/swaps}
mf_wsl_filesystems=${MF_WSL_FILESYSTEMS:-/proc/filesystems}
mf_wsl_mounts=${MF_WSL_MOUNTS:-/proc/mounts}
mf_wsl_conf=${MF_WSL_CONF:-/etc/wsl.conf}
mf_wsl_wslg=${MF_WSL_WSLG:-/mnt/wslg}
mf_wsl_sysmodule=${MF_WSL_SYSMODULE:-/sys/module/wireguard}
mf_wsl_tun=${MF_WSL_TUN:-/dev/net/tun}
mf_wsl_user=${MF_WSL_USER:-browser}

# Print a passed check.
mf_wsl_ok() { printf 'ok:      %s\n' "$1"; }
# Print a failed check with its exact fix and return 1.
mf_wsl_bad() { printf 'MISSING: %s\n         Fix: %s\n' "$1" "$2"; return 1; }

# Swap is global to the WSL VM. Any entry means session memory could be written
# to disk, so the launcher refuses.
mf_wsl_check_swap() {
    local entries
    entries=$(awk 'NR > 1 && NF' "$mf_wsl_swaps" 2>/dev/null | wc -l)
    if [[ -r $mf_wsl_swaps ]] && (( entries == 0 )); then
        mf_wsl_ok 'no swap is active (/proc/swaps is empty)'
    else
        mf_wsl_bad 'swap is active in the WSL VM' \
            'put "[wsl2]" and "swap=0" in %UserProfile%\.wslconfig, then run "wsl --shutdown" from Windows'
    fi
}

# The WSLInterop binfmt entry stays registered VM-wide even when a distro turns
# interop off, so judge what this distro controls: its wsl.conf, its PATH and
# the absence of an interop socket in its environment.
mf_wsl_conf_value() { # section key
    awk -F= -v sec="[$1]" -v key="$2" '
        /^[ \t]*\[/ {s = $0; gsub(/[ \t\r]/, "", s); in_sec = (s == sec); next}
        in_sec {k = $1; v = $2; gsub(/[ \t\r]/, "", k); gsub(/[ \t\r]/, "", v)
            if (k == key) val = v}
        END {print val}' "$mf_wsl_conf" 2>/dev/null
}

# Interop and drive automount must be off (see the note above on the binfmt entry).
mf_wsl_check_interop() {
    local failed=0 point type
    if [[ $(mf_wsl_conf_value interop enabled) == false &&
          $(mf_wsl_conf_value interop appendWindowsPath) == false &&
          $PATH != */mnt/[a-z]/* && -z ${WSL_INTEROP:-} ]]; then
        mf_wsl_ok 'Windows interop is off (wsl.conf, PATH, environment)'
    else
        mf_wsl_bad 'Windows interop is on (this distro can start Windows programs)' \
            'put "[interop]", "enabled=false" and "appendWindowsPath=false" in /etc/wsl.conf, then "wsl --terminate" this distro' || failed=1
    fi
    while read -r _ point type _; do
        if [[ $point =~ ^/mnt/[a-z]$ && ( $type == 9p || $type == drvfs ) ]]; then
            mf_wsl_bad "Windows drive mounted at $point" \
                'put "[automount]" and "enabled=false" in /etc/wsl.conf, then "wsl --terminate" this distro' || failed=1
            return "$failed"
        fi
    done < "$mf_wsl_mounts"
    mf_wsl_ok 'Windows drives are not mounted'
    return "$failed"
}
# The session root is an overlayfs, so the kernel must list it.
mf_wsl_check_overlay() {
    if grep -qw overlay "$mf_wsl_filesystems" 2>/dev/null; then
        mf_wsl_ok 'overlayfs is available'
    else
        mf_wsl_bad 'overlayfs is not available in this WSL kernel' 'run "wsl --update" from Windows'
    fi
}

# Read-only: a loaded module is proof. Otherwise the kernel loads it on first
# use, which only the launcher exercises, so accept the userspace fallback.
mf_wsl_check_wireguard() {
    if [[ -d $mf_wsl_sysmodule ]]; then
        mf_wsl_ok 'WireGuard kernel module is loaded'
    elif [[ -c $mf_wsl_tun ]] && command -v wireguard-go >/dev/null 2>&1; then
        mf_wsl_ok 'WireGuard kernel module is not loaded yet (it loads on first use; wireguard-go is the fallback)'
    else
        mf_wsl_bad 'WireGuard is not available (no kernel module, or no wireguard-go with /dev/net/tun)' \
            'run "wsl --update" from Windows, then "wsl --shutdown"'
    fi
}

# Every program a session needs must be in the base distro.
mf_wsl_check_tools() {
    local tool failed=0
    for tool in nft bwrap wg ip nsenter setpriv unshare flock jq; do
        command -v "$tool" >/dev/null 2>&1 ||
            mf_wsl_bad "$tool is not installed in the distro" 'run "mayfly.ps1 setup" again to rebuild the base distro' || failed=1
    done
    (( failed == 1 )) || mf_wsl_ok 'nft, bwrap, wg, ip, nsenter, setpriv, unshare, flock, jq are present'
    return "$failed"
}

# The Wayland socket proves WSLg is running; the sandbox itself uses the X11 socket.
mf_wsl_check_wslg() {
    if [[ -S $mf_wsl_wslg/runtime-dir/wayland-0 ]]; then
        mf_wsl_ok 'WSLg is available'
    else
        mf_wsl_bad 'WSLg is not available (no Wayland socket)' \
            'run "wsl --update" from Windows, then "wsl --shutdown"; WSLg needs Windows 11'
    fi
}

# WSLg's runtime directory is owned by uid 1000, so the browser user must be 1000.
mf_wsl_check_user() {
    local uid
    uid=$(id -u "$mf_wsl_user" 2>/dev/null) || uid=''
    if [[ $uid == 1000 ]]; then
        mf_wsl_ok "user $mf_wsl_user exists with uid 1000"
    else
        mf_wsl_bad "user $mf_wsl_user with uid 1000 is missing" 'run "mayfly.ps1 setup" again to rebuild the base distro'
    fi
}

# Run every check and report all failures, not just the first.
mf_wsl_preflight() {
    local failed=0 check
    for check in swap interop overlay wireguard tools wslg user; do
        "mf_wsl_check_$check" || failed=1
    done
    return "$failed"
}
