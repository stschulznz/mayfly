#!/bin/bash
# Offline synthetic component tests. No KVM, credentials, network or sudo.
set -euo pipefail
export LC_ALL=C
set +x
project=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
source "$project/lib/policy.sh"
source "$project/lib/host.sh"
source "$project/lib/runtime.sh"
source "$project/lib/build.sh"

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

reject_profile() {
    local diagnostic
    if diagnostic=$(mf_parse_profile <<< "$1" 2>&1); then
        return 1
    fi
    # Never let parser errors echo credentials, payloads, or endpoint values.
    [[ $diagnostic == BLOCKED:* &&
       $diagnostic != *AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=* &&
       $diagnostic != *1.1.1.1* ]]
}

replace_rejected() {
    local altered=${fixture/"$1"/"$2"}
    [[ $altered != "$fixture" ]] && reject_profile "$altered"
}

fixture=$(< "$project/tests/fixtures/synthetic.conf")
check 'one IPv4 full-tunnel profile accepted' mf_parse_profile <<< "$fixture"
check 'public endpoint retained as data' test "$MF_ENDPOINT" = 1.1.1.1
check 'resolver retained as data' test "$MF_DNS" = 10.80.0.1
check 'metadata does not retain last parsed value' test "$MF_TRIMMED" = ''
check 'hooks rejected' replace_rejected 'MTU = 1380' 'PostUp = false'
check 'pre-up hooks rejected' replace_rejected 'MTU = 1380' 'PreUp = false'
check 'includes rejected' replace_rejected 'MTU = 1380' 'Include = /dev/null'
check 'routing tables rejected' replace_rejected 'MTU = 1380' 'Table = off'
check 'save-config rejected' replace_rejected 'MTU = 1380' 'SaveConfig = true'
check 'fwmark routing rejected' replace_rejected 'MTU = 1380' 'FwMark = 123'
check 'unknown fields rejected' replace_rejected 'MTU = 1380' 'Unknown = anything'
check 'shell substitution is rejected as data' replace_rejected 'DNS = 10.80.0.1' 'DNS = $(false)'
check 'array-subscript injection is rejected as data' replace_rejected 'MTU = 1380' 'x[$(false)] = 1'
check 'semicolon injection rejected' replace_rejected 'DNS = 10.80.0.1' 'DNS = 10.80.0.1; false'
check 'duplicate field rejected' reject_profile "$fixture"$'\nEndpoint = 1.1.1.1:51820'
check 'multiple peers rejected' reject_profile "$fixture"$'\n[Peer]'
check 'reordered Interface rejected' replace_rejected '[Interface]' '[Peer]'
check 'missing private key rejected' replace_rejected \
    'PrivateKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=' '# omitted'
check 'bad key encoding rejected' replace_rejected \
    'PrivateKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=' 'PrivateKey = short'
check 'hostname endpoints rejected' replace_rejected '1.1.1.1:51820' 'example.invalid:51820'
check 'IPv6 endpoints rejected' replace_rejected '1.1.1.1:51820' '[2001:db8::1]:51820'
check 'IPv6 routes rejected' replace_rejected 'AllowedIPs = 0.0.0.0/0' 'AllowedIPs = ::/0'
check 'dual stack routes rejected' replace_rejected 'AllowedIPs = 0.0.0.0/0' 'AllowedIPs = 0.0.0.0/0, ::/0'
check 'split tunnels rejected' replace_rejected 'AllowedIPs = 0.0.0.0/0' 'AllowedIPs = 0.0.0.0/1'
check 'IPv6 resolver rejected' replace_rejected 'DNS = 10.80.0.1' 'DNS = 2001:db8::1'
check 'hostname resolver rejected' replace_rejected 'DNS = 10.80.0.1' 'DNS = example.invalid'
check 'multiple resolvers rejected' replace_rejected 'DNS = 10.80.0.1' 'DNS = 1.1.1.1, 8.8.8.8'
check 'slirp DNS resolver rejected' replace_rejected 'DNS = 10.80.0.1' 'DNS = 10.0.2.3'
check 'gateway LAN resolver rejected' replace_rejected 'DNS = 10.80.0.1' 'DNS = 192.168.250.1'
check 'self resolver rejected' replace_rejected 'DNS = 10.80.0.1' 'DNS = 10.80.0.2'
check 'resolver conflicting with WAN endpoint route rejected' replace_rejected 'DNS = 10.80.0.1' 'DNS = 1.1.1.1'
check 'gateway LAN address conflict rejected' replace_rejected '10.80.0.2/32' '192.168.250.1/32'
check 'slirp address conflict rejected' replace_rejected '10.80.0.2/32' '10.0.2.15/32'
check 'unsupported address prefix rejected' replace_rejected '10.80.0.2/32' '10.80.0.2/24'
check 'port zero rejected' replace_rejected '1.1.1.1:51820' '1.1.1.1:0'
check 'port overflow rejected' replace_rejected '1.1.1.1:51820' '1.1.1.1:65536'
check 'noncanonical port rejected' replace_rejected '1.1.1.1:51820' '1.1.1.1:051820'
check 'noncanonical IPv4 rejected' replace_rejected '1.1.1.1:51820' '01.1.1.1:51820'
check 'invalid IPv4 rejected' replace_rejected '1.1.1.1:51820' '256.1.1.1:51820'
check 'MTU below supported range rejected' replace_rejected 'MTU = 1380' 'MTU = 1279'
check 'keepalive overflow rejected' replace_rejected 'PersistentKeepalive = 25' 'PersistentKeepalive = 65536'

