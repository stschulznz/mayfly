# Host qualification: report what is missing and print the exact install
# command for this distribution. Changes nothing on the system.

mf_os_release_file=${MF_OS_RELEASE:-/etc/os-release}

# Print fedora, debian, arch, suse or unknown.
mf_os_family() {
    local key value id='' like='' word
    [[ -r $mf_os_release_file ]] || { printf 'unknown\n'; return 0; }
    while IFS='=' read -r key value; do
        value=${value%\"}
        value=${value#\"}
        case $key in
            ID) id=$value ;;
            ID_LIKE) like=$value ;;
        esac
    done < "$mf_os_release_file"
    for word in $id $like; do
        case $word in
            fedora|rhel|centos|bazzite) printf 'fedora\n'; return 0 ;;
            debian|ubuntu) printf 'debian\n'; return 0 ;;
            arch|archlinux) printf 'arch\n'; return 0 ;;
            suse|opensuse*|sles) printf 'suse\n'; return 0 ;;
        esac
    done
    printf 'unknown\n'
}

mf_os_name() {
    local key value name=unknown
    [[ -r $mf_os_release_file ]] || { printf 'unknown\n'; return 0; }
    while IFS='=' read -r key value; do
        value=${value%\"}
        value=${value#\"}
        [[ $key == PRETTY_NAME ]] && name=$value
    done < "$mf_os_release_file"
    printf '%s\n' "$name"
}

# Package that provides a tool group on a distribution family.
# Groups: qemu qemu-img qemu-gtk iso guestfs gpg gpgv jq curl tar awk util acl git
mf_pkg_for() {
    local family=$1 group=$2
    case $family:$group in
        fedora:qemu) printf 'qemu-kvm\n' ;;
        fedora:qemu-img) printf 'qemu-img\n' ;;
        fedora:qemu-gtk) printf 'qemu-ui-gtk\n' ;;
        fedora:guestfs) printf 'guestfs-tools\n' ;;
        fedora:gpg) printf 'gnupg2\n' ;;
        fedora:gpgv) printf 'gnupg2-verify\n' ;;
        fedora:git) printf 'git-core\n' ;;
        debian:qemu) printf 'qemu-system-x86\n' ;;
        debian:qemu-img) printf 'qemu-utils\n' ;;
        debian:qemu-gtk) printf 'qemu-system-gui\n' ;;
        debian:guestfs) printf 'libguestfs-tools\n' ;;
        debian:gpg) printf 'gpg\n' ;;
        debian:gpgv) printf 'gpgv\n' ;;
        arch:qemu) printf 'qemu-system-x86\n' ;;
        arch:qemu-img) printf 'qemu-img\n' ;;
        arch:qemu-gtk) printf 'qemu-ui-gtk\n' ;;
        arch:iso) printf 'libisoburn\n' ;;
        arch:guestfs) printf 'guestfs-tools\n' ;;
        arch:gpg|arch:gpgv) printf 'gnupg\n' ;;
        suse:qemu) printf 'qemu-x86\n' ;;
        suse:qemu-img) printf 'qemu-tools\n' ;;
        suse:qemu-gtk) printf 'qemu-ui-gtk\n' ;;
        suse:guestfs) printf 'guestfs-tools\n' ;;
        suse:gpg|suse:gpgv) printf 'gpg2\n' ;;
        suse:git) printf 'git-core\n' ;;
        *:iso) printf 'xorriso\n' ;;
        *:awk) printf 'gawk\n' ;;
        *:util) printf 'util-linux\n' ;;
        *:acl) printf 'acl\n' ;;
        *:jq|*:curl|*:tar|*:git) printf '%s\n' "$group" ;;
        *) return 1 ;;
    esac
}

