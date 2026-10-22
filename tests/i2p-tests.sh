# Offline checks for the I2P chooser entry. Sourced by run.sh. No VM, network,
# sudo, or real i2pd; the launcher script runs against stub programs.

mf_i2p_conf=$project/guest/i2pd.conf
mf_i2p_js=$project/guest/i2p-user.js
mf_i2p_desktop=$project/guest/desktop.sh

# Print section.key=value lines for a config file.
mf_conf_pairs() {
    awk '
        /^[ \t]*#/ || /^[ \t]*$/ {next}
        /^\[/ {sec=substr($0,2,length($0)-2); next}
        {
            k=$1; v=$0; sub(/^[^=]*=[ \t]*/, "", v); sub(/[ \t]+$/, "", v)
            print (sec==""?"":sec".") k "=" v
        }' "$1"
}

mf_i2p_conf_has() { mf_conf_pairs "$mf_i2p_conf" | grep -qxF "$1"; }
mf_i2p_conf_lacks_key() { ! mf_conf_pairs "$mf_i2p_conf" | cut -d= -f1 | grep -qxE "$1"; }

check 'i2pd.conf only uses options validated for i2pd 2.56.0' \
    bash -c 'unknown=$(comm -23 <(source "$1"; mf_conf_pairs "$2" | cut -d= -f1 | sort -u) \
        <(grep -v "^#" "$3" | sort -u)); [[ -z $unknown ]]' _ \
        <(declare -f mf_conf_pairs) "$mf_i2p_conf" "$project/tests/fixtures/i2pd-2.56.0-options.txt"
check 'i2pd.conf binds the proxy and console to loopback only' \
    bash -c 'source "$1"; mf_conf_pairs "$2" | grep -qxF httpproxy.address=127.0.0.1 &&
        mf_conf_pairs "$2" | grep -qxF httpproxy.port=4444 &&
        mf_conf_pairs "$2" | grep -qxF http.address=127.0.0.1 &&
        ! mf_conf_pairs "$2" | grep -qE "=(0\.0\.0\.0|::)$"' _ \
        <(declare -f mf_conf_pairs) "$mf_i2p_conf"
check 'i2pd.conf has no outproxy so clearnet requests are refused' \
    bash -c 'source "$1"; ! mf_conf_pairs "$2" | cut -d= -f1 | grep -qiE "outproxy" &&
        mf_conf_pairs "$2" | grep -qxF socksproxy.enabled=false' _ \
        <(declare -f mf_conf_pairs) "$mf_i2p_conf"
check 'i2pd.conf disables every remote-control and discovery interface' \
    bash -c 'source "$1"; for s in sam bob i2cp i2pcontrol upnp; do
        mf_conf_pairs "$2" | grep -qxF "$s.enabled=false" || exit 1; done' _ \
        <(declare -f mf_conf_pairs) "$mf_i2p_conf"
check 'i2pd.conf is a client-only, IPv4-only, non-published, non-persistent router' \
    bash -c 'source "$1"; for kv in ipv6=false floodfill=false notransit=true reseed.verify=true \
        ntcp2.published=false ssu2.published=false limits.transittunnels=0 httpproxy.addresshelper=false \
        persist.profiles=false persist.addressbook=false daemon=false; do
        mf_conf_pairs "$2" | grep -qxF "$kv" || exit 1; done' _ \
        <(declare -f mf_conf_pairs) "$mf_i2p_conf"
check 'the router config files are tracked while credential-style conf files stay ignored' \
    bash -c 'cd "$1" && git check-ignore -q guest/i2pd.conf && exit 1
        git check-ignore -q guest/i2p-tunnels.conf && exit 1
        git check-ignore -q guest/wireguard.conf || exit 1
        git check-ignore -q provider.example.conf || exit 1
        git ls-files --error-unmatch guest/i2pd.conf guest/i2p-tunnels.conf >/dev/null' _ "$project"
check 'i2p tunnels file defines no tunnels, so the router cannot host anything' \
    bash -c '! grep -q "^\[" "$1"' _ "$project/guest/i2p-tunnels.conf"

check 'i2p user.js forces every request through the router proxy with no bypass' \
    bash -c 'for line in \
        "user_pref(\"network.proxy.type\", 1);" \
        "user_pref(\"network.proxy.http\", \"127.0.0.1\");" \
        "user_pref(\"network.proxy.http_port\", 4444);" \
        "user_pref(\"network.proxy.ssl\", \"127.0.0.1\");" \
        "user_pref(\"network.proxy.ssl_port\", 4444);" \
        "user_pref(\"network.proxy.no_proxies_on\", \"\");" \
        "user_pref(\"network.proxy.allow_hijacking_localhost\", true);" \
        "user_pref(\"network.proxy.failover_direct\", false);" \
        "user_pref(\"network.proxy.socks\", \"\");" \
        "user_pref(\"dom.security.https_only_mode\", false);" \
        "user_pref(\"media.peerconnection.enabled\", false);" \
        "user_pref(\"keyword.enabled\", false);" \
        "user_pref(\"media.peerconnection.ice.proxy_only\", true);" \
        "user_pref(\"browser.fixup.domainsuffixwhitelist.i2p\", true);" \
        "user_pref(\"dom.security.https_first\", false);" \
        "user_pref(\"dom.security.https_first_pbm\", false);" \
        "user_pref(\"dom.security.https_first_schemeless\", false);" \
        "user_pref(\"javascript.enabled\", false);" \
        "user_pref(\"privacy.resistFingerprinting\", true);"; do
        grep -qxF "$line" "$1" || { echo "missing: $line" >&2; exit 1; }; done' _ "$mf_i2p_js"
check 'i2p user.js never sets a preference that the Firefox system policy locks' \
    bash -c 'set -euo pipefail
        js=$(grep -oE "user_pref\(\"[^\"]+\"" "$1" | sed -E "s/user_pref\(\"//; s/\"$//" | sort -u)
        locked=$(jq -r ".policies.Preferences | keys[]" "$2" | sort -u)
        [[ -z $(comm -12 <(printf "%s\n" "$js") <(printf "%s\n" "$locked")) ]]' _ \
        "$mf_i2p_js" "$project/guest/firefox-policies.json"
check 'the shared policy keeps HTTPS-only as an overridable default, not a forced lock' \
    jq_quiet '.policies.HttpsOnlyMode == "enabled"' "$project/guest/firefox-policies.json"

check 'chooser offers three entries and every entry has a case branch' \
    bash -c 'for e in "Firefox over WireGuard" "Tor Browser over WireGuard" "I2P over WireGuard (eepsites only)"; do
        [[ $(grep -cF -- "$e" "$1") -ge 2 ]] || exit 1; done' _ "$mf_i2p_desktop"
check 'the I2P entry starts the router and opens Firefox in its own profile' \
    bash -c 'grep -Fq "start_i2p" "$1" && grep -Fq -- "--profile \"\$i2p_profile\"" "$1"' _ "$mf_i2p_desktop"
check 'the Firefox and Tor branches never start the router' \
    bash -c 'b=$(sed -n "/^case \$choice in/,/^esac/p" "$1")
        fx=$(sed -n "/\x27Firefox over WireGuard\x27)/,/;;/p" <<< "$b"); tor=$(sed -n "/\x27Tor Browser over WireGuard\x27)/,/;;/p" <<< "$b")
        [[ -n $fx && -n $tor && $fx != *i2p* && $tor != *i2p* ]]' _ "$mf_i2p_desktop"
check 'the launcher stops the router on exit and only ever runs sudo poweroff' \
    bash -c 'grep -Fq "kill \"\$i2pd_pid\"" "$1" && [[ $(grep -c "sudo " "$1") == 1 ]] && grep -Fq "sudo -n /usr/sbin/poweroff" "$1" && ! grep -qi outproxy "$1"' _ "$mf_i2p_desktop"
check 'the readiness probe never goes through a proxy and the router path is the packaged one' \
    bash -c 'grep -Fq -- "$2" "$1" && grep -Fq "i2pd_bin=\${MF_I2PD_BIN:-/usr/bin/i2pd}" "$1"' _ "$mf_i2p_desktop" "--noproxy '*'"
check 'the launcher refuses to start Firefox when proxy settings are missing and says why' \
    bash -c 'grep -Fq "network.proxy.type\", 1" "$1" && grep -Fq "http_port\", 4444" "$1" && grep -Fq "browser settings are missing or altered" "$1"' _ "$mf_i2p_desktop"
check 'build installs the router and uploads its three files, then verifies the package' \
    bash -c 'b=$(< "$1")
        [[ $b == *"fonts-liberation,i2pd,curl"* && $b == *"guest/i2pd.conf:/tmp/i2pd.conf"* &&
           $b == *"guest/i2p-tunnels.conf:/tmp/i2p-tunnels.conf"* && $b == *"guest/i2p-user.js:/tmp/i2p-user.js"* &&
           $b == *"dpkg-query -W firefox-esr i2pd"* ]]' _ "$project/lib/build.sh"
check 'the packaged router service can never start by itself' \
    bash -c 'grep -Fq "systemctl --root=/ mask i2pd.service" "$1"' _ "$project/guest/browser-prepare.sh"

# ---- behavioural: run the real desktop.sh against stubs ----

mf_i2p_sandbox() {
    d=$(mktemp -d "${TMPDIR:-/tmp}/pbi2p.XXXXXXXX")
    mkdir -p "$d/bin" "$d/home" "$d/lib"
    : > "$d/log"
    cp -- "$project/guest/i2pd.conf" "$project/guest/i2p-tunnels.conf" "$project/guest/i2p-user.js" "$d/lib/"
    printf '%s\n' '#!/bin/bash' \
        'case "$*" in' \
        '  *--list*) [[ -n ${MF_T_CHOICE:-} ]] || exit 1; printf "%s\n" "$MF_T_CHOICE" ;;' \
        '  *--progress*) cat >/dev/null; exit 0 ;;' \
        '  *--error*) echo "zenity-error" >> "$MF_T_LOG" ;;' \
        'esac' > "$d/bin/zenity"
    printf '%s\n' '#!/bin/bash' 'exit 0' > "$d/bin/openbox"
    printf '%s\n' '#!/bin/bash' 'exit 0' > "$d/bin/sleep"
    printf '%s\n' '#!/bin/bash' \
        'echo "i2pd $*" >> "$MF_T_LOG"; echo $$ > "$MF_T_DIR/i2pd.pid"' \
        '[[ ${MF_T_I2PD_DIES:-0} == 1 ]] && exit 1' \
        'exec /bin/sleep 30' > "$d/bin/i2pd"
    printf '%s\n' '#!/bin/bash' \
        'echo curl >> "$MF_T_LOG"' \
        'if [[ ${MF_T_CURL_OK:-0} == 1 ]]; then printf "<b>Client Tunnels:</b> %s <b>Transit Tunnels:</b> 0\n" "${MF_T_TUNNELS:-12}"; else exit 22; fi' > "$d/bin/curl"
    printf '%s\n' '#!/bin/bash' 'echo "sudo $*" >> "$MF_T_LOG"' > "$d/bin/sudo"
    printf '%s\n' '#!/bin/bash' \
        'echo "firefox $*" >> "$MF_T_LOG"; echo "i2pdhome $(stat -c %a "$HOME/.i2pd" 2>/dev/null)" >> "$MF_T_LOG"; [[ -f $HOME/.i2p-firefox/user.js ]] && echo "userjs-present $(stat -c %a "$HOME/.i2p-firefox/user.js")" >> "$MF_T_LOG"; exit 0' > "$d/bin/firefox-esr"
    chmod 755 "$d/bin/"*
}

mf_i2p_run() {
    env HOME="$d/home" MF_GUEST_LIB="$d/lib" MF_T_LOG="$d/log" MF_T_DIR="$d" MF_I2PD_BIN="$d/bin/i2pd" \
        PATH="$d/bin:$PATH" "$@" bash "$mf_i2p_desktop" >/dev/null 2>&1 || :
}

mf_i2p_poweroffs() { grep -c "^sudo -n /usr/sbin/poweroff$" "$d/log" || :; }

mf_i2p_case_ready() {
    local d rc=0; mf_i2p_sandbox
    mf_i2p_run MF_T_CHOICE="I2P over WireGuard (eepsites only)" MF_T_CURL_OK=1
    {
        grep -q "^i2pd --datadir=$d/home/.i2pd --conf=$d/home/.i2pd/i2pd.conf --tunconf=$d/home/.i2pd/tunnels.conf$" "$d/log" &&
        grep -q "^firefox --no-remote --new-instance --profile $d/home/.i2p-firefox about:blank$" "$d/log" &&
        grep -q "^userjs-present 600$" "$d/log" &&
        grep -q "^i2pdhome 700$" "$d/log" &&
        [[ $(mf_i2p_poweroffs) == 1 ]] &&
        ! kill -0 "$(cat "$d/i2pd.pid")" 2>/dev/null
    } || rc=1
    rm -rf -- "$d"; return "$rc"
}
mf_i2p_case_timeout() {
    local d rc=0; mf_i2p_sandbox
    mf_i2p_run MF_T_CHOICE="I2P over WireGuard (eepsites only)" MF_T_CURL_OK=0 MF_I2P_WAIT_LIMIT=3
    { ! grep -q "^firefox" "$d/log" && grep -q "^zenity-error$" "$d/log" && [[ $(mf_i2p_poweroffs) == 1 ]] &&
        ! kill -0 "$(cat "$d/i2pd.pid")" 2>/dev/null; } || rc=1
    rm -rf -- "$d"; return "$rc"
}
mf_i2p_case_too_few_tunnels() {
    local d rc=0; mf_i2p_sandbox
    mf_i2p_run MF_T_CHOICE="I2P over WireGuard (eepsites only)" MF_T_CURL_OK=1 MF_T_TUNNELS=2 MF_I2P_WAIT_LIMIT=3
    { ! grep -q "^firefox" "$d/log" && grep -q "^zenity-error$" "$d/log" && [[ $(mf_i2p_poweroffs) == 1 ]]; } || rc=1
    rm -rf -- "$d"; return "$rc"
}
mf_i2p_case_router_dies() {
    local d rc=0; mf_i2p_sandbox
    mf_i2p_run MF_T_CHOICE="I2P over WireGuard (eepsites only)" MF_T_CURL_OK=0 MF_T_I2PD_DIES=1 MF_I2P_WAIT_LIMIT=300
    # A dead router must end the wait at once, not after the whole time limit.
    { ! grep -q "^firefox" "$d/log" && [[ $(mf_i2p_poweroffs) == 1 ]] &&
        (( $(grep -c '^curl$' "$d/log" || :) < 100 )); } || rc=1
    rm -rf -- "$d"; return "$rc"
}
mf_i2p_case_tampered_profile() {
    local d rc=0; mf_i2p_sandbox
    sed -i 's/"network.proxy.type", 1/"network.proxy.type", 0/' "$d/lib/i2p-user.js"
    mf_i2p_run MF_T_CHOICE="I2P over WireGuard (eepsites only)" MF_T_CURL_OK=1
    { ! grep -q "^firefox" "$d/log" && [[ $(mf_i2p_poweroffs) == 1 ]]; } || rc=1
    rm -rf -- "$d"; return "$rc"
}
mf_i2p_case_other_entry() {
    local d rc=0; mf_i2p_sandbox
    mf_i2p_run MF_T_CHOICE="Firefox over WireGuard"
    { ! grep -q "^i2pd " "$d/log" && grep -q "^firefox --no-remote --new-instance$" "$d/log" &&
        [[ ! -e $d/home/.i2pd && ! -e $d/home/.i2p-firefox ]] && [[ $(mf_i2p_poweroffs) == 1 ]]; } || rc=1
    rm -rf -- "$d"; return "$rc"
}
mf_i2p_case_tor_entry() {
    local d rc=0; mf_i2p_sandbox
    mf_i2p_run MF_T_CHOICE="Tor Browser over WireGuard"
    { ! grep -q "^i2pd " "$d/log" && [[ $(mf_i2p_poweroffs) == 1 ]]; } || rc=1
    rm -rf -- "$d"; return "$rc"
}
mf_i2p_case_cancel() {
    local d rc=0; mf_i2p_sandbox
    mf_i2p_run
    { ! grep -qE "^(i2pd |firefox)" "$d/log" && [[ $(mf_i2p_poweroffs) == 1 ]]; } || rc=1
    rm -rf -- "$d"; return "$rc"
}

check 'I2P entry starts the router, opens the proxied profile, and cleans up' mf_i2p_case_ready
check 'I2P entry ends the session when the router never becomes ready' mf_i2p_case_timeout
check 'I2P entry ends the session when the router reports too few tunnels' mf_i2p_case_too_few_tunnels
check 'I2P entry ends the session when the router dies' mf_i2p_case_router_dies
check 'I2P entry refuses to open a browser with altered proxy settings' mf_i2p_case_tampered_profile
check 'Firefox entry never starts the router or creates I2P files' mf_i2p_case_other_entry
check 'Tor entry never starts the router' mf_i2p_case_tor_entry
check 'cancelling the chooser starts nothing and powers off' mf_i2p_case_cancel
