#!/bin/bash
# Offline checks for the WSL variant (wsl/*.sh). No WSL, root, network or Windows.
# Standalone on purpose: tests/run.sh and its documented count are unchanged.
set -euo pipefail
export LC_ALL=C
set +x
project=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
source "$project/lib/policy.sh"
source "$project/wsl/netpolicy.sh"

passed=0
failed=0
check() {
    local name=$1
    shift
    if "$@"; then
        printf 'ok - %s\n' "$name"
        ((passed += 1))
    else
        printf 'not ok - %s\n' "$name"
        ((failed += 1))
    fi
}

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
fixture=$(< "$project/tests/fixtures/synthetic.conf")
mf_parse_profile <<< "$fixture"
rules=$(mf_wsl_nft_rules 1000)

has() { grep -Fq -- "$1" <<< "$rules"; }
lacks() { ! grep -Fq -- "$1" <<< "$rules"; }
line_of() { grep -Fn -- "$1" <<< "$rules" | head -n 1 | cut -d: -f1; }

check 'all wsl scripts pass bash -n' bash -c 'for f in "$1"/wsl/*.sh; do bash -n "$f" || exit 1; done' _ "$project"
check 'wsl files are ASCII only (no Unicode dashes)' bash -c \
    '! LC_ALL=C grep -nP "[^\x00-\x7F]" "$1"/wsl/*.sh "$1"/mayfly.ps1 "$1"/tests/wsl/* "$1"/tests/wsl-tests.sh' _ "$project"

# Kill switch rules.
check 'input and output default to drop' bash -c \
    '[[ $(grep -c "policy drop;" <<< "$1") == 2 ]]' _ "$rules"
check 'no forward chain, NAT or VM interface names' bash -c \
    '! grep -Eq "forward|nat|wan0|lan0|masquerade" <<< "$1"' _ "$rules"
check 'IPv6 is dropped in both chains' bash -c \
    '[[ $(grep -c "meta nfproto ipv6 drop" <<< "$1") == 2 ]]' _ "$rules"
check 'only the browser uid may leave, and only through wg0' bash -c \
    '! grep -E "oifname \"wg0\"" <<< "$1" | grep -Ev "skuid 1000|drop$" | grep -q .' _ "$rules"
check 'the only output accept besides lo is wg0' bash -c \
    '[[ $(grep -c "accept" <<< "$(sed -n "/chain output/,\$p" <<< "$1")") == 4 ]]' _ "$rules"
check 'DNS accept names the tunnel resolver for udp and tcp' has "ip daddr $MF_DNS udp dport 53 accept"
check 'DNS accept names the tunnel resolver for tcp' has "ip daddr $MF_DNS tcp dport 53 accept"
check 'DNS accept comes before the other-resolver drop and the special drop' bash -c \
    '(( $1 < $2 && $2 < $3 ))' _ "$(line_of 'udp dport 53 accept')" "$(line_of 'wg0" udp dport 53 drop')" "$(line_of 'ip daddr @special drop')"
check 'the general accept comes last' bash -c \
    '(( $1 > $2 ))' _ "$(line_of "oifname \"wg0\" meta skuid 1000 accept")" "$(line_of 'ip daddr @special drop')"
check 'the special-use set matches MF_SPECIAL' bash -c \
    'for s in "${@:2}"; do grep -Fq "$s" <<< "$1" || exit 1; done' _ "$rules" "${MF_SPECIAL[@]}"
check 'underlay addresses never appear (the tunnel socket stays outside the namespace)' lacks "$MF_ENDPOINT"
check 'a different uid is rendered exactly' bash -c \
    'source "$1/lib/policy.sh"; source "$1/wsl/netpolicy.sh"; mf_parse_profile <<< "$2"; mf_wsl_nft_rules 4242 | grep -Fq "meta skuid 4242 accept"' _ "$project" "$fixture"
check 'rules refuse a bad or root uid' bash -c \
    'source "$1/lib/policy.sh"; source "$1/wsl/netpolicy.sh"; mf_parse_profile <<< "$2"
     ! mf_wsl_nft_rules 0 2>/dev/null && ! mf_wsl_nft_rules "" 2>/dev/null && ! mf_wsl_nft_rules "1000; drop" 2>/dev/null' _ "$project" "$fixture"
