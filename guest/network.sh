#!/bin/bash
# Runs INSIDE the disposable guest, never on the host.
set +x
set -Eeuo pipefail
export LC_ALL=C
umask 077
ulimit -c 0
source /usr/local/lib/mayfly/policy.sh

fail_closed() {
    trap - ERR EXIT
    ip link set wan0 down 2>/dev/null || :
    ip link set lan0 down 2>/dev/null || :
    ip link set wg0 down 2>/dev/null || :
    systemctl --no-block poweroff || :
}
trap fail_closed ERR
read -r role dns extra < /run/mayfly-session
[[ -z ${extra:-} && ( $role == gateway || $role == browser ) ]]
mf_tunnel_address "$dns/32"
sysctl -q -w net.ipv6.conf.all.disable_ipv6=1 net.ipv6.conf.default.disable_ipv6=1
sysctl -q -w net.ipv4.ip_forward=0
mkdir -m 700 -p /run/mayfly

if [[ $role == gateway ]]; then
    # No network manager is enabled. Interfaces are still DOWN here.
    ip link set wan0 down
    ip link set lan0 down
    modprobe qemu_fw_cfg
    cat /sys/firmware/qemu_fw_cfg/by_name/opt/mayfly/profile/raw |
        dd of=/run/mayfly/profile.conf status=none
    mf_parse_profile < /run/mayfly/profile.conf
    [[ $MF_DNS == "$dns" ]]
    mf_nft_rules | dd of=/run/mayfly/policy.nft status=none
    nft --check --file /run/mayfly/policy.nft
    nft --file /run/mayfly/policy.nft
    # Never run wg-quick or evaluate profile text. Remove only data fields not
    # accepted by wg setconf; strict parser already rejected every hook/helper.
    awk '
        /^[ \t]*#/ || /^[ \t]*$/ {next}
        /^[ \t]*(Address|DNS|MTU)[ \t]*=/ {next}
        {print}
        /^[ \t]*\[Interface\][ \t\r]*$/ {print "ListenPort = 51820"}
    ' /run/mayfly/profile.conf |
        dd of=/run/mayfly/wg.conf status=none
    mtu=$(awk -F= '/^[ \t]*MTU[ \t]*=/ {gsub(/[ \t\r]/,"",$2);print $2}' \
        /run/mayfly/profile.conf)
    mtu=${mtu:-1420}
    ip link add wg0 type wireguard
    wg setconf wg0 /run/mayfly/wg.conf 2>/dev/null
    ip address add "$MF_ADDRESS" dev wg0
    ip link set wg0 mtu "$mtu" up
    ip address add 10.0.2.15/24 dev wan0
    ip address add 192.168.250.1/30 dev lan0
    ip link set lan0 mtu 1280
    # FIRST permitted WAN connectivity follows successful atomic nft load.
    ip link set wan0 up
    ip link set lan0 up
    ip route add "$MF_ENDPOINT/32" via 10.0.2.2 dev wan0
    ip route add default dev wg0
    sysctl -q -w net.ipv4.ip_forward=1
    # Keepalive, if provided, and browser traffic establish the tunnel.
    # A tunnel outage leaves the default route on wg0 and cannot use WAN.
else
    ip link set lan0 down
    ip address add 192.168.250.2/30 dev lan0
    ip link set lan0 mtu 1280
    # Only one NIC exists. No DHCP/slirp/Tor proxy switching is available.
    ip link set lan0 up
    ip route add default via 192.168.250.1 dev lan0
fi
rm -f -- /etc/resolv.conf
printf 'nameserver %s\noptions attempts:2 timeout:2\n' "$dns" |
    dd of=/etc/resolv.conf status=none
# umask 077 would leave this root-only; unprivileged browsers must read it.
chmod 0644 /etc/resolv.conf
modprobe qemu_fw_cfg 2>/dev/null || :
if [[ -e /sys/firmware/qemu_fw_cfg/by_name/opt/mayfly/diag/raw ]]; then
    systemd-run --no-block --unit=mayfly-diag /usr/local/lib/mayfly/diag.sh "$role" || :
fi
trap - ERR