for address in 0.1.2.3 10.0.2.2 100.64.0.1 127.0.0.1 169.254.169.254 \
    172.16.0.1 192.0.0.1 192.0.2.1 192.88.99.1 192.168.0.1 \
    198.18.0.1 198.51.100.1 203.0.113.1 224.0.0.1 255.255.255.255; do
    check "special-use endpoint denied: $address" replace_rejected '1.1.1.1:51820' "$address:51820"
done

reject_nul() {
    local diagnostic
    if diagnostic=$(printf '%s\0%s' "$fixture" 'ignored' | mf_parse_profile 2>&1); then
        return 1
    fi
    [[ $diagnostic == *'NUL byte'* ]]
}
check 'NUL bytes cannot be silently skipped' reject_nul
printf -v oversize '%17000s' ''
check 'oversized input rejected' reject_profile "$oversize"
check 'empty input rejected' reject_profile ''

# Structural checks only. These do not execute nft or model kernel conntrack.
mf_parse_profile <<< "$fixture"
rules=$(mf_nft_rules)
has_rule() { [[ $rules == *"$1"* ]]; }
lacks_rule() { [[ $rules != *"$1"* ]]; }
check 'input default deny' has_rule 'type filter hook input priority 0; policy drop;'
check 'output default deny' has_rule 'type filter hook output priority 0; policy drop;'
check 'forward default deny' has_rule 'type filter hook forward priority 0; policy drop;'
check 'WAN egress endpoint and protocol pinned' has_rule \
    'oifname "wan0" ip daddr 1.1.1.1 udp sport 51820 udp dport 51820 accept'
check 'WAN return endpoint and state pinned' has_rule \
    'iifname "wan0" ip saddr 1.1.1.1 udp sport 51820 udp dport 51820 ct state established accept'
check 'browser egress requires LAN ingress and tunnel egress' has_rule \
    'iifname "lan0" oifname "wg0" ip saddr 192.168.250.2 accept'
check 'return state scoped to tunnel and browser interfaces' has_rule \
    'iifname "wg0" oifname "lan0" ip daddr 192.168.250.2 ct state established,related accept'
check 'private tunnel DNS exception scoped by source and both interfaces' has_rule \
    'iifname "lan0" oifname "wg0" ip saddr 192.168.250.2 ip daddr 10.80.0.1 udp dport 53 accept'
check 'other classic DNS denied' has_rule 'iifname "lan0" oifname "wg0" tcp dport 53 drop'
check 'LAN and special-use destinations denied' has_rule \
    'iifname "lan0" oifname "wg0" ip daddr @special drop'
check 'NAT on tunnel only' has_rule 'oifname "wg0" ip saddr 192.168.250.2 masquerade'
check 'no browser forwarding to WAN' lacks_rule 'iifname "lan0" oifname "wan0"'
check 'no blanket established allowance' lacks_rule $'\n    ct state established'
check 'no WAN masquerade' lacks_rule 'oifname "wan0" masquerade'
check 'no guest ruleset flushing' lacks_rule 'flush ruleset'
check 'all filter hooks deny IPv6' test "$(grep -c 'meta nfproto ipv6 drop' <<< "$rules")" = 3
for subnet in "${MF_SPECIAL[@]}"; do
    check "deny set includes $subnet" has_rule "$subnet"
