#!/bin/bash
# Sourced by run.sh. Structural checks and explicit MOCK lifecycle only.

check 'versioned pin file accepted as data, not downloaded' mf_build_config \
    "$project/tests/fixtures/synthetic.pins"
pins=$(< "$project/tests/fixtures/synthetic.pins")
bad_pins() {
    printf '%s\n' "$1" | dd of="$tmp/invalid.pins" status=none
    ! mf_build_config "$tmp/invalid.pins" 2>/dev/null
}
check 'pin input cannot execute shell' bad_pins "$pins"$'\nPostUp=$(false)'
check 'duplicate pin rejected' bad_pins "$pins"$'\nTOR_SHA256=0'
check 'latest unpinned Debian URL rejected' bad_pins "${pins/20251006-2257\/debian/latest\/debian}"
check 'HTTP download origin rejected' bad_pins "${pins/https:/http:}"
check 'foreign Tor origin rejected' bad_pins "${pins/dist.torproject.org/example.invalid}"
check 'nonhex digest rejected' bad_pins "${pins/IMAGE_SHA256=0/IMAGE_SHA256=z}"
check 'pin symlink rejected' bash -c \
    'source "$1/lib/policy.sh"; source "$1/lib/runtime.sh"; source "$1/lib/build.sh"; ! mf_build_config "$2" 2>/dev/null' \
    _ "$project" "$tmp/link.conf"
check 'download mismatch fails closed' bash -c \
    'source "$1/lib/policy.sh"; source "$1/lib/build.sh"; ! mf_digest "$2" 0000000000000000000000000000000000000000000000000000000000000000 2>/dev/null' \
    _ "$project" "$tmp/profile.conf"
check 'comma path rejected before QEMU option injection' bash -c \
    'source "$1/lib/policy.sh"; source "$1/lib/runtime.sh"; ! mf_path "/tmp/a,readonly=off" 2>/dev/null' _ "$project"

mf_customize_args /mock/base.qcow2 /mock/build "$project"
custom="${MF_CUSTOMIZE[*]}"
contains_custom() { [[ $custom == *"$1"* ]]; }
check 'real build command installs gateway packages' contains_custom --install
check 'real build uploads existing validated parser' contains_custom lib/policy.sh:
check 'real build invokes in-guest preparation' contains_custom 'bash /usr/local/lib/mayfly/prepare.sh'
check 'image format specified before appliance drive' test "${MF_CUSTOMIZE[0]}" = --format

mf_qemu_args browser /mock/base /dev/shm/mayfly.mock
args="${MF_QEMU[*]}"
contains_arg() { [[ $args == *"$1"* ]]; }
lacks_arg() { [[ $args != *"$1"* ]]; }
check 'browser has exactly one network backend' test "$(grep -o -- '-netdev' <<< "$args" | wc -l)" = 1
check 'browser UNIX stream uses QEMU 8 default no-reconnect' contains_arg \
    'stream,id=lan,server=off,addr.type=unix,addr.path=/dev/shm/mayfly.mock/lan.sock'
check 'browser has no reconnect override' lacks_arg reconnect
check 'browser has no user/slirp backend' lacks_arg 'user,id='
check 'base file opened read-only' contains_arg 'filename=/mock/base/browser.qcow2,read-only=on'
check 'base qcow2 node opened read-only' contains_arg 'node-name=base,file=base-file,read-only=on'
check 'overlay explicitly backs onto readonly base node' contains_arg 'file=session-file,backing=base'
check 'session writes point to selected RAM path' contains_arg 'filename=/dev/shm/mayfly.mock/browser.qcow2'
check 'seed is read-only' contains_arg 'format=raw,media=cdrom,readonly=on'
check 'guest core exclusion set' contains_arg 'dump-guest-core=off'
check 'KSM disabled' contains_arg 'mem-merge=off'
check 'no default devices or implicit NIC' contains_arg '-nodefaults -no-user-config'
for forbidden in 'hostfwd' 'guestfwd' 'virtfs' '9p' 'vhost-user' 'spice' \
    'qemu-ga' 'usb-host' 'pflash' 'tpm' '-snapshot' '-loadvm' '-incoming'; do
    check "browser lacks integration/persistence: $forbidden" lacks_arg "$forbidden"
