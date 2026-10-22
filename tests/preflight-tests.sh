# Offline checks for the preflight command. Sourced by run.sh.

mf_pf() {
    bash -c 'set -uo pipefail; source "$1/lib/policy.sh"; source "$1/lib/runtime.sh"; source "$1/lib/preflight.sh"; shift; eval "$1"' _ "$project" "$1"
}

mf_osr() { # write an os-release file with the given lines to a temp path and print it
    local f
    f=$(mktemp "${TMPDIR:-/tmp}/mfosr.XXXXXXXX")
    printf '%s\n' "$@" > "$f"
    printf '%s\n' "$f"
}

mf_family_is() { # expected, lines...
    local want=$1 f got rc=0
    shift
    f=$(mf_osr "$@")
    got=$(MF_OS_RELEASE=$f bash -c 'source "$1/lib/preflight.sh"; mf_os_family' _ "$project")
    [[ $got == "$want" ]] || rc=1
    rm -f -- "$f"
    return "$rc"
}

check 'family: Fedora' mf_family_is fedora 'ID=fedora' 'VERSION_ID=44'
check 'family: Bazzite (ID_LIKE fedora)' mf_family_is fedora 'ID=bazzite' 'ID_LIKE="fedora"'
check 'family: Rocky (ID_LIKE rhel centos fedora)' mf_family_is fedora 'ID="rocky"' 'ID_LIKE="rhel centos fedora"'
check 'family: Debian' mf_family_is debian 'ID=debian' 'VERSION_ID="13"'
check 'family: Ubuntu (ID_LIKE debian)' mf_family_is debian 'ID=ubuntu' 'ID_LIKE=debian'
check 'family: Arch' mf_family_is arch 'ID=arch'
check 'family: Manjaro (ID_LIKE arch)' mf_family_is arch 'ID=manjaro' 'ID_LIKE=arch'
check 'family: openSUSE Tumbleweed' mf_family_is suse 'ID="opensuse-tumbleweed"' 'ID_LIKE="opensuse suse"'
check 'family: an unsupported distribution is reported as unknown' mf_family_is unknown 'ID=alpine'

mf_pkg_is() { # family group expected
    local got
    got=$(bash -c 'source "$1/lib/preflight.sh"; mf_pkg_for "$2" "$3"' _ "$project" "$1" "$2")
    [[ $got == "$3" ]]
}
check 'packages: Debian QEMU, GTK and guestfs names' bash -c '
    source "$1/lib/preflight.sh"
    [[ $(mf_pkg_for debian qemu) == qemu-system-x86 && $(mf_pkg_for debian qemu-gtk) == qemu-system-gui &&
       $(mf_pkg_for debian guestfs) == libguestfs-tools && $(mf_pkg_for debian qemu-img) == qemu-utils ]]' _ "$project"
check 'packages: Fedora splits gpgv into its own package' bash -c '
    source "$1/lib/preflight.sh"
    [[ $(mf_pkg_for fedora gpg) == gnupg2 && $(mf_pkg_for fedora gpgv) == gnupg2-verify &&
       $(mf_pkg_for fedora qemu-gtk) == qemu-ui-gtk ]]' _ "$project"
check 'packages: Arch uses libisoburn for the ISO tool and one gnupg package' bash -c '
    source "$1/lib/preflight.sh"
    [[ $(mf_pkg_for arch iso) == libisoburn && $(mf_pkg_for arch gpg) == gnupg && $(mf_pkg_for arch gpgv) == gnupg ]]' _ "$project"
check 'packages: openSUSE names' bash -c '
    source "$1/lib/preflight.sh"
    [[ $(mf_pkg_for suse qemu) == qemu-x86 && $(mf_pkg_for suse qemu-img) == qemu-tools && $(mf_pkg_for suse awk) == gawk ]]' _ "$project"
check 'packages: shared names and an unknown group' bash -c '
    source "$1/lib/preflight.sh"
    [[ $(mf_pkg_for debian iso) == xorriso && $(mf_pkg_for arch acl) == acl && $(mf_pkg_for suse jq) == jq ]] &&
    ! mf_pkg_for debian nonsense >/dev/null 2>&1' _ "$project"

check 'install command per family, including image-based Fedora' bash -c '
    source "$1/lib/preflight.sh"
    [[ $(mf_install_command fedora 0 a b) == "sudo dnf install a b" &&
       $(mf_install_command fedora 1 a b) == "sudo rpm-ostree install --idempotent a b   # then reboot" &&
       $(mf_install_command debian 0 a b) == "sudo apt-get install a b" &&
       $(mf_install_command arch 0 a b) == "sudo pacman -S --needed a b" &&
       $(mf_install_command suse 0 a b) == "sudo zypper install a b" &&
       $(mf_install_command unknown 0 a b) == *"a b" ]]' _ "$project"

check 'preflight lists missing tools, queues each package once, and fails' \
    mf_pf 'f=$(mktemp); printf "ID=debian\n" > "$f"; MF_OS_RELEASE=$f; mf_os_release_file=$f
        mf_have() { case $1 in jq|setfacl|prlimit) return 1 ;; *) return 0 ;; esac; }
        mf_iso_tool() { printf "xorriso\n"; }
        qemu-system-x86_64() { case "$*" in --version) echo "QEMU emulator version 8.2.2" ;; "-display help") echo gtk ;; "-netdev help") echo stream ;; esac; }
        out=$(mf_preflight 2>&1); rc=$?
        [[ $rc == 78 && $out == *"MISSING  jq"* && $out == *"MISSING  setfacl"* && $out == *"MISSING  prlimit, runuser, unshare"* ]]
        [[ $out == *"sudo apt-get install jq acl util-linux"* ]]
        [[ $out == *"ok       QEMU 8.2"* && $out == *"ok       QEMU GTK display"* ]]
        rm -f -- "$f"'
check 'preflight rejects a QEMU older than 8' \
    mf_pf 'f=$(mktemp); printf "ID=fedora\n" > "$f"; mf_os_release_file=$f
        mf_have() { return 0; }; mf_iso_tool() { printf "xorriso\n"; }
        qemu-system-x86_64() { case "$*" in --version) echo "QEMU emulator version 7.2.0" ;; "-display help") echo gtk ;; "-netdev help") echo stream ;; esac; }
        out=$(mf_preflight 2>&1); rc=$?; rm -f -- "$f"
        [[ $rc == 78 && $out == *"QEMU 7.2 is too old"* ]]'
check 'preflight asks for a GTK display package when QEMU lacks it' \
    mf_pf 'f=$(mktemp); printf "ID=arch\n" > "$f"; mf_os_release_file=$f
        mf_have() { return 0; }; mf_iso_tool() { printf "xorriso\n"; }
        qemu-system-x86_64() { case "$*" in --version) echo "QEMU emulator version 11.1.2" ;; "-display help") echo none ;; "-netdev help") echo stream ;; esac; }
        out=$(mf_preflight 2>&1); rm -f -- "$f"
        [[ $out == *"MISSING  QEMU GTK display"* && $out == *"sudo pacman -S --needed qemu-ui-gtk"* ]]'
check 'preflight never changes the system' \
    bash -c '! grep -nE "\b(sudo|rm|install|chmod|chown|mkdir|useradd|sysctl|rpm-ostree) " <(sed -n "/^mf_preflight() {/,/^}/p" "$1/lib/preflight.sh" | grep -v "printf") >/dev/null' _ "$project"
