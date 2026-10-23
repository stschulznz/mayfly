# Offline checks for the dedicated-user wrapper and installer.
# Sourced by run.sh. Never uses sudo, a real service user, mounts, or KVM.

mf_wrapper=$project/host/mayfly-wrapper.sh
mf_installer=$project/host/install-host.sh
mf_sub() {
    # Run a snippet in a fresh strict shell with the wrapper functions loaded.
    bash -c 'set -euo pipefail; neg() { if "$@"; then exit 1; fi; }; source "$1"; shift; eval "$1"' _ "$mf_wrapper" "$1"
}
mf_sub_installer() {
    bash -c 'set -euo pipefail; neg() { if "$@"; then exit 1; fi; }; source "$1"; shift; eval "$1"' _ "$mf_installer" "$1"
}

check 'wrapper and installer have valid shell syntax' \
    bash -c 'bash -n "$1" && bash -n "$2"' _ "$mf_wrapper" "$mf_installer"
check 'wrapper never evals or interpolates caller text into a shell' \
    bash -c '! grep -nE "(^|[^_a-z])eval |bash -c .*\\$\\{?[A-Z]*(ARG|NAME|DISPLAY)" "$1"' _ "$mf_wrapper"

check 'base names accept simple names' \
    mf_sub 'mf_valid_name test-09 && mf_valid_name A_b-1 && mf_valid_name x'
check 'base names reject paths, dots, spaces, shell syntax and long names' \
    mf_sub 'for n in "" .hidden ../x a/b "a b" "a;b" "a\$(id)" -x "$(printf "a%.0s" {1..70})"; do ! mf_valid_name "$n" || exit 1; done'

check 'caller id accepts an ordinary user and rejects unset, root and non-numeric ids' \
    mf_sub 'SUDO_UID=1000 mf_caller_uid >/dev/null
        ! (unset SUDO_UID; mf_caller_uid >/dev/null 2>&1) &&
        ! SUDO_UID=0 mf_caller_uid >/dev/null 2>&1 &&
        ! SUDO_UID=abc mf_caller_uid >/dev/null 2>&1 &&
        ! SUDO_UID="1000;id" mf_caller_uid >/dev/null 2>&1'
check 'caller id refuses the service user itself' \
    mf_sub 'id() { printf "%s\n" 1234; }; ! SUDO_UID=1234 mf_caller_uid >/dev/null 2>&1'

mf_wayland_fixture() {
    local root=$1
    mkdir -p "$root/1000" "$root/2000" "$root/3000"
    python3 - "$root" <<'PY'
import socket, sys
r = sys.argv[1]
def mk(p):
    s = socket.socket(socket.AF_UNIX); s.bind(p); return s
keep = [mk(r + "/1000/wayland-0"),
        mk(r + "/2000/wayland-0"), mk(r + "/2000/wayland-1"),
        mk(r + "/3000/wayland-0")]
open(r + "/1000/wayland-0.lock", "w").close()
open(r + "/3000/wayland-9", "w").close()
PY
}
check 'wayland socket discovery picks exactly one real socket' \
    bash -c 'set -euo pipefail; neg() { if "$@"; then exit 1; fi; }; source "$1"; d=$(mktemp -d "${TMPDIR:-/tmp}/pbw.XXXXXXXX"); trap "rm -rf -- $d" EXIT
        source "$2"; mf_wayland_fixture "$d"
        [[ $(mf_wayland_name 1000 "" "$d") == wayland-0 ]]
        neg mf_wayland_name 2000 "" "$d" >/dev/null
        [[ $(mf_wayland_name 2000 wayland-1 "$d") == wayland-1 ]]
        neg mf_wayland_name 3000 wayland-9 "$d" >/dev/null
        neg mf_wayland_name 1000 "wayland-0/../x" "$d" >/dev/null
        neg mf_wayland_name 1000 "wayland-0.lock" "$d" >/dev/null' \
        _ "$mf_wrapper" <(declare -f mf_wayland_fixture)

check 'launch option parsing accepts valid forms' \
    mf_sub 'mf_parse_launch test-09 && [[ $MF_ARG_DIAG == 0 && $MF_ARG_NAME == test-09 ]]
        mf_parse_launch --diag --display wayland-1 test-09 && [[ $MF_ARG_DIAG == 1 && $MF_ARG_DISPLAY == wayland-1 ]]'