done
MF_VALID=0
check 'unparsed metadata cannot render policy' bash -c \
    'source "$1/lib/policy.sh"; ! mf_nft_rules 2>/dev/null' _ "$project"

safe_snapshot() {
    MF_HOST=(
        [ram_fs]=tmpfs [ram_owner]="$UID" [ram_mode]=700
        [ram_options]=rw,nosuid,nodev,noexec,relatime [ram_size]=34359738368
        [ram_available]=30000000000 [resume_offset]=0 [resume_config]=none
        [mem_available]=30000000000 [power_state]='freeze mem'
        [resume]=0:0 [crash_loaded]=0 [crash_size]=0
        [core_pattern]=core [suid_dumpable]=0 [core_soft]=0 [core_hard]=0
        [swap_safe]=yes [kvm]=yes
    )
}
bad_snapshot() {
    local key=$1 value=$2 diagnostic
    safe_snapshot
    MF_HOST[$key]=$value
    if diagnostic=$(mf_check_host_snapshot 2>&1); then
        return 1
    fi
    [[ $diagnostic == BLOCKED:* ]]
}
safe_snapshot
check 'synthetic safe snapshot passes predicates only' mf_check_host_snapshot
check 'disk filesystem refused despite RAM-like path' bad_snapshot ram_fs ext4
check 'unbounded ramfs refused' bad_snapshot ram_fs ramfs
check 'shared RAM directory refused' bad_snapshot ram_mode 1777
check 'wrong RAM directory owner refused' bad_snapshot ram_owner 999999
safe_snapshot
MF_HOST[ram_options]=rw,nosuid,nodev
check 'noexec not required for nonexecuted session data' mf_check_host_snapshot
safe_snapshot
MF_HOST[power_state]='freeze mem disk'
check 'disk capability alone is not configured hibernation' mf_check_host_snapshot
check 'missing nodev refused' bad_snapshot ram_options rw,nosuid
check 'low tmpfs free capacity refused' bad_snapshot ram_available 1024
check 'small tmpfs refused' bad_snapshot ram_size 1024
check 'unknown tmpfs bound refused' bad_snapshot ram_size unknown
check 'noncanonical numeric bound refused' bad_snapshot ram_size 08
check 'insufficient memory refused' bad_snapshot mem_available 1024
check 'missing memory evidence refused' bad_snapshot mem_available ''
check 'disk swap or zram writeback refused' bad_snapshot swap_safe no
check 'unreadable swap evidence refused' bad_snapshot swap_safe unknown
check 'configured resume kernel argument refused' bad_snapshot resume_config configured
check 'unknown resume arguments refused' bad_snapshot resume_config unknown
check 'configured resume offset refused' bad_snapshot resume_offset 2048
check 'unknown power state refused' bad_snapshot power_state unknown
check 'configured resume device refused' bad_snapshot resume 8:1
check 'loaded kdump refused' bad_snapshot crash_loaded 1
check 'reserved crash memory refused' bad_snapshot crash_size 134217728
check 'unknown kdump state refused' bad_snapshot crash_loaded unknown
check 'piped core collector refused even with zero rlimit' bad_snapshot core_pattern '|/example/collector'
check 'nonzero soft core limit refused' bad_snapshot core_soft unlimited
check 'nonzero hard core limit refused' bad_snapshot core_hard unlimited
check 'suid dump state refused' bad_snapshot suid_dumpable 2
check 'inaccessible KVM refused' bad_snapshot kvm no
reject_swap() { ! mf_swap_record_safe "$@"; }
check 'zram without backing storage accepted as record' mf_swap_record_safe /dev/zram0 partition none
check 'disk-backed zram record refused' reject_swap /dev/zram0 partition /dev/example
check 'unknown zram backing record refused' reject_swap /dev/zram0 partition unknown
check 'disk partition swap record refused' reject_swap /dev/example partition none
check 'swapfile record refused' reject_swap /example/swapfile file none
check 'fake zram pathname refused' reject_swap /dev/zram0/other partition none
MF_HOST=()
check 'missing snapshot cannot pass' bash -c \
    'source "$1/lib/policy.sh"; source "$1/lib/host.sh"; ! mf_check_host_snapshot 2>/dev/null' _ "$project"