check 'rules refuse to render before a profile is parsed' bash -c \
    'source "$1/lib/policy.sh"; source "$1/wsl/netpolicy.sh"; ! mf_wsl_nft_rules 1000 2>/dev/null' _ "$project"
if nft --version >/dev/null 2>&1 && nft --check --file <(printf 'table inet t {}\n') >/dev/null 2>&1; then
    printf '%s\n' "$rules" > "$tmp/policy.nft"
    check 'nft accepts the rendered rules (--check)' nft --check --file "$tmp/policy.nft"
else
    printf 'skip - nft --check unavailable here (needs nft and privileges)\n'
fi

# wg setconf input, MTU and resolver text.
conf=$(mf_wsl_wg_conf <<< "$fixture")
check 'wg conf drops Address, DNS and MTU and comments' bash -c \
    '! grep -Eq "^(Address|DNS|MTU)|^#" <<< "$1"' _ "$conf"
check 'wg conf keeps keys, AllowedIPs and Endpoint, and sets no ListenPort' bash -c \
    'grep -q "^PrivateKey" <<< "$1" && grep -q "^PublicKey" <<< "$1" && grep -q "^AllowedIPs" <<< "$1" &&
     grep -q "^Endpoint" <<< "$1" && ! grep -q ListenPort <<< "$1"' _ "$conf"
check 'MTU defaults to 1420 and honours the profile' bash -c \
    'source "$1/wsl/netpolicy.sh"; [[ $(mf_wsl_profile_mtu <<< "[Interface]") == 1420 &&
     $(printf "[Interface]\nMTU = 1300\n" | mf_wsl_profile_mtu) == 1300 ]]' _ "$project"
check 'tunnel MTU fits the uplink (1280 uplink gives 1220) and never exceeds the profile' bash -c 'source "$1/lib/policy.sh"; source "$1/wsl/netpolicy.sh"
     [[ $(mf_wsl_tunnel_mtu 1420 1280) == 1220 && $(mf_wsl_tunnel_mtu 1420 1500) == 1420 && $(mf_wsl_tunnel_mtu 1300 1500) == 1300 && $(mf_wsl_tunnel_mtu 1420 500) == 576 ]]' _ "$project"
check 'tunnel MTU uses a larger overhead for wireguard-go (1280 uplink, 80 overhead gives 1200)' bash -c 'source "$1/lib/policy.sh"; source "$1/wsl/netpolicy.sh"; [[ $(mf_wsl_tunnel_mtu 1420 1280 80) == 1200 && $(mf_wsl_tunnel_mtu 1420 1280) == 1220 ]]' _ "$project"
check 'tunnel MTU rejects non-numeric input' bash -c 'source "$1/lib/policy.sh"; source "$1/wsl/netpolicy.sh"; ! mf_wsl_tunnel_mtu 14x0 1500 2>/dev/null' _ "$project"
check 'resolv.conf names only the tunnel resolver' bash -c \
    'source "$1/lib/policy.sh"; source "$1/wsl/netpolicy.sh"; mf_parse_profile <<< "$2"
     [[ $(mf_wsl_resolv | grep -c nameserver) == 1 ]] && mf_wsl_resolv | grep -Fqx "nameserver $MF_DNS"' _ "$project" "$fixture"

# Preflight predicates against fixtures.
check_pf() { # name expect(0|1) function env...
    local name=$1 expect=$2 fn=$3 rc=0 out
    shift 3
    out=$(env -u WSL_INTEROP "$@" bash -c 'source "$1/wsl/preflight.sh"; "$2"' _ "$project" "$fn" 2>&1) || rc=$?
    [[ $expect == 0 && $rc == 0 ]] || [[ $expect == 1 && $rc != 0 ]] || { printf '%s\n' "$out" >&2; return 1; }
}
printf 'Filename Type Size Used Priority\n' > "$tmp/swaps-empty"
printf 'Filename Type Size Used Priority\n/dev/sdc partition 8388608 0 -2\n' > "$tmp/swaps-on"
check 'preflight: empty /proc/swaps passes' check_pf swap 0 mf_wsl_check_swap MF_WSL_SWAPS="$tmp/swaps-empty"
check 'preflight: active swap fails and says swap=0' bash -c \
    'out=$(MF_WSL_SWAPS="$2" bash -c "source \"\$1/wsl/preflight.sh\"; mf_wsl_check_swap" _ "$1" 2>&1) && exit 1; [[ $out == *swap=0* && $out == *"wsl --shutdown"* ]]' _ "$project" "$tmp/swaps-on"