check 'launch option parsing rejects unknown options, missing and duplicate names' \
    mf_sub '! mf_parse_launch --bogus x && ! mf_parse_launch a b && ! mf_parse_launch --display && mf_parse_launch && [[ -z $MF_ARG_NAME ]]'

check 'launch command uses a clean environment and only fixed paths' \
    mf_sub 'mf_launch_cmd test-09 0 /run/mayfly/wayland-0
        c="${MF_CMD[*]}"
        [[ ${MF_CMD[0]} == env && ${MF_CMD[1]} == -i ]]
        [[ $c == *"HOME=/var/lib/mayfly/home"* ]]
        [[ $c == *"WAYLAND_DISPLAY=/run/mayfly/wayland-0"* ]]
        [[ $c == *"/usr/local/lib/mayfly/mayfly.sh launch /var/lib/mayfly/bases/test-09 /var/lib/mayfly/secrets/wireguard.conf /dev/shm"* ]]
        [[ $c != *MAYFLY_DIAG* && $c != *DISPLAY=:* && $c != *XAUTHORITY* ]]'
check 'launch command adds diagnostics only on request' \
    mf_sub 'mf_launch_cmd t 1 /run/mayfly/wayland-0; [[ " ${MF_CMD[*]} " == *" MAYFLY_DIAG=1 "* ]]'

check 'wrapper refuses to run without root' \
    bash -c '(( EUID == 0 )) || { bash "$1" doctor >/dev/null 2>&1; [[ $? == 77 ]]; }' _ "$mf_wrapper"
check 'internal namespace entry validates its arguments before touching the system' \
    mf_sub 'for a in "0 wayland-0 0 x" "1000 ../x 0 x" "1000 wayland-0 2 x" "1000 wayland-0 0 ../x"; do
        ( mf_ns_launch $a ) >/dev/null 2>&1 && exit 1; done; true'

check 'internal namespace entry refuses to run outside the private namespace' \
    mf_sub 'out=$( (MF_IN_NS= mf_ns_launch 1000 wayland-0 0 test-09) 2>&1 ) && exit 1; [[ $out == *"internal command"* ]]'

check 'only the one bound Wayland socket receives an access list, never the runtime directory' \
    bash -c 'grep -c "setfacl -m" "$1" | grep -qx 1 && grep -F "setfacl -m \"u:\$MF_USER:rw\" -- \"\$MF_NS_TARGET\"" "$1" >/dev/null && ! grep -nE "setfacl.*/run/user/[^/]+\"?( |$)" "$1"' _ "$mf_wrapper"
check 'wrapper uses a private mount namespace and revokes access from an exit trap' \
    bash -c 'grep -Fq "unshare --mount --propagation private" "$1" && grep -Fq "trap mf_ns_revoke EXIT" "$1" && grep -Fq "trap : INT" "$1" && ! grep -q "mf_ns_forward" "$1"' _ "$mf_wrapper"
check 'a wrapper killed by TERM or HUP still runs its exit trap (bash behaviour the revoke relies on)' \
    bash -c 'for sig in TERM HUP; do
        f=$(mktemp "${TMPDIR:-/tmp}/pbt.XXXXXXXX"); rm -f "$f"
        bash -c '"'"'trap "echo ran > \$1" EXIT; sleep 20'"'"' _ "$f" & p=$!; sleep 1; kill -$sig $p; wait $p 2>/dev/null || true
        [[ -e $f ]] || exit 1; rm -f "$f"; done'
check 'launch refuses a symlinked wayland socket name' \
    bash -c 'set -euo pipefail; source "$1"; d=$(mktemp -d "${TMPDIR:-/tmp}/pbw.XXXXXXXX"); trap "rm -rf -- $d" EXIT
        source "$2"; mf_wayland_fixture "$d"; ln -s "$d/1000/wayland-0" "$d/1000/wayland-5"
        if mf_wayland_name 1000 wayland-5 "$d" >/dev/null; then exit 1; fi' _ "$mf_wrapper" <(declare -f mf_wayland_fixture)

check 'wrapper integrity-checks the installed tree before every command' \
    bash -c 'grep -Fq "sha256sum --check --quiet --strict MANIFEST.sha256" "$1"' _ "$mf_wrapper"