done
mf_qemu_args gateway /mock/base /dev/shm/mayfly.mock
args="${MF_QEMU[*]}"
check 'gateway private UNIX socket listener' contains_arg \
    'stream,id=lan,server=on,addr.type=unix,addr.path=/dev/shm/mayfly.mock/lan.sock'
check 'gateway WAN is IPv4-only user mode' contains_arg 'user,id=wan,ipv6=off'
check 'gateway WAN never forwards host ports' lacks_arg hostfwd
check 'gateway secret transported by read-only firmware file' contains_arg \
    'name=opt/mayfly/profile,file=/dev/shm/mayfly.mock/profile.conf'
check 'no literal synthetic key in QEMU argv' lacks_arg AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
check 'gateway no graphical integration' contains_arg '-display none'
check 'diagnostics off by default: serial none' contains_arg '-serial none'
check 'diagnostics off by default: no serial file' lacks_arg 'gateway-diag'
MAYFLY_DIAG=1 mf_qemu_args gateway /mock/base /dev/shm/mayfly.mock
args="${MF_QEMU[*]}"
check 'opt-in diagnostics use a file inside the RAM session dir' contains_arg \
    'file:/dev/shm/mayfly.mock/gateway-diag.log'
check 'opt-in diagnostics replace serial none' lacks_arg '-serial none'
MAYFLY_DIAG=1 mf_qemu_args browser /mock/base /dev/shm/mayfly.mock
args="${MF_QEMU[*]}"
check 'browser diagnostics log is separate and inside the RAM dir' contains_arg \
    'file:/dev/shm/mayfly.mock/browser-diag.log'
check 'profile firmware file is never passed to the browser VM' lacks_arg \
    'opt/mayfly/profile'
check 'diagnostics script never prints profile, keys or endpoint' \
    bash -c '! grep -Eqi "PrivateKey|PresharedKey|MF_ENDPOINT|profile\.conf|wg show wg0 (dump|private)" "$1"' _ "$project/guest/diag.sh"
mf_qemu_args gateway /mock/base /dev/shm/mayfly.mock
args="${MF_QEMU[*]}"

network=$(< "$project/guest/network.sh")
check 'diagnostics start only after the resolver file is final' \
    bash -c 'a=$(grep -n "chmod 0644 /etc/resolv.conf" "$1" | cut -d: -f1); b=$(grep -n "systemd-run --no-block --unit=mayfly-diag" "$1" | cut -d: -f1); [[ -n $a && -n $b && $a -lt $b ]]' _ "$project/guest/network.sh"
check 'diagnostics hook is gated on the fw_cfg diag entry' \
    grep -Fq 'by_name/opt/mayfly/diag/raw' <<< "$network"
build_src=$(< "$project/lib/build.sh")
check 'build uploads the diagnostics script' \
    grep -Fq 'guest/diag.sh:/usr/local/lib/mayfly/diag.sh' <<< "$build_src"
check 'build fetch follows only bounded HTTPS redirects' \
    bash -c 'grep -Fq -- "--location --max-redirs 3" "$1" && grep -Fq -- "--proto-redir '"'"'=https'"'"'" "$1"' _ "$project/lib/build.sh"
check 'guide downloads go through one fetch helper with the redirect policy' \
    bash -c 'n=$(grep -c "curl " "$1"); [[ $n == 1 ]] && grep -q -- "--max-redirs 3" "$1" && grep -q -- "--proto-redir .=https." "$1" && grep -q -- "--proto .=https." "$1"' _ "$project/DEPLOYMENT.md"
jq_quiet() { jq -e "$@" >/dev/null; }
check 'firefox policy file is valid JSON and blocks DoH, WebRTC host IPs and extensions' \
    jq_quiet '.policies.DNSOverHTTPS.Enabled == false and .policies.DNSOverHTTPS.Locked == true
        and .policies.Preferences["network.trr.mode"].Value == 5
        and .policies.Preferences["media.peerconnection.ice.no_host"].Value == true
        and .policies.ExtensionSettings["*"].installation_mode == "blocked"
        and .policies.DisableAppUpdate == true' "$project/guest/firefox-policies.json"