check 'preflight: unreadable swap file fails closed' check_pf swap 1 mf_wsl_check_swap MF_WSL_SWAPS="$tmp/missing"
printf '[interop]\nenabled=false\nappendWindowsPath=false\n[automount]\nenabled=false\n' > "$tmp/wsl-off"
printf '[interop]\nenabled=true\n' > "$tmp/wsl-on"
printf 'tmpfs /run tmpfs rw 0 0\ndrivers /usr/lib/wsl/drivers 9p ro 0 0\nnone /mnt/wslg tmpfs rw 0 0\n' > "$tmp/mounts-ok"
printf 'tmpfs /run tmpfs rw 0 0\nC:\\134 /mnt/c 9p rw 0 0\n' > "$tmp/mounts-c"
check 'preflight: interop off with no Windows PATH passes' check_pf interop 0 mf_wsl_check_interop \
    MF_WSL_CONF="$tmp/wsl-off" MF_WSL_MOUNTS="$tmp/mounts-ok" PATH=/usr/bin:/bin
check 'preflight: interop enabled in wsl.conf fails' check_pf interop 1 mf_wsl_check_interop \
    MF_WSL_CONF="$tmp/wsl-on" MF_WSL_MOUNTS="$tmp/mounts-ok" PATH=/usr/bin:/bin
check 'preflight: a Windows directory in PATH fails' check_pf interop 1 mf_wsl_check_interop \
    MF_WSL_CONF="$tmp/wsl-off" MF_WSL_MOUNTS="$tmp/mounts-ok" PATH=/usr/bin:/mnt/c/Windows/System32
check 'preflight: an inherited interop socket variable fails' check_pf interop 1 mf_wsl_check_interop \
    MF_WSL_CONF="$tmp/wsl-off" MF_WSL_MOUNTS="$tmp/mounts-ok" PATH=/usr/bin:/bin WSL_INTEROP=/run/WSL/1_interop
check 'preflight: a mounted Windows drive fails; the WSLg and driver mounts do not' check_pf interop 1 mf_wsl_check_interop \
    MF_WSL_CONF="$tmp/wsl-off" MF_WSL_MOUNTS="$tmp/mounts-c" PATH=/usr/bin:/bin
check 'preflight: a missing wsl.conf fails (interop state unknown)' check_pf interop 1 mf_wsl_check_interop \
    MF_WSL_CONF="$tmp/none" MF_WSL_MOUNTS="$tmp/mounts-ok" PATH=/usr/bin:/bin
printf 'nodev\tsysfs\nnodev\toverlay\next4\n' > "$tmp/fs-ok"
printf 'nodev\tsysfs\next4\n' > "$tmp/fs-no"
check 'preflight: overlayfs present passes' check_pf overlay 0 mf_wsl_check_overlay MF_WSL_FILESYSTEMS="$tmp/fs-ok"
check 'preflight: overlayfs absent fails' check_pf overlay 1 mf_wsl_check_overlay MF_WSL_FILESYSTEMS="$tmp/fs-no"
mkdir "$tmp/wgmod"
check 'preflight: a loaded wireguard module passes' check_pf wg 0 mf_wsl_check_wireguard MF_WSL_SYSMODULE="$tmp/wgmod"
check 'preflight: no module and no wireguard-go fails' check_pf wg 1 mf_wsl_check_wireguard \
    MF_WSL_SYSMODULE="$tmp/none" MF_WSL_TUN="$tmp/none" PATH=/nonexistent
check 'preflight: no Wayland socket fails' check_pf wslg 1 mf_wsl_check_wslg MF_WSL_WSLG="$tmp/none"
check 'preflight: a user that is not uid 1000 fails' check_pf user 1 mf_wsl_check_user MF_WSL_USER=root
check 'preflight: a missing user fails' check_pf user 1 mf_wsl_check_user MF_WSL_USER=no-such-user-mayfly

