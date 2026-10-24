#!/bin/bash
# Regression tests for defects found in review (browser policy merge, QEMU
# arguments, key cleanup, protected profile open, encoding). Sourced by run.sh.
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    set -euo pipefail
    set +x
    export LC_ALL=C
    project=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
    source "$project/lib/policy.sh"
    source "$project/lib/host.sh"
    source "$project/lib/runtime.sh"
    source "$project/lib/build.sh"
    passed=0 failed=0
    check() {
        local name=$1
        shift
        if "$@"; then
            printf 'ok - %s\n' "$name"; ((passed += 1))
        else
            printf 'not ok - %s\n' "$name"; ((failed += 1))
        fi
    }
fi
repair_source() { command cat -- "$project/$2"; }

repair_browser_policy() (
    local sandbox policy defaults profiles
    sandbox=$(mktemp -d)
    trap 'mf_remove_tree "$sandbox"' EXIT
    # All absolute guest paths are mapped into a disposable synthetic tree.
    # No root operations run: record intended ownership; test real modes/JSON.
    mkdir -p "$sandbox"/{opt/tor-browser/Browser/{distribution,TorBrowser/Data},etc/sudoers.d,usr/local/lib/mayfly}
    printf '' | dd of="$sandbox/usr/local/lib/mayfly/desktop.sh" status=none
    printf '' | dd of="$sandbox/opt/tor-browser/Browser/start-tor-browser" status=none
    mkdir -p "$sandbox/opt/tor-browser/Browser/TorBrowser/Data/Browser"
    profiles=$sandbox/opt/tor-browser/Browser/TorBrowser/Data/Browser/profiles.ini
    # Official Bundle-Data/linux/Data/Browser/profiles.ini contents.
    printf '%s\n' '[General]' 'StartWithLastProfile=1' '' '[Profile0]' \
        'Name=default' 'IsRelative=1' 'Path=profile.default' 'Default=1' |
        dd of="$profiles" status=none
    profiles=$(sha256sum "$profiles"); profiles=${profiles%% *}
    # Official 000-tor-browser.js proxy defaults, standing in for packed prefs.
    defaults=$sandbox/opt/tor-browser/Browser/upstream-defaults.fixture
    printf '%s\n' 'pref("network.proxy.socks", "127.0.0.1");' \
        'pref("network.proxy.socks_port", 9150);' \
        'pref("network.proxy.socks_remote_dns", true);' \
        'pref("network.proxy.no_proxies_on", "");' |
        dd of="$defaults" status=none
    defaults=$(sha256sum "$defaults"); defaults=${defaults%% *}
    policy=$sandbox/opt/tor-browser/Browser/distribution/policies.json
    printf '%s\n' '{"policies":{"DisableTelemetry":true,"Preferences":{"upstream.fixture":{"Value":true,"Status":"locked"}}},"fixture":"preserve"}' |
        dd of="$policy" status=none
    MF_TEST_OWNERS='' MF_TEST_INSTALL=''
    useradd() { :; }; passwd() { :; }; tar() { :; }
    MF_TEST_SYSTEMCTL=''
    systemctl() { MF_TEST_SYSTEMCTL+="$*;"; }; cloud-init() { :; }
    chown() { MF_TEST_OWNERS+="$*;"; }
    install() {
        local -a args=()
        MF_TEST_INSTALL+="$*;"
        while (( $# )); do
            case $1 in
                -o|-g) [[ $2 == root ]] || return 1; shift 2 ;;
                *) args+=("$1"); shift ;;
            esac
        done
        command install "${args[@]}"
    }
    cp -- "$project/guest/firefox-policies.json" "$sandbox/firefox-policies.json"
    for f in i2pd.conf i2p-tunnels.conf i2p-user.js; do
        cp -- "$project/guest/$f" "$sandbox/$f"
    done
    mkdir -p "$sandbox/usr/bin" "$sandbox/usr/share/i2pd/certificates"
    printf '' | dd of="$sandbox/usr/bin/i2pd" status=none; chmod 755 "$sandbox/usr/bin/i2pd"
    source <(repair_source _ guest/browser-prepare.sh |
        sed -e "s|/tmp/firefox-policies.json|$sandbox/firefox-policies.json|g" \
            -e "s|/tmp/i2pd.conf|$sandbox/i2pd.conf|g" -e "s|/tmp/i2p-tunnels.conf|$sandbox/i2p-tunnels.conf|g" \
            -e "s|/tmp/i2p-user.js|$sandbox/i2p-user.js|g" \
            -e "s|/opt/|$sandbox/opt/|g" -e "s|/etc/|$sandbox/etc/|g" \
            -e "s|/usr/|$sandbox/usr/|g" -e "s|/tmp/tor.tar.xz|$sandbox/tor.tar.xz|g" \
            -e "s|mkdir -p /opt |mkdir -p $sandbox/opt |")
    [[ -f $policy && $(stat -c %a "$policy") == 644 &&
       $(stat -c %a "${policy%/*}") == 755 &&
       $MF_TEST_OWNERS == *"root:root $sandbox/opt/tor-browser $sandbox/opt/tor-browser/Browser;"* ]] || return 1
    [[ $(sha256sum "$sandbox/opt/tor-browser/Browser/upstream-defaults.fixture") == "$defaults "* &&
       $(sha256sum "$sandbox/opt/tor-browser/Browser/TorBrowser/Data/Browser/profiles.ini") == "$profiles "* ]] || return 1
    jq -e '.fixture == "preserve" and .policies.DisableTelemetry == true and
        .policies.Preferences["upstream.fixture"].Value == true' "$policy" >/dev/null || return 1
    [[ $MF_TEST_SYSTEMCTL == *"--root=/ mask i2pd.service;"* ]] || return 1
    for f in i2pd.conf i2p-tunnels.conf i2p-user.js; do
        [[ -f $sandbox/usr/local/lib/mayfly/$f &&
           $MF_TEST_INSTALL == *"-o root -g root -m 644 -- $sandbox/$f $sandbox/usr/local/lib/mayfly/$f;"* ]] || return 1
    done
    jq -e '.policies.DNSOverHTTPS.Locked == true and
        .policies.ExtensionSettings["*"].installation_mode == "blocked" and
        .policies.Preferences["network.trr.mode"].Value == 5' \
        "$sandbox/etc/firefox/policies/policies.json" >/dev/null || return 1
    jq -e '.policies | has("ExtensionSettings") | not' "$sandbox/opt/tor-browser/Browser/distribution/policies.json" >/dev/null || return 1
    for policy in "$policy" "$sandbox/etc/firefox/policies/policies.json"; do
        [[ $MF_TEST_INSTALL == *"-o root -g root -m 644 -- $policy.new $policy;"* ]] || return 1
        jq -e '.policies | .DisableAppUpdate == true and .ExtensionUpdate == false and
            .DisableSystemAddonUpdate == true and
            .Preferences["media.gmp-manager.updateEnabled"] == {"Value":false,"Status":"locked"} and
            .Preferences["media.gmp-provider.enabled"] == {"Value":false,"Status":"locked"}' \
            "$policy" >/dev/null || return 1
        # Other-user read/traverse mode bits model the non-root desktop reader.
        [[ $(stat -c %a "$policy") == 644 &&
           $(stat -c %a "${policy%/*}") == 755 ]] || return 1
    done
    # The desktop user must be able to traverse every parent of the Firefox policy file.
    [[ $(stat -c %a "$sandbox/etc/firefox") == 755 ]] || return 1
)