check 'wrapper starts in a neutral working directory' \
    bash -c 'grep -qx "cd /" "$1"' _ "$mf_wrapper"

mf_ns_harness='
    d=$(mktemp -d "${TMPDIR:-/tmp}/pbns.XXXXXXXX"); trap "rm -rf -- $d" EXIT
    log=$d/log; MF_RUN_DIR=$d/run; mkdir -p "$MF_RUN_DIR"; : > "$log"
    MF_IN_NS=1
    install() { :; }
    mount() { printf "mount %s\n" "$*" >> "$log"; if [[ $1 == --bind ]]; then bindhook "$3"; fi; }
    setfacl() { printf "setfacl %s\n" "$*" >> "$log"; }
    runuser() { printf "runuser\n" >> "$log"; return 7; }
    sockhook() { rm -f -- "$1"; python3 -c "import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])" "$1"; }
    plainhook() { :; }
'
check 'ns launch revokes the socket access list on a normal exit and keeps the launcher status' \
    mf_sub "$mf_ns_harness"'bindhook() { sockhook "$@"; }
        rc=0; (mf_ns_launch $(id -u) wayland-0 0 test-09) || rc=$?
        [[ $rc == 7 ]]
        grep -q "^setfacl -m u:mayfly:rw -- $MF_RUN_DIR/wayland-0\$" "$log"
        [[ $(grep -c "^setfacl -x u:mayfly" "$log") -ge 1 ]]
        [[ $(grep -n "^runuser" "$log" | cut -d: -f1) -gt $(grep -n "^setfacl -m" "$log" | cut -d: -f1) ]]'
check 'ns launch refuses a swapped path that is not a socket and never grants access' \
    mf_sub "$mf_ns_harness"'bindhook() { plainhook "$@"; }
        ( mf_ns_launch $(id -u) wayland-0 0 test-09 ) >/dev/null 2>&1 && exit 1
        ! grep -q "^setfacl -m" "$log" && ! grep -q "^runuser" "$log"'
check 'ns launch refuses a socket owned by someone else and never grants access' \
    mf_sub "$mf_ns_harness"'bindhook() { sockhook "$@"; }
        ( mf_ns_launch $(( $(id -u) + 1 )) wayland-0 0 test-09 ) >/dev/null 2>&1 && exit 1
        ! grep -q "^setfacl -m" "$log" && ! grep -q "^runuser" "$log"'
check 'cleanup only touches real sockets owned by the caller' \
    bash -c "grep -Fq 'if [[ -S \$socket && ! -L \$socket && \$(stat -c %u \"\$socket\") == \"\$uid\" ]]' \"\$1\"" _ "$mf_wrapper"

check 'installer runtime allowlist matches the tracked runtime files' \
    bash -c 'set -euo pipefail; source "$1"
        want=$(git -C "$2" ls-files mayfly.sh lib guest | sort)
        have=$(printf "%s\n" "${MF_RUNTIME_FILES[@]}" | sort)
        [[ $want == "$have" ]]' _ "$mf_installer" "$project"
check 'installer dry run changes nothing and prints the plan' \
    bash -c 'out=$(bash "$1" --dry-run --allow-dirty 2>&1); [[ $out == *"+ copy "*"/host/mayfly-wrapper.sh -> /usr/local/sbin/mayfly (mode 0755, root:root)"* && $out == *"+ rm -rf --one-file-system -- /usr/local/lib/mayfly"* ]]' _ "$mf_installer"
check 'installer never runs git as root and never disables git ownership protection' \
    bash -c '! grep -q "safe.directory" "$1" && grep -Fq "runuser -u \"\$SUDO_USER\" -- env -i PATH=/usr/bin:/bin git" "$1"' _ "$mf_installer"
check 'installer creates a system no-login user when missing' \
    mf_sub_installer 'id() { return 1; }; getent() { return 1; }; MF_DRY=1
        out=$(mf_ensure_user); [[ $out == *"+ useradd --system --user-group --home-dir /var/lib/mayfly --no-create-home --shell "*nologin* ]]'
check 'installer refuses an existing user that is not a no-login system account' \
    mf_sub_installer 'MF_DRY=1
        mf_ensure_user_quiet() { (mf_ensure_user) >/dev/null 2>&1; }
        id() { if [[ $1 == -u ]]; then echo 1500; else return 1; fi; }
        getent() { echo "mayfly:x:1500:1500::/home/mayfly:/bin/bash"; }
        neg mf_ensure_user_quiet
        id() { if [[ $1 == -u ]]; then echo 400; else return 1; fi; }
        getent() { echo "mayfly:x:400:400::/home/mayfly:/bin/bash"; }
        neg mf_ensure_user_quiet'
