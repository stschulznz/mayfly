#!/bin/bash
# Opt-in diagnostics (MAYFLY_DIAG=1 at launch). Runs INSIDE the gateway or browser guest.
# Writes only nonsecret counters to the serial file in the host RAM session
# directory: never keys, endpoint, resolver, or profile text.
set +x
export LC_ALL=C
umask 077
exec > /dev/ttyS0 2>&1
role=${1:?}

# Nonsecret I2P progress for the I2P entry: the router's own tunnel count.
i2p_count() {
    curl -fsS --max-time 2 --max-filesize 1048576 --proto =http --noproxy '*' \
        --resolve localhost:7070:127.0.0.1 \
        http://localhost:7070/ 2>/dev/null |
        sed -n 's|.*<b>Client Tunnels:</b> \([0-9][0-9]*\).*|\1|p' | head -n 1
}
echo "diag start role=$role"
i=0
while :; do
    i=$((i + 1))
    hs=$(wg show wg0 latest-handshakes 2>/dev/null | awk '{print $2; exit}')
    xfer=$(wg show wg0 transfer 2>/dev/null | awk '{print "rx=" $2 " tx=" $3; exit}')
    line="diag n=$i up=$(cut -d. -f1 /proc/uptime) handshake=${hs:-none} ${xfer:-wg0=absent}"
    for nic in lan0 wan0 wg0; do
        d=/sys/class/net/$nic
        [[ -d $d ]] || { line+=" $nic=absent"; continue; }
        line+=" $nic=$(<"$d/operstate"),rxp=$(<"$d/statistics/rx_packets"),txp=$(<"$d/statistics/tx_packets"),txdrop=$(<"$d/statistics/tx_dropped")"
    done
    if [[ $role == browser ]]; then
        line+=" neigh=$(ip -4 neigh show dev lan0 | awk '{print $1 "/" $NF}' | tr '\n' ',')"
        line+=" routes=$(ip -4 route show | wc -l) addr=$(ip -4 -o addr show dev lan0 | awk '{print $4}')"
        # Active probes: one UDP packet to the gateway, then one name lookup.
        rc=0; timeout 1 bash -c 'echo > /dev/udp/192.168.250.1/9' 2>/dev/null || rc=$?
        line+=" probe_udp_rc=$rc"
        rc=0; timeout 4 runuser -u browser -- getent ahostsv4 example.com >/dev/null 2>&1 || rc=$?
        line+=" probe_dns_rc=$rc"
        line+=" resolv_mode=$(stat -c %a /etc/resolv.conf)"
        if pgrep -x i2pd >/dev/null 2>&1; then
            line+=" i2p_tunnels=$(i2p_count)"
        fi
        line+=" browser_procs=$(ps -u browser -o comm= 2>/dev/null | sort -u | tr '\n' ',')"
    fi
    echo "$line"
    sleep 5
done