# Deliberately narrow fake QEMU 8 stream parser, based on v8.0.0 qapi/net.json.
# It rejects unknown properties, unlike the lifecycle mocks. Not native QEMU.
repair_qemu8_parse() {
    local item key reconnect=0
    local -a items
    IFS=, read -r -a items <<< "$1"
    [[ ${items[0]} == stream ]] || return 1
    for item in "${items[@]:1}"; do
        key=${item%%=*}
        case $key in
            id|server|addr.type|addr.path) ;;
            reconnect) reconnect=${item#*=} ;;
            *) return 1 ;;
        esac
    done
    # A simulated disconnect schedules no reconnect with the schema default 0.
    [[ $reconnect == 0 ]]
}

repair_qemu() (
    source <(repair_source _ lib/runtime.sh)
    mf_tools() { :; }
    qemu-system-x86_64() {
        case "$*" in
            --version) printf 'QEMU emulator version %s.0.0\n' "$fake_major" ;;
            '-netdev help') printf '%s\n' user stream ;;
            '-display help') printf '%s\n' gtk ;;
            '-accel help') printf '%s\n' kvm ;;
            *) return 1 ;;
        esac
    }
    local fake_major=8 i option=''
    mf_native || return 1
    fake_major=7
    if mf_native 2>/dev/null; then return 1; fi
    mf_qemu_args browser /mock/base /mock/run
    for ((i=0; i<${#MF_QEMU[@]}; i++)); do
        [[ ${MF_QEMU[i]} != -netdev ]] || option=${MF_QEMU[i+1]}
    done
    if repair_qemu8_parse 'stream,id=lan,reconnect-ms=0'; then return 1; fi
    repair_qemu8_parse "$option" && [[ $option != *reconnect* ]]
)

repair_guest_wildcard() (
    local sandbox i deletes=0
    sandbox=$(mktemp -d)
    trap 'mf_remove_tree "$sandbox"' EXIT
    mkdir -p "$sandbox/etc/ssh"
    touch "$sandbox/etc/ssh/ssh_host_fixture_a" "$sandbox/etc/ssh/ssh_host_fixture_b"
    # Map only the fixed SSH operand into fake host /etc before sourcing.
    source <(repair_source _ lib/build.sh |
        sed "s|/etc/ssh/ssh_host_|$sandbox/etc/ssh/ssh_host_|g")
    mf_customize_args /mock/image /mock/work "$project" || return 1
    # Fake virt-customize parser: each option has exactly one operand.
    for ((i=0; i<${#MF_CUSTOMIZE[@]}; i++)); do
        case ${MF_CUSTOMIZE[i]} in
            --network) ;;
            --delete)
                ((i+=1)); ((deletes+=1))
                if (( deletes == 1 )); then
                    [[ ${MF_CUSTOMIZE[i]} == /root/.ssh ]] || return 1
                else
                    [[ ${MF_CUSTOMIZE[i]} == "$sandbox/etc/ssh/ssh_host_*" ]] || return 1
                fi ;;
            --format|-a|--install|--mkdir|--upload|--run-command) ((i+=1)) ;;
            *) return 1 ;;
        esac
    done
    [[ $deletes == 2 ]]
)

repair_profile() (
    local scenario=$1 sandbox file diagnostic fd before after consumer=mf_open_profile
    if [[ $scenario == cli-* ]]; then
        scenario=${scenario#cli-}
        consumer=mf_test_profile_cli
    fi
    sandbox=$(mktemp -d)
    trap 'mf_remove_tree "$sandbox"' EXIT
    chmod 700 "$sandbox"
    mkdir -m 700 "$sandbox/private" "$sandbox/source"
    file=$sandbox/private/profile.conf
    install -m 600 "$project/tests/fixtures/synthetic.conf" "$file"
    install -m 600 "$project/tests/fixtures/synthetic.conf" "$sandbox/replacement"
    source <(repair_source _ lib/policy.sh)
    mf_test_profile_cli() {
        local file=$1 root=$2
        mf_profile_dump_guard() { :; } # Synthetic dump-safe CLI body only.
        source <(repair_source _ lib/state.sh)
        mf_profile_check "$file"
    }
    case $scenario in
        stable) ;;
        source) file=$sandbox/source/profile.conf; install -m 600 "$sandbox/replacement" "$file" ;;
        symlink) mv "$file" "$sandbox/original"; ln -s "$sandbox/original" "$file" ;;
        hardlink) ln "$file" "$sandbox/second" ;;
        mode) chmod 640 "$file" ;;
        parent) chmod 750 "$sandbox/private" ;;
        ancestor) chmod 770 "$sandbox" ;;
    esac
    # Preserve the exact validator and interpose only after successful validation,
    # before the original unchecked "before" stat or the repaired descriptor open.
    # This avoids timing dependencies in the old process-substitution stat.
    source <(declare -f mf_private_profile_file |
        sed '1s/mf_private_profile_file/mf_test_validate/')
    mf_private_profile_file() {
        mf_test_validate "$@" || return 1
        if [[ $scenario == race-* && $scenario != race-after-open &&
              ! -e $sandbox/fired ]]; then
            touch "$sandbox/fired"
            case $scenario in
                race-mode) chmod 644 "$sandbox/replacement"; mv "$sandbox/replacement" "$file" ;;
                race-inode) mv "$sandbox/replacement" "$file" ;;
                race-owner) mv "$sandbox/replacement" "$file" ;;
                race-symlink) mv "$file" "$sandbox/original"; ln -s "$sandbox/replacement" "$file" ;;
                race-hardlink) ln "$sandbox/replacement" "$sandbox/second"; mv "$sandbox/replacement" "$file" ;;
                race-parent)
                    mv "$sandbox/private" "$sandbox/old-parent"
                    mkdir -m 755 "$sandbox/private"
                    install -m 600 "$sandbox/replacement" "$file" ;;
                race-source)
                    mv "$sandbox/replacement" "$sandbox/source/replacement"
                    mv "$file" "$sandbox/original"
                    ln -s "$sandbox/source/replacement" "$file" ;;
            esac
        fi
    }
    if [[ $scenario == race-after-open ]]; then
        stat() {
            command stat "$@" || return
            if [[ ${*: -1} == /proc/self/fd/* && ! -e $sandbox/fired ]]; then
                touch "$sandbox/fired"
                mv "$sandbox/replacement" "$file"
            fi
            if [[ $scenario == race-owner ]]; then
                stat() {
                    if [[ -e $sandbox/fired &&
                          ( ${*: -1} == "$file" || ${*: -1} == /proc/self/fd/* ) ]]; then
                        command stat "$@" | sed -e "s/ $UID 600 / $((UID+1)) 600 /" \
                            -e "s/:$UID:600:/:$((UID+1)):600:/"
                    else command stat "$@"; fi
                }
            fi
        }
    fi
    # Wrong-owner descriptor metadata is simulated, without chown/root access.
    if [[ $scenario == descriptor-owner ]]; then
        stat() {
            if [[ ${*: -1} == /proc/self/fd/* ]]; then
                command stat "$@" | sed -e "s/ $UID 600 / $((UID+1)) 600 /" \
                    -e "s/:$UID:600:/:$((UID+1)):600:/"
            else command stat "$@"; fi
        }
    fi
    if diagnostic=$("$consumer" "$file" "$sandbox/source" 2>&1); then
        [[ $scenario == stable ]] || return 1
        mf_open_profile "$file" "$sandbox/source" || return 1
        mf_parse_profile <&"$MF_PROFILE_FD"
        exec {MF_PROFILE_FD}<&-
        [[ $MF_VALID == 1 ]]
    else
        [[ $scenario != stable && $diagnostic == *BLOCKED:* &&
           $diagnostic != *"$sandbox"* &&
           $diagnostic != *AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=* ]]
    fi
)

repair_encoding() (
    local file
    while IFS= read -r -d '' file; do
        if [[ $file == "$project/guest/desktop.sh" ]]; then
            if repair_source _ guest/desktop.sh | grep -qE $'\xe2\x80[\x93\x94]'; then return 1; fi
        elif grep -qE $'\xe2\x80[\x93\x94]' "$file"; then
            return 1
        fi
    done < <(find "$project/lib" "$project/guest" "$project/host" "$project/tests" "$project/mayfly.sh" -type f -print0)
)

check 'prepared browser policies preserve upstream defaults and lock updaters (synthetic guest)' repair_browser_policy
check 'accepted QEMU 8 args parse with default no reconnect (fake schema parser)' repair_qemu
check 'guest wildcard survives fake matching host files and exact argv parser' repair_guest_wildcard
for scenario in stable source symlink hardlink mode parent ancestor descriptor-owner \
    race-mode race-inode race-owner race-symlink race-hardlink race-parent race-source race-after-open \
    cli-stable cli-race-mode cli-race-inode cli-race-parent; do
    check "protected profile open, synthetic $scenario" repair_profile "$scenario"
done
check 'scripts and config contain no typographic dash codepoints' repair_encoding
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    printf '%s passed, %s failed. SYNTHETIC regression checks only.\n' "$passed" "$failed"
    (( failed == 0 ))
fi

check 'ancestry: only uid 0 or the overflow uid can be root-like, never an ordinary uid' bash -c '
    source "$1/lib/policy.sh"
    mf_root_owner 0 && ! mf_root_owner 1234' _ "$project"

check 'docs: every checksum tool named in the guides exists on this host' \
    bash -c 'for t in $(grep -ohE "sha[0-9]+sum" "$1/README.md" "$1/DEPLOYMENT.md" | sort -u); do command -v "$t" >/dev/null || { echo "missing $t"; exit 1; }; done' _ "$project"
check 'docs: checksum file names are real (SHA512SUMS, never a mangled number)' \
    bash -c '! grep -ohE "SHA[0-9]+SUMS" "$1/README.md" "$1/DEPLOYMENT.md" | grep -vqx "SHA512SUMS"' _ "$project"