prepare_src=$(< "$project/guest/browser-prepare.sh")
check 'extension blocking applies to Firefox only, never merged into Tor policy' \
    bash -c '[[ $1 != *"ExtensionSettings"* ]]' _ "$prepare_src"
check 'build uploads the Firefox policy file' \
    grep -Fq 'guest/firefox-policies.json:/tmp/firefox-policies.json' <<< "$build_src"
check 'browser account password is locked, not deleted' \
    bash -c '[[ $1 == *"passwd --lock browser"* && $1 != *"passwd --delete"* ]]' _ "$prepare_src"
check 'sudo rule allows poweroff with no arguments only' \
    grep -Fq 'NOPASSWD: /usr/sbin/poweroff ""' <<< "$prepare_src"
runtime_src=$(< "$project/lib/runtime.sh")
check 'launcher forces the Wayland backend and drops X11 variables' \
    bash -c '[[ $1 == *"GDK_BACKEND=wayland"* && $1 == *"unset DISPLAY XAUTHORITY"* ]]' _ "$runtime_src"
check 'launcher removes the profile snapshot once the gateway has started' \
    bash -c 'a=$(grep -n "mf_wait_gateway_socket$" "$1" | tail -1 | cut -d: -f1); b=$(grep -n "rm -f -- \"\$MF_RUN/profile.conf\"" "$1" | cut -d: -f1); [[ -n $a && -n $b && $b -gt $a ]]' _ "$project/lib/runtime.sh"
age_dir=$(mktemp -d)
printf 'x\n' > "$age_dir/browser.sha256"
touch -d '60 days ago' "$age_dir/browser.sha256"
check 'stale base triggers a rebuild warning' \
    bash -c 'source "$1/lib/policy.sh"; source "$1/lib/runtime.sh"; out=$(mf_base_age_warning "$2" 2>&1); [[ $out == *"60 days old"* ]]' _ "$project" "$age_dir"
check 'non-numeric age limit falls back to the default and cannot execute code' \
    bash -c 'source "$1/lib/policy.sh"; source "$1/lib/runtime.sh"; MAYFLY_MAX_BASE_AGE_DAYS="a[\$(touch $3/pwned)]" mf_base_age_warning "$2" >/dev/null 2>&1; [[ ! -e $3/pwned ]]' _ "$project" "$age_dir" "$age_dir"
touch "$age_dir/browser.sha256"
check 'fresh base produces no warning' \
    bash -c 'source "$1/lib/policy.sh"; source "$1/lib/runtime.sh"; out=$(mf_base_age_warning "$2" 2>&1); [[ -z $out ]]' _ "$project" "$age_dir"
rm -r -- "$age_dir"
check 'resolver file is readable by the unprivileged browser user' \
    grep -Fq 'chmod 0644 /etc/resolv.conf' <<< "$network"
prepare=$(< "$project/guest/prepare.sh")
service=$(< "$project/guest/mayfly.service")
network_has() { [[ $network == *"$1"* ]]; }
prepare_has() { [[ $prepare == *"$1"* ]]; }
check 'guest parser reused before network setup' network_has 'mf_parse_profile < /run/mayfly/profile.conf'
check 'guest uses wg setconf not hook interpreter' network_has 'wg setconf wg0'
check 'guest never executes wg-quick' test "$(grep -c '^[[:space:]]*wg-quick' <<< "$network" || :)" = 0
line_of() { grep -nF "$1" <<< "$network" | head -1 | cut -d: -f1; }
check 'atomic firewall installed before WAN comes up' test \
    "$(line_of 'nft --file /run/mayfly/policy.nft')" -lt "$(line_of 'ip link set wan0 up')"
check 'firewall installed before forwarding enabled' test \
    "$(line_of 'nft --file /run/mayfly/policy.nft')" -lt "$(line_of 'net.ipv4.ip_forward=1')"
check 'failure drops WAN interface' network_has 'ip link set wan0 down'
check 'failure powers guest off' network_has 'systemctl --no-block poweroff'
check 'gateway endpoint route pinned, no WAN default route' network_has 'ip route add "$MF_ENDPOINT/32" via 10.0.2.2 dev wan0'
check 'browser path MTU fits lowest supported tunnel MTU' network_has 'ip link set lan0 mtu 1280'
check 'autonomous cloud networking disabled' prepare_has 'network: {config: disabled}'
check 'network manager and networkd masked' prepare_has 'systemd-networkd.socket'
check 'static MAC naming baked into build' prepare_has 'MACAddress=52:54:00:fa:00:'
check 'guest service waits for local NoCloud config' test \
    "$(grep -c '^After=cloud-config.service$' <<< "$service")" = 1