# Only synthetic fixtures are copied. No real profile or VM state is accessed.
tmp=$(mktemp -d)
tmp=$(realpath -e -- "$tmp")
cleanup() {
    # Explicit task-owned files only, never recursive cleanup or shared tmpdirs.
    mf_remove_tree "$tmp"
}
trap cleanup EXIT
install -m 600 -- "$project/tests/fixtures/synthetic.conf" "$tmp/profile.conf"
check 'private outside-source fixture metadata accepted' mf_private_profile_file "$tmp/profile.conf" "$project"

private_reject() {
    local diagnostic
    if diagnostic=$(mf_private_profile_file "$1" "$2" 2>&1); then
        return 1
    fi
    [[ $diagnostic == BLOCKED:* ]]
}
chmod 644 "$tmp/profile.conf"
check 'readable-by-others profile refused' private_reject "$tmp/profile.conf" "$project"
chmod 600 "$tmp/profile.conf"
chmod 755 "$tmp"
check 'shared profile parent refused' private_reject "$tmp/profile.conf" "$project"
chmod 700 "$tmp"
ln -s "$tmp/profile.conf" "$tmp/link.conf"
check 'symlink profile refused' private_reject "$tmp/link.conf" "$project"
ln "$tmp/profile.conf" "$tmp/hard.conf"
check 'hardlinked profile refused' private_reject "$tmp/hard.conf" "$project"
rm -- "$tmp/hard.conf"
check 'in-source credentials refused' private_reject "$tmp/profile.conf" "$tmp"
check 'noncanonical credential path refused' private_reject "$tmp/../${tmp##*/}/profile.conf" "$project"
check 'relative credential path refused' private_reject 'profile.conf' "$project"
check 'missing credential file refused' private_reject "$tmp/missing" "$project"
ln -s "$tmp" "$tmp/state-link"
check 'symlink runtime directory refused' bash -c \
    'source "$1/lib/policy.sh"; source "$1/lib/host.sh"; ! mf_host_snapshot "$2" 2>/dev/null' _ "$project" "$tmp/state-link"

exit_is() {
    local expected=$1 actual=0 output
    shift
    output=$(bash "$project/mayfly.sh" "$@" 2>&1) || actual=$?
    [[ $actual == "$expected" ]]
}
profile_rc=0
# Main CLI hardens its own core limits; inspect only nonsecret kernel policy
# here to account for hosts where a piped collector makes parsing unsafe.
core_pattern=$(mf_read_state /proc/sys/kernel/core_pattern)
[[ -n $core_pattern && $core_pattern != unknown && $core_pattern != \|* ]] || profile_rc=1
check 'profile CLI parses protected synthetic input only when dump policy permits' \
    exit_is "$profile_rc" check-profile "$tmp/profile.conf"
check 'no command rejected' exit_is 64
check 'unknown command rejected' exit_is 64 anything
check 'extra profile argument rejected' exit_is 64 check-profile "$tmp/profile.conf" extra
check 'relative profile argument rejected' exit_is 64 check-profile relative.conf
check 'extra doctor argument rejected' exit_is 64 doctor "$tmp" extra
check 'missing doctor argument rejected' exit_is 64 doctor
check 'build rejects extra arguments and non-name, non-path words' exit_is 64 build /a /b /c
check 'launch rejects relative base paths with extra arguments' exit_is 64 launch a/b c d e
check 'QEMU passthrough rejected' exit_is 64 launch -netdev user
check 'build passthrough rejected' exit_is 64 build --unsafe
doctor_never_claims_readiness() {
    local rc=0 output
    output=$(bash "$project/mayfly.sh" doctor "$tmp" 2>&1) || rc=$?
    [[ $rc == 0 || $rc == 78 ]] &&
        [[ $output == *'never live routing or full operational readiness'* ]]
}
check 'doctor never implies operational readiness' doctor_never_claims_readiness
check 'no runtime files created by blocked commands' test "$(find "$tmp" -maxdepth 1 -type f | wc -l)" = 1

source "$project/tests/runtime-tests.sh"
source "$project/tests/regression-tests.sh"
source "$project/tests/host-tests.sh"
source "$project/tests/i2p-tests.sh"
source "$project/tests/preflight-tests.sh"
source "$project/tests/capture-tests.sh"
source "$project/tests/setup-tests.sh"
source "$project/tests/attach-tests.sh"
printf '\n%s passed, %s failed. OFFLINE component checks, not live VM acceptance.\n' "$passed" "$failed"
(( failed == 0 ))
