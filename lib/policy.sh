#!/bin/bash
# Data-only profile parsing and pure firewall rendering; no network mutations.
# Callers must not enable tracing when handling profiles.

mf_error() {
    printf 'BLOCKED: %s\n' "$1" >&2
    return 1
}

mf_uint() {
    [[ $1 =~ ^(0|[1-9][0-9]{0,8})$ ]] && (( 10#$1 <= $2 ))
}

mf_ipv4() {
    local part
    local -a parts
    [[ $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    IFS=. read -r -a parts <<< "$1"
    for part in "${parts[@]}"; do
        mf_uint "$part" 255 || return 1
    done
}

mf_ip_number() {
    local a b c d
    mf_ipv4 "$1" || return 1
    IFS=. read -r a b c d <<< "$1"
    printf '%s\n' "$(( (10#$a << 24) | (10#$b << 16) | (10#$c << 8) | 10#$d ))"
}

# Conservative special-use deny set, shared by validation and nft generation.
# No claim that blocking this set is sufficient for anonymity.
MF_SPECIAL=(
    0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8
    169.254.0.0/16 172.16.0.0/12 192.0.0.0/24 192.0.2.0/24
    192.88.99.0/24 192.168.0.0/16 198.18.0.0/15 198.51.100.0/24
    203.0.113.0/24 224.0.0.0/4 240.0.0.0/4
)

mf_in_subnet() {
    local ip network prefix mask
    ip=$(mf_ip_number "$1") || return 1
    network=$(mf_ip_number "${2%/*}") || return 1
    prefix=${2#*/}
    mf_uint "$prefix" 32 || return 1
    mask=$(( (0xffffffff << (32 - prefix)) & 0xffffffff ))
    (( (ip & mask) == (network & mask) ))
}

mf_public_ipv4() {
    local subnet
    mf_ipv4 "$1" || return 1
    for subnet in "${MF_SPECIAL[@]}"; do
        if mf_in_subnet "$1" "$subnet"; then
            return 1
        fi
    done
}

mf_tunnel_address() {
    # Deliberately narrow supported profile: one usable IPv4 /32.
    local ip=${1%/32}
    [[ $1 == */32 ]] && mf_ipv4 "$ip" || return 1
    ! mf_in_subnet "$ip" 0.0.0.0/8 &&
        ! mf_in_subnet "$ip" 127.0.0.0/8 &&
        ! mf_in_subnet "$ip" 169.254.0.0/16 &&
        ! mf_in_subnet "$ip" 192.168.250.0/30 &&
        ! mf_in_subnet "$ip" 10.0.2.0/24 &&
        ! mf_in_subnet "$ip" 224.0.0.0/3
}

mf_trim() {
    MF_TRIMMED=${1#"${1%%[!$' \t\r']*}"}
    MF_TRIMMED=${MF_TRIMMED%"${MF_TRIMMED##*[!$' \t\r']}"}
}

mf_parse_profile() {
    # Input is data, never shell. Keep only nonsecret metadata after parsing.
    # All diagnostics are fixed strings: never interpolate keys, lines or values.
    local payload='' line section='' key value id
    local interface_seen=0 peer_seen=0 count=0
    local -A seen=()
    MF_VALID=0
    MF_ADDRESS='' MF_DNS='' MF_ENDPOINT='' MF_PORT=''
    if IFS= read -r -d '' payload; then
        mf_error 'profile contains a NUL byte'; return 1
    fi
    if (( ${#payload} > 16384 )); then
        mf_error 'profile exceeds 16 KiB'; return 1
    fi
    while IFS= read -r line || [[ -n $line ]]; do
        ((count += 1))
        ((count <= 100)) || { mf_error 'too many profile lines'; return 1; }
        mf_trim "$line"; line=$MF_TRIMMED
        [[ -z $line || $line == \#* ]] && continue
        case $line in
            '[Interface]')
                (( interface_seen == 0 && peer_seen == 0 )) ||
                    { mf_error 'duplicate or reordered Interface'; return 1; }
                interface_seen=1; section=Interface; continue ;;
            '[Peer]')
                (( interface_seen == 1 && peer_seen == 0 )) ||
                    { mf_error 'exactly one Peer is supported'; return 1; }
                peer_seen=1; section=Peer; continue ;;
        esac
        [[ -n $section && $line == *=* ]] ||
            { mf_error 'invalid profile structure'; return 1; }
        mf_trim "${line%%=*}"; key=$MF_TRIMMED
        mf_trim "${line#*=}"; value=$MF_TRIMMED
        # Check a literal whitelist before constructing any array subscript.
        case "$section/$key" in
            Interface/PrivateKey|Interface/Address|Interface/DNS|Interface/MTU|\
            Peer/PublicKey|Peer/PresharedKey|Peer/AllowedIPs|Peer/Endpoint|\
            Peer/PersistentKeepalive) ;;
            *) mf_error 'unsupported profile field (hooks and helpers forbidden)'; return 1 ;;
        esac
        id=$section/$key
        [[ ! ${seen[$id]+present} ]] ||
            { mf_error 'duplicate profile field'; return 1; }
        seen[$id]=1
        case $key in
            PrivateKey|PublicKey|PresharedKey)
                [[ $value =~ ^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw048]=$ ]] ||
                    { mf_error 'invalid key encoding'; return 1; } ;;
            Address)
                mf_tunnel_address "$value" ||
                    { mf_error 'only one nonconflicting IPv4 /32 is supported'; return 1; }
                MF_ADDRESS=$value ;;
            DNS)
                mf_tunnel_address "$value/32" ||
                    { mf_error 'one numeric tunnel resolver is required'; return 1; }
                MF_DNS=$value ;;
            MTU)
                mf_uint "$value" 1420 && (( value >= 1280 )) ||
                    { mf_error 'supported MTU range is 1280..1420'; return 1; } ;;
            AllowedIPs)
                [[ $value == '0.0.0.0/0' ]] ||
                    { mf_error 'exact IPv4 full tunnel required; IPv6 unsupported'; return 1; } ;;
            Endpoint)
                MF_ENDPOINT=${value%:*}; MF_PORT=${value##*:}
                [[ $value == *:* ]] &&
                    mf_public_ipv4 "$MF_ENDPOINT" &&
                    mf_uint "$MF_PORT" 65535 && (( MF_PORT > 0 )) ||
                    { mf_error 'endpoint must be a public numeric IPv4 and UDP port'; return 1; } ;;
            PersistentKeepalive)
                mf_uint "$value" 65535 ||
                    { mf_error 'invalid keepalive'; return 1; } ;;
        esac
    done <<< "$payload"
    for id in Interface/PrivateKey Interface/Address Interface/DNS \
        Peer/PublicKey Peer/AllowedIPs Peer/Endpoint; do
        [[ ${seen[$id]+present} ]] ||
            { mf_error 'required profile field missing'; return 1; }
    done
    [[ ${MF_ADDRESS%/32} != "$MF_DNS" &&
       ${MF_ADDRESS%/32} != "$MF_ENDPOINT" && $MF_DNS != "$MF_ENDPOINT" ]] ||
        { mf_error 'tunnel address, resolver and endpoint must be distinct'; return 1; }
    MF_TRIMMED=''
    MF_VALID=1
}