check 'guest avoids cloud-final / multi-user ordering cycle' test \
    "$(grep -c 'cloud-final' <<< "$service" || :)" = 0

mock_lifecycle() {
    local mode=$1 expected=$2 rc=0 pid role
    mkdir -m 700 "$tmp/$mode"
    bash "$project/tests/mock-launch.sh" "$mode" "$tmp/$mode" \
        "$project" "$tmp/profile.conf" >/dev/null 2>&1 || rc=$?
    [[ $rc == "$expected" ]] || return 1
    for role in gateway browser; do
        [[ -f $tmp/$mode/$role.pid ]] || continue
        read -r pid < "$tmp/$mode/$role.pid"
        ! kill -0 "$pid" 2>/dev/null || return 1
    done
    [[ $(find "$tmp/$mode" -mindepth 1 -maxdepth 1 -type d | wc -l) == 0 ]]
}
check 'MOCK gateway death terminates browser and removes session subtree' mock_lifecycle gateway-first 1
check 'MOCK browser exit terminates gateway and removes session subtree' mock_lifecycle browser-first 0
check 'MOCK image creation failure launches nothing and cleans state' mock_lifecycle image-failure 1
check 'MOCK prlimit enforces 3 GiB per-file ceiling' grep -q -- \
    '--core=0:0 --fsize=3221225472:3221225472' "$tmp/gateway-first/gateway.args"
check 'MOCK fw_cfg gets RAM snapshot not persistent credential path' bash -c \
    '[[ $(< "$1") != *"$2"* && $(< "$1") == *"/profile.conf"* ]]' \
    _ "$tmp/gateway-first/gateway.args" "$tmp/profile.conf"
check 'MOCK original synthetic input survives all session cleanup' test -f "$tmp/profile.conf"

mock_signal() {
    local runner i role pid rc=0
    mkdir -m 700 "$tmp/signal"
    bash "$project/tests/mock-launch.sh" signal "$tmp/signal" "$project" \
        "$tmp/profile.conf" >/dev/null 2>&1 &
    runner=$!
    for ((i=0; i<100; i++)); do
        [[ -f $tmp/signal/browser.pid ]] && break
        sleep .05
    done
    if [[ ! -f $tmp/signal/browser.pid ]]; then
        kill -TERM "$runner" 2>/dev/null || :
        wait "$runner" 2>/dev/null || :
        return 1
    fi
    kill -TERM "$runner"
    wait "$runner" || rc=$?
    [[ $rc == 143 ]] || return 1
    for role in gateway browser; do
        read -r pid < "$tmp/signal/$role.pid"
        ! kill -0 "$pid" 2>/dev/null || return 1
    done
    [[ $(find "$tmp/signal" -mindepth 1 -maxdepth 1 -type d | wc -l) == 0 ]]
}
check 'MOCK TERM to actual launcher cleans both direct children and RAM paths' mock_signal
check 'stale or nonchild PID cannot pass ownership predicate' bash -c \
    'source "$1/lib/runtime.sh"; MF_SESSION_PID=$BASHPID; ! mf_child_alive 1 123; ! mf_child_alive "$BASHPID" 123' _ "$project"

mock_build_case() {
    local mode=$1 rc=0
    mkdir -m 700 "$tmp/$mode"
    bash "$project/tests/mock-build.sh" "$mode" "$tmp/$mode" "$project" \
        >/dev/null 2>&1 || rc=$?
    if [[ $mode == build-success ]]; then
        [[ $rc == 0 && -f $tmp/$mode/bases/browser.sha256 &&
           $(stat -c %a "$tmp/$mode/bases/browser.qcow2") == 444 ]] || return 1
    else
        [[ $rc != 0 && ! -e $tmp/$mode/bases/browser.sha256 &&
           ! -e $tmp/$mode/bases/gateway.sha256 ]] || return 1
    fi
}
check 'MOCK full build orchestrates downloads/signature/appliances and publishes readonly hashes last' \
    mock_build_case build-success