check 'installer state parent is root-owned so the service user cannot swap its subdirectories' \
    mf_sub_installer 'MF_DRY=1; out=$(mf_ensure_state)
        [[ $out == *"install -d -m 0711 -o root -g root -- /var/lib/mayfly"* &&
           $out == *"install -d -m 0700 -o mayfly -g mayfly -- /var/lib/mayfly/secrets"* &&
           $out != *"-o mayfly -g mayfly -- /var/lib/mayfly"$'"'"'\n'"'"'* ]]'
check 'installer reads only a regular file owned by the invoking user' \
    bash -c 'set -euo pipefail; neg() { if "$@"; then exit 1; fi; }; source "$1"; d=$(mktemp -d "${TMPDIR:-/tmp}/pbi.XXXXXXXX"); trap "rm -rf -- $d" EXIT
        export SUDO_UID=$(id -u)
        printf "x\n" > "$d/ok.conf"; ln -s "$d/ok.conf" "$d/link.conf"
        head -c 20000 /dev/zero > "$d/big.conf"
        [[ $(mf_read_user_file "$d/ok.conf" 16384) == x ]]
        neg mf_read_user_file "$d/link.conf" 16384 >/dev/null
        neg mf_read_user_file "$d/big.conf" 16384 >/dev/null
        neg mf_read_user_file "$d" 16384 >/dev/null
        neg mf_read_user_file "$d/missing" 16384 >/dev/null
        neg mf_read_user_file /etc/hostname 16384 >/dev/null' _ "$mf_installer"
check 'installer writes the profile as the service user, owner-only' \
    bash -c 'set -euo pipefail; source "$1"; d=$(mktemp -d "${TMPDIR:-/tmp}/pbi.XXXXXXXX"); trap "rm -rf -- $d" EXIT
        export SUDO_UID=$(id -u); printf "x\n" > "$d/p.conf"; MF_DRY=1 MF_REPLACE=0
        out=$(mf_install_private_file profile "$d/p.conf" /var/lib/mayfly/secrets/wireguard.conf 16384)
        [[ $out == "+ copy $d/p.conf -> /var/lib/mayfly/secrets/wireguard.conf as mayfly (mode 0600)" ]]
        grep -Fq "runuser -u \"\$MF_USER\" -- bash -c" "$1"' _ "$mf_installer"

mf_launch_gate_harness='
    d=$(mktemp -d "${TMPDIR:-/tmp}/pbl.XXXXXXXX"); trap "rm -rf -- $d" EXIT
    MF_STATE=$d; mkdir -p "$d/bases/test-09" "$d/secrets"; : > "$d/secrets/wireguard.conf"
    id() { printf "%s\n" 1234; }
    mf_check_install() { :; }
    stat_base=1234:700 stat_profile=1234:600
    stat() {
        case $3 in
            */bases/test-09) printf "%s\n" "$stat_base" ;;
            */secrets/wireguard.conf) printf "%s\n" "$stat_profile" ;;
            *) command stat "$@" ;;
        esac
    }
    SUDO_UID=1000
    run_launch() { ( mf_cmd_launch --display wayland-0 test-09 ) 2>&1 || :; }
'
check 'launch accepts correct base and profile ownership (control)' \
    mf_sub "$mf_launch_gate_harness"'out=$(run_launch); [[ $out != *"was not found or is not owned"* && $out != *"profile is missing"* ]]'
check 'launch refuses a base that is not owned by the service user with mode 0700' \
    mf_sub "$mf_launch_gate_harness"'stat_base=1000:700; out=$(run_launch); [[ $out == *"was not found or is not owned"* ]]
        stat_base=1234:755; out=$(run_launch); [[ $out == *"was not found or is not owned"* ]]'
check 'launch refuses a profile that is not owned by the service user with mode 0600' \
    mf_sub "$mf_launch_gate_harness"'stat_profile=1000:600; out=$(run_launch); [[ $out == *"profile is missing"* ]]
        stat_profile=1234:644; out=$(run_launch); [[ $out == *"profile is missing"* ]]'

