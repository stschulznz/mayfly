#!/bin/bash
# Runs INSIDE the sandbox as the browser user: Firefox over a local i2pd router
# (eepsites only). Mirrors the I2P entry in guest/desktop.sh and reuses its
# configuration files, which provision.sh installs next to this script.
set +x
set -euo pipefail
umask 077
lib=${MF_GUEST_LIB:-/usr/local/lib/mayfly}
i2p_home=$HOME/.i2pd
i2p_profile=$HOME/.i2p-firefox
i2pd_pid=
trap '[[ -z $i2pd_pid ]] || kill "$i2pd_pid" 2>/dev/null || :' EXIT

# 0 when the router has built enough tunnels, 2 when it has died, else 1.
i2p_ready() {
    local page n
    kill -0 "$i2pd_pid" 2>/dev/null || return 2
    page=$(curl -fsS --max-time 3 --noproxy '*' \
        --resolve localhost:7070:127.0.0.1 http://localhost:7070/ 2>/dev/null) || return 1
    n=$(sed -n 's|.*<b>Client Tunnels:</b> \([0-9][0-9]*\).*|\1|p' <<< "$page" | head -n 1)
    (( ${n:-0} >= 6 ))
}

install -d -m 700 "$i2p_home" "$i2p_profile"
install -m 600 "$lib/i2pd.conf" "$i2p_home/i2pd.conf"
install -m 600 "$lib/i2p-tunnels.conf" "$i2p_home/tunnels.conf"
install -m 600 "$lib/i2p-user.js" "$i2p_profile/user.js"
/usr/bin/i2pd --datadir="$i2p_home" --conf="$i2p_home/i2pd.conf" \
    --tunconf="$i2p_home/tunnels.conf" > "$i2p_home/i2pd.log" 2>&1 &
i2pd_pid=$!

limit=${MF_I2P_WAIT_LIMIT:-300}
i=0
while :; do
    rc=0
    i2p_ready || rc=$?
    (( rc == 0 )) && break
    (( rc == 2 )) && { printf 'The I2P router stopped. This session will end.\n' >&2; exit 1; }
    (( ++i > limit )) && { printf 'I2P did not become ready. This session will end.\n' >&2; exit 1; }
    (( i % 15 == 1 )) && printf 'Joining the I2P network: %d seconds (usually a few minutes)\n' $((i * 2)) >&2
    sleep 2
done
# Refuse to open a browser whose proxy settings are missing or altered.
if ! grep -qx 'user_pref("network.proxy.type", 1);' "$i2p_profile/user.js" ||
    ! grep -qx 'user_pref("network.proxy.http_port", 4444);' "$i2p_profile/user.js"; then
    printf 'The I2P browser settings are missing or altered. This session will end.\n' >&2
    exit 1
fi
firefox-esr --no-remote --new-instance --profile "$i2p_profile" about:blank