# Print the command that installs the given packages.
mf_install_command() {
    local family=$1 immutable=$2
    shift 2
    case $family in
        fedora)
            if [[ $immutable == 1 ]]; then
                printf 'sudo rpm-ostree install --idempotent %s   # then reboot\n' "$*"
            else
                printf 'sudo dnf install %s\n' "$*"
            fi ;;
        debian) printf 'sudo apt-get install %s\n' "$*" ;;
        arch) printf 'sudo pacman -S --needed %s\n' "$*" ;;
        suse) printf 'sudo zypper install %s\n' "$*" ;;
        *) printf 'Install these with your package manager: %s\n' "$*" ;;
    esac
}

mf_have() {
    command -v "$1" >/dev/null 2>&1
}

mf_preflight() {
    local family immutable=0 version group tool missing_group
    local -a packages=() optional=()
    local -A seen=()
    family=$(mf_os_family)
    [[ -e /run/ostree-booted ]] && immutable=1
    printf 'Mayfly preflight\nSystem: %s (family: %s%s)\n\n' \
        "$(mf_os_name)" "$family" "$([[ $immutable == 1 ]] && printf ', image-based')"

    want() { # group description; read tools from remaining args; report and queue a package
        local group=$1 label=$2 tool miss=0 pkg
        shift 2
        for tool in "$@"; do
            mf_have "$tool" || miss=1
        done
        if (( miss )); then
            pkg=$(mf_pkg_for "$family" "$group" 2>/dev/null) || pkg='(see your distribution)'
            printf '  MISSING  %-30s package: %s\n' "$label" "$pkg"
            if [[ -z ${seen[$pkg]:-} ]]; then
                seen[$pkg]=1
                packages+=("$pkg")
            fi
            return 1
        fi
        printf '  ok       %s\n' "$label"
    }

    local status=0
    want qemu 'qemu-system-x86_64' qemu-system-x86_64 || status=1
    want qemu-img 'qemu-img' qemu-img || status=1
    if mf_have qemu-system-x86_64; then
        version=$(qemu-system-x86_64 --version 2>/dev/null | sed -n '1s/.*version \([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p')
        if [[ -n $version && ${version%%.*} -ge 8 ]]; then
            printf '  ok       QEMU %s (version 8 or newer needed)\n' "$version"
        else
            printf '  MISSING  QEMU %s is too old; version 8 or newer is needed\n' "${version:-unknown}"
            status=1
        fi
        if qemu-system-x86_64 -display help 2>/dev/null | grep -qw gtk; then
            printf '  ok       QEMU GTK display\n'
        else
            printf '  MISSING  %-30s package: %s\n' 'QEMU GTK display' "$(mf_pkg_for "$family" qemu-gtk 2>/dev/null || printf unknown)"
            packages+=("$(mf_pkg_for "$family" qemu-gtk 2>/dev/null || printf unknown)")
            status=1
        fi
        if qemu-system-x86_64 -netdev help 2>/dev/null | grep -qw stream; then
            printf '  ok       QEMU stream network backend\n'
        else
            printf '  MISSING  QEMU stream network backend (QEMU 7.2 or newer)\n'
            status=1
        fi
    fi
    if mf_iso_tool >/dev/null 2>&1; then
        printf '  ok       ISO tool (%s)\n' "$(mf_iso_tool)"
    else
        printf '  MISSING  %-30s package: %s\n' 'genisoimage, mkisofs or xorriso' "$(mf_pkg_for "$family" iso)"
        packages+=("$(mf_pkg_for "$family" iso)")
        status=1
    fi
    want guestfs 'virt-customize and virt-resize' virt-customize virt-resize || status=1
    want gpg 'gpg' gpg || status=1
    want gpgv 'gpgv' gpgv || status=1
    want jq 'jq' jq || status=1
    want curl 'curl' curl || status=1
    want tar 'tar' tar || status=1
    want awk 'awk' awk || status=1
    want util 'prlimit, runuser, unshare' prlimit runuser unshare || status=1
    want acl 'setfacl (dedicated-user mode)' setfacl || status=1
    want git 'git (optional)' git || optional+=(git)

    printf '\nHost checks:\n'
    if [[ -c /dev/kvm && -r /dev/kvm && -w /dev/kvm ]]; then
        printf '  ok       /dev/kvm is usable by you\n'
    elif [[ -c /dev/kvm ]]; then
        local kvm_group
        kvm_group=$(stat -c %G /dev/kvm 2>/dev/null || :)
        printf '  WARNING  /dev/kvm exists but you cannot use it\n'
        if [[ -n $kvm_group && $kvm_group != root && $kvm_group != UNKNOWN ]]; then
            printf '           Fix: sudo usermod -aG %s "$USER", then log out and back in\n' "$kvm_group"
        else
            printf '           Fix: check the permissions of /dev/kvm for your distribution, then log out and back in\n'
        fi
    else
        printf '  MISSING  /dev/kvm; hardware virtualization is off or the kvm module is not loaded\n'
        printf '           Fix: enable virtualization (Intel VT-x or AMD-V) in the firmware setup, then run: sudo modprobe kvm_intel (Intel) or sudo modprobe kvm_amd (AMD)\n'
        status=1
    fi
    if [[ -n ${WAYLAND_DISPLAY:-} || -n $(compgen -G "/run/user/$UID/wayland-*" 2>/dev/null | head -n 1) ]]; then
        printf '  ok       Wayland session\n'
    else
        printf '  WARNING  no Wayland session found; X11-only sessions are not supported\n'
        printf '           Fix: log out and choose a Wayland session on the login screen (check with: echo $XDG_SESSION_TYPE)\n'
    fi
    local kb
    kb=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo 2>/dev/null || :)
    if [[ -n $kb ]] && (( kb >= 16 * 1024 * 1024 )); then
        printf '  ok       at least 16 GiB of memory available\n'
    else
        printf '  WARNING  less than 16 GiB of memory available; the launcher requires 16 GiB\n'
        printf '           Fix: close other applications, then run preflight again\n'
    fi
    local swaps=${MF_PROC_SWAPS:-/proc/swaps} dev disk_swap=0
    if [[ -r $swaps ]]; then
        while read -r dev _; do
            [[ $dev == Filename || $dev == /dev/zram* ]] || disk_swap=1
        done < "$swaps"
        if (( disk_swap )); then
            printf '  WARNING  disk swap is active; session memory could be written to disk. The launcher refuses to start until it is off\n'
            printf '           Fix: see DEPLOYMENT.md step 8 for how to turn it off safely (zram swap is fine)\n'
        else
            printf '  ok       no disk swap\n'
        fi
    fi
    if compgen -G '/boot/vmlinuz-*' >/dev/null 2>&1 || compgen -G '/usr/lib/modules/*/vmlinuz' >/dev/null 2>&1; then
        local readable=0 k
        for k in /boot/vmlinuz-* /usr/lib/modules/*/vmlinuz; do
            [[ -r $k ]] && readable=1
        done
        if (( readable )); then
            printf '  ok       a kernel image is readable (needed to build images)\n'
        else
            printf '  WARNING  no kernel image is readable; image builds fail\n'
            printf '           Fix (Ubuntu): sudo chmod 0644 /boot/vmlinuz-*\n'
        fi
    else
        printf '  WARNING  no kernel image found for the image-build tools\n'
        printf '           Fix: install your distribution'"'"'s kernel package, for example linux-image-amd64 on Debian\n'
    fi

    if (( ${#packages[@]} )); then
        printf '\nInstall the missing packages:\n  '
        mf_install_command "$family" "$immutable" "${packages[@]}"
    fi
    if (( ${#optional[@]} )); then
        printf '\nOptional: %s\n' "${optional[*]}"
    fi
    if (( status )); then
        printf '\nNot ready. Fix the MISSING items above, then run preflight again.\n'
        return 78
    fi
    printf '\nReady for the next step. Preflight changes nothing and does not test the VPN.\n'
}
