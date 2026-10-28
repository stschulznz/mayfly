#!/bin/bash
# Pure text renderers for the WSL variant. No network or mount mutations here.
# Sourced after lib/policy.sh, which supplies the profile parser and MF_SPECIAL.
# Callers must not enable tracing when handling profiles.

# Rules loaded INSIDE the per-session network namespace, which holds only lo and
# wg0. WSL2 distros share one network namespace, so these rules must never be
# loaded outside it. $1 is the numeric uid of the browser user.
mf_wsl_nft_rules() {
    [[ ${MF_VALID:-0} == 1 ]] ||
        { mf_error 'parse a supported profile before generating policy'; return 1; }
    [[ ${1:-} =~ ^[1-9][0-9]{0,8}$ ]] ||
        { mf_error 'a numeric browser uid is required'; return 1; }
    local uid=$1 elements='' subnet
    for subnet in "${MF_SPECIAL[@]}"; do
        elements+="${elements:+, }$subnet"
    done
    printf '%s\n' \
        'table inet mayfly {' \
        '  set special { type ipv4_addr; flags interval; auto-merge;' \
        "    elements = { $elements }" \
        '  }' \
        '  chain input {' \
        '    type filter hook input priority 0; policy drop;' \
        '    meta nfproto ipv6 drop' \
        '    iifname "lo" accept' \
        '    iifname "wg0" ct state established,related accept' \
        '  }' \
        '  chain output {' \
        '    type filter hook output priority 0; policy drop;' \
        '    meta nfproto ipv6 drop' \
        '    oifname "lo" accept' \
        "    oifname \"wg0\" meta skuid $uid ip daddr $MF_DNS udp dport 53 accept" \
        "    oifname \"wg0\" meta skuid $uid ip daddr $MF_DNS tcp dport 53 accept" \
        '    oifname "wg0" udp dport 53 drop' \
        '    oifname "wg0" tcp dport 53 drop' \
        '    oifname "wg0" ip daddr @special drop' \
        "    oifname \"wg0\" meta skuid $uid accept" \
        '  }' \
        '}'
}

# stdin: a profile already accepted by mf_parse_profile. stdout: the part that
# "wg setconf" accepts. Address, DNS and MTU are applied by the caller.
mf_wsl_wg_conf() {
    awk '
        /^[ \t]*#/ || /^[ \t]*$/ {next}
        /^[ \t]*(Address|DNS|MTU)[ \t]*=/ {next}
        {print}
    '
}

# stdin: an accepted profile. stdout: the MTU, 1420 when absent.
mf_wsl_profile_mtu() {
    local mtu
    mtu=$(awk -F= '/^[ \t]*MTU[ \t]*=/ {gsub(/[ \t\r]/,"",$2); print $2}')
    printf '%s\n' "${mtu:-1420}"
}

# $1 profile MTU, $2 MTU of the uplink that carries the encrypted packets, $3 overhead (default 60,
# the kernel module over IPv4; wireguard-go needs 80, found by test). The tunnel MTU must fit in the
# uplink minus the overhead. WSL uplinks can be as low as 1280.
mf_wsl_tunnel_mtu() {
    local want=$1 uplink=$2 overhead=${3:-60} fit
    [[ $want =~ ^[0-9]+$ && $uplink =~ ^[0-9]+$ && $overhead =~ ^[0-9]+$ ]] || { mf_error 'MTU values must be numbers'; return 1; }
    fit=$(( uplink - overhead ))
    (( fit < 576 )) && fit=576
    (( want < fit )) && fit=$want
    printf '%s\n' "$fit"
}

# Render the sandbox resolv.conf: only the tunnel resolver.
mf_wsl_resolv() {
    printf 'nameserver %s\noptions attempts:2 timeout:2\n' "$MF_DNS"
}