mf_install_gate_harness='
    id() { if [[ ${1:-} == -u ]]; then printf "%s\n" 1234; fi; }
    cd() { return 0; }
    sha256sum() { return ${sum_rc:-0}; }
    prog_mode=0:644 state_mode=0:711 secrets_mode=1234:700 sum_rc=0
    stat() {
        case $3 in
            */mayfly.sh) printf "%s\n" "$prog_mode" ;;
            /var/lib/mayfly) printf "%s\n" "$state_mode" ;;
            */secrets) printf "%s\n" "$secrets_mode" ;;
            *) command stat "$@" ;;
        esac
    }
'
check 'integrity gate accepts a root-owned program, manifest and state' \
    mf_sub "$mf_install_gate_harness"'mf_check_install'
check 'integrity gate refuses a program file that is not root-owned mode 0644' \
    mf_sub "$mf_install_gate_harness"'prog_mode=1000:644; ( mf_check_install ) >/dev/null 2>&1 && exit 1; true'
check 'integrity gate refuses a manifest mismatch' \
    mf_sub "$mf_install_gate_harness"'sum_rc=1; ( mf_check_install ) >/dev/null 2>&1 && exit 1; true'
check 'integrity gate refuses a state parent that the service user could modify' \
    mf_sub "$mf_install_gate_harness"'state_mode=1234:700; ( mf_check_install ) >/dev/null 2>&1 && exit 1; true'

check 'both root scripts pin PATH to system directories' \
    bash -c 'grep -Fqx "export PATH=/usr/sbin:/usr/bin:/sbin:/bin" "$1" && grep -Fqx "export PATH=/usr/sbin:/usr/bin:/sbin:/bin" "$2"' _ "$mf_wrapper" "$mf_installer"
check 'installer refuses an unclean or unknown source revision unless told otherwise' \
    mf_sub_installer 'mf_git() { case $1 in rev-parse) printf "%s\n" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ;; status) printf " M file\n" ;; esac; }
        mf_source_revision; [[ $MF_DIRTY == yes ]]
        ( MF_DRY=1; mf_install_main --dry-run ) >/dev/null 2>&1 && exit 1
        ( mf_install_main --dry-run --allow-dirty ) >/dev/null 2>&1
        mf_git() { return 1; }; mf_source_revision; [[ $MF_DIRTY == unknown ]]
        ( mf_install_main --dry-run ) >/dev/null 2>&1 && exit 1
        true'
check 'a failed git status is unknown, never clean' \
    mf_sub_installer 'mf_git() { case $1 in rev-parse) printf "%s\n" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ;; status) return 1 ;; esac; }
        mf_source_revision; [[ $MF_DIRTY == unknown ]]
        ( mf_install_main --dry-run ) >/dev/null 2>&1 && exit 1; true'
check 'installer refuses a symlinked state subdirectory before any root chown' \
    mf_sub_installer 'd=$(mktemp -d "${TMPDIR:-/tmp}/pbs.XXXXXXXX"); trap "rm -rf -- $d" EXIT
        mkdir "$d/real"; ln -s "$d/real" "$d/secrets"; MF_STATE=$d MF_DRY=1
        out=$( (mf_ensure_state) 2>&1 ) && exit 1; [[ $out == *"is a symlink"* ]]'
check 'installer can pin an exact reviewed commit' \
    mf_sub_installer 'mf_git() { case $1 in rev-parse) printf "%s\n" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ;; status) : ;; esac; }
        ( mf_install_main --dry-run --expect-rev bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb ) >/dev/null 2>&1 && exit 1
        ( mf_install_main --dry-run --expect-rev aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ) >/dev/null 2>&1
        ( mf_install_main --dry-run --expect-rev nothex ) >/dev/null 2>&1 && exit 1
        true'
check 'kvm access: world-accessible device needs no group change' \
    mf_sub_installer 'MF_DRY=1; MF_KVM_DEV=/dev/null; stat() { case "$*" in *%a*) echo 666 ;; *) echo kvm ;; esac; }
        out=$(mf_ensure_kvm_access 2>&1); [[ $out != *usermod* ]]'