check 'MOCK download digest failure prevents base publication' mock_build_case digest-failure
check 'MOCK Tor signature failure prevents base publication' mock_build_case signature-failure
check 'MOCK browser appliance receives official verified archive and desktop packages' grep -q \
    'virt-customize .*--install xorg,lightdm,openbox,firefox-esr.*tor.tar.xz:/tmp/tor.tar.xz' \
    "$tmp/build-success/events"
check 'MOCK no disk resizing follows failed Tor signature' test \
    "$(grep -c '^virt-resize ' "$tmp/signature-failure/events" || :)" = 0

# Test real local manifest/hash/metadata guards against synthetic image bytes.
# Only the qemu-img metadata producer and jq are mocked, clearly not real disks.
mock_base_guard() (
    local dir=$tmp/build-success/bases hash
    qemu-img() { printf '%s\n' '{"format":"qcow2","virtual-size":17179869184}'; }
    jq() { cat >/dev/null; }
    mf_base_check "$dir"
    chmod 600 "$dir/browser.qcow2"
    if mf_base_check "$dir" 2>/dev/null; then return 1; fi
    printf 'tampered synthetic image\n' | dd of="$dir/browser.qcow2" status=none
    chmod 444 "$dir/browser.qcow2"
    if mf_base_check "$dir" 2>/dev/null; then return 1; fi
    hash=$(sha256sum "$dir/browser.qcow2"); hash=${hash%% *}
    chmod 600 "$dir/browser.sha256"
    printf '%s\n' "$hash" | dd of="$dir/browser.sha256" status=none
    chmod 400 "$dir/browser.sha256"
    mf_base_check "$dir"
)
check 'synthetic base guard rejects writable or hash-mismatched bases (metadata MOCK)' mock_base_guard

# ---- seed ISO builder: any one of three ISO tools ----
mf_seed_tool_test() {
    local d rc=0 tool=$1 order=$2 t
    d=$(mktemp -d "${TMPDIR:-/tmp}/mfseed.XXXXXXXX")
    mkdir -p "$d/bin"
    for t in $order; do
        printf '%s\n' '#!/bin/bash' "printf '%s %s\\n' \"\${0##*/}\" \"\$*\" > \"$d/called\"" > "$d/bin/$t"
        chmod 755 "$d/bin/$t"
    done
    : > "$d/user-data"
    PATH="$d/bin" mf_make_seed "$d/seed.iso" "$d/user-data" "$d/meta-data" "$d/network-config" || rc=1
    [[ $(< "$d/called") == "$tool "* && $(< "$d/called") == *"-volid cidata -joliet -rock "* &&
       $(< "$d/called") == *"-output $d/seed.iso"* && $(< "$d/called") == *"$d/user-data $d/meta-data $d/network-config"* ]] || rc=1
    rm -rf -- "$d"; return "$rc"
}
check 'seed builder prefers genisoimage' mf_seed_tool_test genisoimage 'genisoimage mkisofs xorriso'
check 'seed builder falls back to mkisofs' mf_seed_tool_test mkisofs 'mkisofs xorriso'
check 'seed builder falls back to xorriso in mkisofs mode' bash -c '
    source "$1/lib/policy.sh"; source "$1/lib/runtime.sh"
    d=$(mktemp -d); trap "rm -rf -- $d" EXIT; mkdir "$d/bin"
    printf "%s\n" "#!/bin/bash" "echo \"\$*\" > $d/called" > "$d/bin/xorriso"; chmod 755 "$d/bin/xorriso"
    PATH="$d/bin" mf_make_seed "$d/s.iso" a b c; [[ $(< "$d/called") == "-no_rc -as mkisofs -quiet -output $d/s.iso -volid cidata -joliet -rock a b c" ]]' _ "$project"
check 'seed builder reports a missing ISO tool' bash -c '
    source "$1/lib/policy.sh"; source "$1/lib/runtime.sh"
    out=$(PATH=/nonexistent mf_make_seed /tmp/none a 2>&1) && exit 1; [[ $out == *"ISO tool"* ]]' _ "$project"
