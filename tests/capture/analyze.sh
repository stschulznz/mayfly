#!/bin/bash
# Compare a host packet capture of a Mayfly session with an idle baseline.
# Passes only if every outbound packet that is not in the baseline goes to the
# WireGuard endpoint over UDP.
#
#   analyze.sh --endpoint IP:PORT BASELINE.pcap SESSION.pcap
#   analyze.sh --profile FILE BASELINE.pcap SESSION.pcap
#   analyze.sh --endpoint IP:PORT --local ADDR --text BASELINE.txt SESSION.txt
#
# --profile reads only the Endpoint line of a WireGuard profile. The pcap form
# needs tcpdump (reading a file needs no privileges). --text reads output of
# `tcpdump -nn -q -r FILE`. A pass means "no direct traffic observed in this
# capture", not that no leak path exists.
set -euo pipefail
export LC_ALL=C

usage() {
    printf 'usage: %s (--endpoint IP:PORT | --profile FILE) [--local ADDR]... [--text] BASELINE SESSION\n' "${0##*/}" >&2
    exit 2
}

endpoint=''
profile=''
text=0
locals=()
files=()
while (( $# )); do
    case $1 in
        --endpoint) [[ $# -ge 2 ]] || usage; endpoint=$2; shift 2 ;;
        --profile) [[ $# -ge 2 ]] || usage; profile=$2; shift 2 ;;
        --local) [[ $# -ge 2 ]] || usage; locals+=("$2"); shift 2 ;;
        --text) text=1; shift ;;
        --*) usage ;;
        *) files+=("$1"); shift ;;
    esac
done
(( ${#files[@]} == 2 )) || usage

if [[ -z $endpoint && -n $profile ]]; then
    endpoint=$(awk -F'[ =]+' 'tolower($1) == "endpoint" { print $2; exit }' "$profile")
fi
[[ $endpoint =~ ^[0-9.]+:[0-9]+$ ]] || {
    printf 'endpoint must be an IPv4 address and port, for example 203.0.113.5:51820\n' >&2
    exit 2
}

if (( ! ${#locals[@]} )); then
    mapfile -t locals < <(ip -o addr show scope global 2>/dev/null | awk '{ sub("/.*", "", $4); print $4 }')
fi
(( ${#locals[@]} )) || { printf 'no local addresses found; pass --local ADDR\n' >&2; exit 2; }

dump() {
    if (( text )); then cat -- "$1"; else tcpdump -nn -q -r "$1" 2>/dev/null; fi
}

# One line per distinct outbound flow: count family|proto|remote|port
outbound() {
    dump "$1" | awk -v locals="${locals[*]}" '
        BEGIN { n = split(locals, l, " "); for (i = 1; i <= n; i++) mine[l[i]] = 1 }
        function split_addr(a, out,   p) {
            sub(/:$/, "", a)
            p = match(a, /\.[0-9]+$/)
            if (p) { out[1] = substr(a, 1, p - 1); out[2] = substr(a, p + 1) } else { out[1] = a; out[2] = "-" }
        }
        { sub(/^[0-9:.]+ /, "") }
        ($1 == "IP" || $1 == "IP6") && $3 == ">" {
            split_addr($2, s); split_addr($4, d)
            if (!(s[1] in mine)) next
            proto = $5; sub(/,$/, "", proto)
            print ($1 == "IP6" ? "v6" : "v4") "|" proto "|" d[1] "|" d[2]
        }' | sort | uniq -c
}

base=$(outbound "${files[0]}" | awk '{ $1 = ""; print substr($0, 2) }')
sess=$(outbound "${files[1]}")

ep_ip=${endpoint%:*}
ep_port=${endpoint##*:}
fail=0
seen_ep=0
printf 'Outbound traffic in the session capture that the baseline does not explain:\n'
while read -r count key; do
    [[ -n ${key:-} ]] || continue
    IFS='|' read -r fam proto ip port <<< "$key"
    if [[ $fam == v4 && $proto == UDP && $ip == "$ep_ip" && $port == "$ep_port" ]]; then
        seen_ep=1
        printf '  ok          %6s  WireGuard endpoint %s\n' "$count" "$endpoint"
    elif grep -Fqx -- "$key" <<< "$base"; then
        :
    else
        fail=1
        printf '  UNEXPECTED  %6s  %s %s %s port %s\n' "$count" "$fam" "$proto" "$ip" "$port"
    fi
done <<< "$sess"

if (( ! seen_ep )); then
    printf '  no packets to the WireGuard endpoint were seen; the capture is inconclusive\n'
    fail=1
fi
if (( fail )); then
    printf 'RESULT: FAIL. Review the lines above before trusting this session.\n'
    exit 1
fi
printf 'RESULT: PASS. Only the WireGuard endpoint and baseline traffic were observed leaving this host.\n'