mf_profile_metadata() {
    local device inode owner mode links size kind rest
    read -r device inode owner mode links size kind rest <<< "$1"
    [[ $kind =~ ^[a-fA-F0-9]+$ ]] && (( (16#$kind & 0170000) == 0100000 )) &&
        [[ $owner == "$UID" && $mode == 600 && $links == 1 ]] &&
        [[ $size =~ ^[0-9]{1,5}$ ]] && (( size > 0 && size <= 16384 ))
}

mf_private_profile_file() {
    # Capture the SAME snapshot whose metadata is validated, for protected open.
    local file=$1 source_root=$2 canonical owner mode parent snapshot kind rest
    MF_PROFILE_SNAPSHOT='' MF_PROFILE_PARENTS=''
    [[ $file == /* && -f $file && ! -L $file ]] ||
        { mf_error 'profile must be an absolute regular nonsymlink file'; return 1; }
    canonical=$(realpath -e -- "$file" 2>/dev/null) ||
        { mf_error 'cannot resolve profile'; return 1; }
    [[ $canonical == "$file" ]] ||
        { mf_error 'profile path must be canonical without symlink components'; return 1; }
    source_root=$(realpath -e -- "$source_root" 2>/dev/null) ||
        { mf_error 'cannot resolve source root'; return 1; }
    [[ $file != "$source_root" && $file != "$source_root/"* ]] ||
        { mf_error 'profile must be outside the source repository'; return 1; }
    MF_PROFILE_SNAPSHOT=$(stat -c '%d %i %u %a %h %s %f %y %z' -- "$file" 2>/dev/null) ||
        { mf_error 'cannot stat profile'; return 1; }
    mf_profile_metadata "$MF_PROFILE_SNAPSHOT" ||
        { mf_error 'profile requires regular owned 0600 single-link file of 1..16384 bytes'; return 1; }
    parent=${file%/*}
    [[ -n $parent ]] || parent=/
    while :; do
        [[ ! -L $parent ]] ||
            { mf_error 'profile ancestry must not contain symlinks'; return 1; }
        snapshot=$(stat -c '%u %a %f %d %i' -- "$parent" 2>/dev/null) ||
            { mf_error 'cannot stat profile ancestry'; return 1; }
        read -r owner mode kind rest <<< "$snapshot"
        [[ $kind =~ ^[a-fA-F0-9]+$ ]] && (( (16#$kind & 0170000) == 0040000 )) ||
            { mf_error 'profile ancestry must contain directories'; return 1; }
        if [[ $parent == "${file%/*}" ]]; then
            [[ $owner == "$UID" && $mode == 700 ]] ||
                { mf_error 'profile parent must be owned by current user with mode 0700'; return 1; }
        fi
        # Root-owned sticky /tmp is safe for owned child directories. Otherwise
        # ancestors must be root/current-owned and not group/world writable.
        { mf_root_owner "$owner" || [[ $owner == "$UID" ]]; } &&
            { (( (8#$mode & 0022) == 0 )) ||
              { mf_root_owner "$owner" && (( (8#$mode & 01000) != 0 )); }; } ||
            { mf_error 'profile ancestry permits untrusted replacement'; return 1; }
        MF_PROFILE_PARENTS+="$snapshot;"
        [[ $parent != / ]] || break
        parent=${parent%/*}
        [[ -n $parent ]] || parent=/
    done
}

# Inside a rootless container (distrobox, toolbox) the host's root shows up
# as the overflow uid. Accept it as root only in a non-initial user namespace.
mf_root_owner() {
    local owner=$1 overflow map
    [[ $owner == 0 ]] && return 0
    overflow=$(cat /proc/sys/kernel/overflowuid 2>/dev/null) || return 1
    [[ $owner == "$overflow" ]] || return 1
    map=$(tr -s ' \t' ' ' < /proc/self/uid_map 2>/dev/null | sed 's/^ //') || return 1
    [[ -n $map && $map != '0 0 4294967295' ]]
}

mf_open_profile() {
    local file=$1 root=$2 validated parents opened
    mf_private_profile_file "$file" "$root" || return 1
    validated=$MF_PROFILE_SNAPSHOT parents=$MF_PROFILE_PARENTS
    # Suppress Bash's pathname-bearing open diagnostics; use fixed errors only.
    if ! { exec {MF_PROFILE_FD}< "$file"; } 2>/dev/null; then
        mf_error 'cannot open protected profile'; return 1
    fi
    opened=$(stat -Lc '%d %i %u %a %h %s %f %y %z' -- "/proc/self/fd/$MF_PROFILE_FD" 2>/dev/null) || opened=''
    if [[ $opened != "$validated" ]] || ! mf_profile_metadata "$opened" ||
        ! mf_private_profile_file "$file" "$root" ||
        [[ $MF_PROFILE_SNAPSHOT != "$validated" || $MF_PROFILE_PARENTS != "$parents" ]]; then
        exec {MF_PROFILE_FD}<&-
        mf_error 'profile changed during protected open'; return 1
    fi
}

mf_nft_rules() {
    # Text renderer only; guest/network.sh applies it before bringing up WAN.
    # Interface names and IP layout are fixed by the image and QEMU arguments.
    [[ ${MF_VALID:-0} == 1 ]] ||
        { mf_error 'parse a supported profile before generating policy'; return 1; }
    local elements subnet
    elements=''
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
        "    iifname \"wan0\" ip saddr $MF_ENDPOINT udp sport $MF_PORT udp dport 51820 ct state established accept" \
        '  }' \
        '  chain output {' \
        '    type filter hook output priority 0; policy drop;' \
        '    meta nfproto ipv6 drop' \
        '    oifname "lo" accept' \
        "    oifname \"wan0\" ip daddr $MF_ENDPOINT udp sport 51820 udp dport $MF_PORT accept" \
        '  }' \
        '  chain forward {' \
        '    type filter hook forward priority 0; policy drop;' \
        '    meta nfproto ipv6 drop' \
        "    iifname \"lan0\" oifname \"wg0\" ip saddr 192.168.250.2 ip daddr $MF_DNS udp dport 53 accept" \
        "    iifname \"lan0\" oifname \"wg0\" ip saddr 192.168.250.2 ip daddr $MF_DNS tcp dport 53 accept" \
        '    iifname "lan0" oifname "wg0" ip daddr @special drop' \
        '    iifname "lan0" oifname "wg0" udp dport 53 drop' \
        '    iifname "lan0" oifname "wg0" tcp dport 53 drop' \
        '    iifname "lan0" oifname "wg0" ip saddr 192.168.250.2 accept' \
        '    iifname "wg0" oifname "lan0" ip daddr 192.168.250.2 ct state established,related accept' \
        '  }' \
        '}' \
        'table ip mayfly_nat {' \
        '  chain postrouting {' \
        '    type nat hook postrouting priority srcnat; policy accept;' \
        '    oifname "wg0" ip saddr 192.168.250.2 masquerade' \
        '  }' \
        '}'
}
