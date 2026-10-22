#!/bin/bash
# Firefox over WireGuard, the bundled Tor Browser, or Firefox over a local i2pd
# router (eepsites only). Ordinary Firefox has no Tor or I2P proxy settings.
set +x
set -euo pipefail
umask 077
ulimit -c 0
i2pd_pid=
finish() {
    [[ -z $i2pd_pid ]] || kill "$i2pd_pid" 2>/dev/null || :
    sudo -n /usr/sbin/poweroff
}
trap finish EXIT
openbox &

lib=${MF_GUEST_LIB:-/usr/local/lib/mayfly}
i2p_home=$HOME/.i2pd
i2p_profile=$HOME/.i2p-firefox
i2pd_bin=${MF_I2PD_BIN:-/usr/bin/i2pd}

# 0 when the router has built enough tunnels, 2 when it has died, else 1.
i2p_ready() {
    local page n
    kill -0 "$i2pd_pid" 2>/dev/null || return 2
    page=$(curl -fsS --max-time 3 --noproxy '*' \
        --resolve localhost:7070:127.0.0.1 http://localhost:7070/ 2>/dev/null) || return 1
    n=$(sed -n 's|.*<b>Client Tunnels:</b> \([0-9][0-9]*\).*|\1|p' <<< "$page" | head -n 1)
    (( ${n:-0} >= 6 ))
}

wait_for_i2p() {
    local limit=${MF_I2P_WAIT_LIMIT:-300} i=0 rc
    {
        while :; do
            rc=0
            i2p_ready || rc=$?
            if (( rc == 0 )); then printf '100\n'; exit 0; fi
            (( rc == 2 )) && exit 3
            (( ++i > limit )) && exit 4
            printf '# Joining the I2P network: %d seconds (usually a few minutes)\n' $((i * 2))
            sleep 2
        done
    } | zenity --progress --pulsate --auto-close --title='Starting I2P' \
        --text='Starting router'
}

start_i2p() {
    install -d -m 700 "$i2p_home" "$i2p_profile"
    install -m 600 "$lib/i2pd.conf" "$i2p_home/i2pd.conf"
    install -m 600 "$lib/i2p-tunnels.conf" "$i2p_home/tunnels.conf"
    install -m 600 "$lib/i2p-user.js" "$i2p_profile/user.js"
    "$i2pd_bin" --datadir="$i2p_home" --conf="$i2p_home/i2pd.conf" \
        --tunconf="$i2p_home/tunnels.conf" > "$i2p_home/i2pd.log" 2>&1 &
    i2pd_pid=$!
}

choice=$(zenity --list --title='Disposable session: close browser to end' \
    --column=Browser 'Firefox over WireGuard' 'Tor Browser over WireGuard' \
    'I2P over WireGuard (eepsites only)') || exit 0
case $choice in
    'Firefox over WireGuard')
        firefox-esr --no-remote --new-instance ;;
    'Tor Browser over WireGuard')
        cd /opt/tor-browser
        ./Browser/start-tor-browser ;;
    'I2P over WireGuard (eepsites only)')
        start_i2p
        if ! wait_for_i2p; then
            zenity --error --text='I2P did not become ready. This session will end.' || :
            exit 0
        fi
        # Refuse to open a browser whose proxy settings are missing or altered.
        if ! grep -qx 'user_pref("network.proxy.type", 1);' "$i2p_profile/user.js" ||
            ! grep -qx 'user_pref("network.proxy.http_port", 4444);' "$i2p_profile/user.js"; then
            zenity --error --text='The I2P browser settings are missing or altered. This session will end.' || :
            exit 1
        fi
        firefox-esr --no-remote --new-instance --profile "$i2p_profile" about:blank ;;
    *) exit 1 ;;
esac
