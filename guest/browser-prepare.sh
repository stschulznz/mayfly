#!/bin/bash
# Runs ONLY in the browser build appliance after signature verification.
set -euo pipefail
umask 077

mf_browser_update_policies() {
    # Tor disables system policy loading. Merge into its XREAppDist instead.
    # Keep upstream policies/preferences except these maintenance-only controls.
    local policy existing
    for policy in "$@"; do
        install -d -o root -g root -m 755 -- "${policy%/*}"
        existing=$policy
        [[ -f $existing ]] || existing=/dev/null
        jq -s '
            (.[0] // {"policies": {}}) * {
                "policies": {
                    "DisableAppUpdate": true,
                    "ExtensionUpdate": false,
                    "DisableSystemAddonUpdate": true,
                    "Preferences": {
                        "media.gmp-manager.updateEnabled": {"Value": false, "Status": "locked"},
                        "media.gmp-provider.enabled": {"Value": false, "Status": "locked"}
                    }
                }
            }' "$existing" | dd of="$policy.new" status=none
        install -o root -g root -m 644 -- "$policy.new" "$policy"
        rm -- "$policy.new"
    done
}

useradd --create-home --shell /bin/bash browser
passwd --lock browser
mkdir -p /opt /usr/share/xsessions /etc/lightdm/lightdm.conf.d \
    /etc/systemd/system/lightdm.service.d /etc/firefox/policies
tar --extract --xz --file /tmp/tor.tar.xz --directory /opt --no-same-owner
test -f /opt/tor-browser/Browser/start-tor-browser
# Preserve upstream writable profile/Tor configuration paths. Protect only the
# policy ancestors here; the merge below also protects distribution and its file.
chown -R browser:browser /opt/tor-browser
chown root:root /opt/tor-browser /opt/tor-browser/Browser
chmod 755 /opt/tor-browser /opt/tor-browser/Browser
chmod 755 /usr/local/lib/mayfly/desktop.sh
# I2P entry assets are root-owned; each session copies them into a RAM home.
install -o root -g root -m 644 -- /tmp/i2pd.conf /usr/local/lib/mayfly/i2pd.conf
install -o root -g root -m 644 -- /tmp/i2p-tunnels.conf /usr/local/lib/mayfly/i2p-tunnels.conf
install -o root -g root -m 644 -- /tmp/i2p-user.js /usr/local/lib/mayfly/i2p-user.js
# The package ships a service that must never start in any entry; the router is
# started by the chooser, as the browser user, only for the I2P entry.
systemctl --root=/ mask i2pd.service
test -x /usr/bin/i2pd
test -d /usr/share/i2pd/certificates
printf '%s\n' '[Desktop Entry]' 'Name=Mayfly disposable session' 'Type=Application' \
    'Exec=/usr/local/lib/mayfly/desktop.sh' |
    dd of=/usr/share/xsessions/mayfly.desktop status=none
printf '%s\n' '[Seat:*]' 'autologin-user=browser' 'autologin-user-timeout=0' \
    'user-session=mayfly' 'autologin-session=mayfly' \
    'allow-guest=false' 'greeter-hide-users=true' |
    dd of=/etc/lightdm/lightdm.conf.d/50-mayfly.conf status=none
printf '%s\n' '[Unit]' 'Requires=mayfly.service' \
    'After=mayfly.service' |
    dd of=/etc/systemd/system/lightdm.service.d/mayfly.conf status=none
printf '%s\n' 'browser ALL=(root) NOPASSWD: /usr/sbin/poweroff ""' |
    dd of=/etc/sudoers.d/mayfly status=none
chmod 440 /etc/sudoers.d/mayfly
# Firefox hardening policy (Tor Browser never reads /etc/firefox/policies).
jq -e . /tmp/firefox-policies.json >/dev/null
install -o root -g root -m 644 -- /tmp/firefox-policies.json \
    /etc/firefox/policies/policies.json
mf_browser_update_policies /etc/firefox/policies/policies.json \
    /opt/tor-browser/Browser/distribution/policies.json
# System-wide files must be traversable/readable by the desktop user even
# though the appliance build shell uses umask 077.
chmod 755 /usr/share/xsessions /etc/lightdm/lightdm.conf.d /etc/firefox/policies
chmod 644 /usr/share/xsessions/mayfly.desktop \
    /etc/lightdm/lightdm.conf.d/50-mayfly.conf \
    /etc/firefox/policies/policies.json
systemctl --root=/ enable lightdm.service
systemctl --root=/ set-default graphical.target
cloud-init clean --logs --machine-id --seed
truncate -s 0 /etc/machine-id