# session.sh against a copy of the library directory.
mkdir "$tmp/lib"
cp "$project/lib/policy.sh" "$project/wsl/netpolicy.sh" "$project/wsl/preflight.sh" "$tmp/lib/"
session() { MF_WSL_LIB="$tmp/lib" bash "$project/wsl/session.sh" "$@"; }
check 'session.sh with no arguments is a usage error (64)' bash -c \
    'MF_WSL_LIB="$2" bash "$1/wsl/session.sh" 2>/dev/null; [[ $? == 64 ]]' _ "$project" "$tmp/lib"
check 'session.sh run rejects an unknown entry (64)' bash -c \
    'MF_WSL_LIB="$2" bash "$1/wsl/session.sh" run chrome </dev/null 2>/dev/null; [[ $? == 64 ]]' _ "$project" "$tmp/lib"
check 'session.sh check-profile accepts the fixture and prints no key' bash -c \
    'out=$(MF_WSL_LIB="$3" bash "$1/wsl/session.sh" check-profile <<< "$2" 2>&1) &&
     [[ $out == "ok: "* && $out != *AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=* ]]' _ "$project" "$fixture" "$tmp/lib"
check 'session.sh check-profile rejects hooks without echoing them' bash -c \
    'out=$(MF_WSL_LIB="$3" bash "$1/wsl/session.sh" check-profile <<< "${2/\[Peer\]/PostUp = touch /tmp/pwned$'"'"'\n'"'"'[Peer]}" 2>&1) && exit 1
     [[ $out == BLOCKED:* && $out != *pwned* ]]' _ "$project" "$fixture" "$tmp/lib"
check 'session.sh run refuses while swap is active and starts nothing' bash -c \
    'out=$(MF_WSL_LIB="$3" MF_WSL_SWAPS="$2" bash "$1/wsl/session.sh" run firefox </dev/null 2>&1) && exit 1
     [[ $out == *swap=0* && $out == *"nothing was started"* ]]' _ "$project" "$tmp/swaps-on" "$tmp/lib"

# Shared Linux hardening: the policy function is read from guest/browser-prepare.sh.
if jq --version >/dev/null 2>&1; then
check 'extracted merge keeps hardening and adds update suppression' bash -c '
    project=$1
    work=$(mktemp -d); trap "rm -rf -- \"$work\"" EXIT
    install() { local a=(); while (( $# )); do case $1 in -o|-g|-m) shift 2 ;; *) a+=("$1"); shift ;; esac; done; command install "${a[@]}"; }
    source <(tr -d "\r" < "$project/guest/browser-prepare.sh" | sed -n "/^mf_browser_update_policies() {/,/^}/p")
    declare -F mf_browser_update_policies >/dev/null
    cp "$project/guest/firefox-policies.json" "$work/policies.json"
    mf_browser_update_policies "$work/policies.json"
    jq -e ".policies.DisableAppUpdate == true and .policies.HttpsOnlyMode == \"enabled\"" "$work/policies.json" >/dev/null' _ "$project"
else
    printf 'skip - jq is not installed\n'
fi
check 'provision.sh installs the shared files and reads the merge from browser-prepare.sh' bash -c \
    'for p in "copy lib/policy.sh" "copy guest/i2p-user.js" "mf_browser_update_policies() {" "guest/firefox-policies.json" "/etc/wsl.conf" "enabled=false" "appendWindowsPath=false"; do
         grep -Fq -- "$p" "$1/wsl/provision.sh" || exit 1; done' _ "$project"
check 'provision.sh verifies Tor Browser against the pinned fingerprint with the Linux pins and fetch code' bash -c \
    'for p in mf_pins_parse_tor_json MF_TOR_FPR gpgv "lib/pins.sh" "mf_fetch() {"; do
         grep -Fq -- "$p" "$1/wsl/provision.sh" || exit 1; done' _ "$project"
check 'session.sh accepts the tor entry and refuses to run it when Tor Browser is missing' bash -c \
    'grep -Fq "entry == tor" "$1/wsl/session.sh" && grep -Fq "Tor Browser is not installed" "$1/wsl/session.sh"' _ "$project"
check 'provision.sh disables automount and interop and creates uid 1000 browser' bash -c \
    'grep -Fq "useradd --uid 1000" "$1/wsl/provision.sh" && grep -Fq "[automount]" "$1/wsl/provision.sh" && grep -Fq "[interop]" "$1/wsl/provision.sh"' _ "$project"

printf '\n%s passed, %s failed. OFFLINE WSL component checks, not live acceptance.\n' "$passed" "$failed"
(( failed == 0 ))