check 'kvm access: root:kvm 0660 adds the service user to the device group' \
    mf_sub_installer 'MF_DRY=1; MF_KVM_DEV=/dev/null; stat() { case "$*" in *%a*) echo 660 ;; *) echo kvm ;; esac; }
        getent() { echo kvm:x:36:; }
        out=$(mf_ensure_kvm_access 2>&1); [[ $out == *"+ usermod --append --groups kvm mayfly"* ]]'
check 'kvm access: unresolvable group is refused' \
    mf_sub_installer 'MF_DRY=1; MF_KVM_DEV=/dev/null; stat() { case "$*" in *%a*) echo 660 ;; *) echo kvm ;; esac; }
        getent() { return 2; }
        ( mf_ensure_kvm_access ) >/dev/null 2>&1 && exit 1; true'

mf_cleanup_harness='
    d=$(mktemp -d "${TMPDIR:-/tmp}/pbc.XXXXXXXX"); trap "rm -rf -- $d" EXIT; log=$d/log; : > "$log"
    SUDO_UID=1000
    id() { printf "%s\n" 1234; }
    setfacl() { :; }
    kill() { printf "kill %s\n" "$*" >> "$log"; }
    rm() { printf "rm %s\n" "$*" >> "$log"; }
    launcher_running=0
    pgrep() {
        case " $* " in
            *" -f "*) (( launcher_running )) && { printf "%s\n" 555; return 0; }; return 1 ;;
            *) printf "%s\n" 801 802 "abc;id"; return 0 ;;
        esac
    }
    find() { printf "%s\n" /dev/shm/mayfly.AbC123 "/dev/shm/mayfly.a b" /dev/shm/mayflyXY /dev/shm/mayfly.ok9 "/dev/shm/mayfly.x;y"; }
'
check 'cleanup stops only numeric orphan pids and removes only well-formed session directories' \
    mf_sub "$mf_cleanup_harness"'out=$(mf_cmd_cleanup)
        [[ $(grep -c "^kill -TERM " "$log") == 2 && $(grep -c "^kill -TERM 80[12]$" "$log") == 2 ]]
        [[ $(grep -c "^rm " "$log") == 2 ]]
        grep -q "^rm -rf --one-file-system -- /dev/shm/mayfly.AbC123$" "$log"
        grep -q "^rm -rf --one-file-system -- /dev/shm/mayfly.ok9$" "$log"'
check 'cleanup leaves a running session alone' \
    mf_sub "$mf_cleanup_harness"'launcher_running=1; out=$(mf_cmd_cleanup); [[ $out == *"run \"stop\" first"* && ! -s $log ]]'

check 'status lists only well-formed base names' \
    mf_sub 'd=$(mktemp -d "${TMPDIR:-/tmp}/pbs.XXXXXXXX"); trap "rm -rf -- $d" EXIT
        MF_STATE=$d; mkdir -p "$d/bases/ok-1" "$d/bases/b_2" "$d/bases/bad name" "$d/bases/$(printf "a\033[31mb")"
        id() { :; }; stat() { :; }; ps() { :; }; mf_caller_uid() { return 1; }
        out=$(mf_cmd_status 2>&1); [[ $out == *"bases: "* && $out == *ok-1* && $out == *b_2* && $out != *"bad name"* && $out != *$(printf "\033")* ]]'
check 'doctor refuses when the service user cannot use /dev/kvm' \
    mf_sub 'mf_check_install() { :; }; sysctl() { printf "0\n"; }
        mf_run_as() { return 1; }
        out=$( (mf_cmd_doctor) 2>&1 ) && exit 1; [[ $out == *"cannot read and write /dev/kvm"* ]]'
check 'doctor warns when keystroke injection is enabled' \
    mf_sub 'mf_check_install() { :; }; sysctl() { printf "1\n"; }; mf_run_as() { return 0; }
        out=$( (mf_cmd_doctor) 2>&1 ); [[ $out == *"legacy_tiocsti"* ]]'

check 'wrapper passes the reminder-shown flag to the launcher only when it already printed it' \
    mf_sub 'MF_REMINDER_SHOWN=1; mf_launch_cmd t 0 /run/mayfly/wayland-0; [[ " ${MF_CMD[*]} " == *" MF_REMINDER_SHOWN=1 "* ]]
        unset MF_REMINDER_SHOWN; mf_launch_cmd t 0 /run/mayfly/wayland-0; [[ " ${MF_CMD[*]} " != *MF_REMINDER_SHOWN* ]]'
