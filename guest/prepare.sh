#!/bin/bash
# Build appliance ONLY: modifies a guest disk mounted by virt-customize.
set -euo pipefail
umask 077
chmod 700 /usr/local/lib/mayfly/*.sh
for unit in networking.service NetworkManager.service systemd-networkd.service \
    systemd-networkd.socket systemd-networkd-wait-online.service \
    systemd-resolved.service ssh.service ssh.socket \
    apt-daily.timer apt-daily-upgrade.timer apt-daily.service \
    apt-daily-upgrade.service unattended-upgrades.service systemd-timesyncd.service \
    systemd-coredump.socket kdump-tools.service swap.target \
    qemu-guest-agent.service spice-vdagentd.service \
    getty@tty1.service serial-getty@ttyS0.service; do
    systemctl --root=/ mask "$unit"
done
mkdir -p /etc/cloud/cloud.cfg.d /etc/systemd/network /etc/systemd/journald.conf.d
printf '%s\n' 'datasource_list: [ NoCloud ]' 'network: {config: disabled}' \
    'ssh_deletekeys: true' 'ssh_genkeytypes: []' |
    dd of=/etc/cloud/cloud.cfg.d/99-mayfly.cfg status=none
for record in '01 lan0' '02 lan0' '03 wan0'; do
    read -r suffix name <<< "$record"
    printf '[Match]\nMACAddress=52:54:00:fa:00:%s\n[Link]\nName=%s\n' "$suffix" "$name" |
        dd of="/etc/systemd/network/10-mayfly-$suffix.link" status=none
done
printf '%s\n' '[Journal]' 'Storage=volatile' 'RuntimeMaxUse=16M' |
    dd of=/etc/systemd/journald.conf.d/mayfly.conf status=none
printf '%s\n' 'net.ipv6.conf.all.disable_ipv6=1' \
    'net.ipv6.conf.default.disable_ipv6=1' 'net.ipv4.ip_forward=0' \
    'kernel.core_pattern=/dev/null' 'fs.suid_dumpable=0' |
    dd of=/etc/sysctl.d/99-mayfly.conf status=none
# Remove any cloud image-provided swap mounts, not arbitrary host fstab data.
sed -i '/[[:space:]]swap[[:space:]]/d' /etc/fstab
systemctl --root=/ enable mayfly.service
systemctl --root=/ disable nftables.service || :
# No generated cloud identity survives maintenance into a session.
cloud-init clean --logs --machine-id --seed
truncate -s 0 /etc/machine-id
