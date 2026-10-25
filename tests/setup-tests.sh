# Offline checks for state, fetch-pins, setup, core-policy and the new CLI
# defaults. Sourced by run.sh after host-tests.sh. No network, sudo or KVM:
# curl, gpg, gpgv, sysctl, sudo and pgrep are shell functions in each test.

mf_st_prelude='
    set -euo pipefail; export LC_ALL=C; umask 077
    neg() { if "$@"; then exit 1; fi; }
    project=$1; d=$2; shift 2
    export HOME=$d/home MAYFLY_HOME=$d/state
    unset XDG_STATE_HOME MF_CORE_STATE
    mkdir -p "$HOME"
    for f in policy host runtime build preflight state pins corepolicy attach; do source "$project/lib/$f.sh"; done
    root=$project
    usage() { printf "usage\n"; }
    run() { set +e; ( set -e; "$@" ) > "$d/out" 2>&1; rc=$?; set -e; }
'
mf_st() {
    local d rc=0
    d=$(mktemp -d "${TMPDIR:-/tmp}/mfst.XXXXXXXX")
    bash -c "$mf_st_prelude"'eval "$1"' _ "$project" "$d" "$1" || rc=$?
    rm -rf -- "$d"
    return "$rc"
}

mf_st_fetch_stubs='
    DEB=20260101-77; TOR=15.0.9
    IMG=debian-13-generic-amd64-$DEB.qcow2; ARC=tor-browser-linux-x86_64-$TOR.tar.xz
    FPR=EF6E286DDA85EA2A4BA7DE684E2C6E8793298290
    index_html="<a href=\"/images/cloud/\">Parent</a>
<a href=\"20250806-2196/\"><img></a><a href=\"20250806-2196/\">20250806-2196/</a>
<a href=\"$DEB/\">$DEB/</a>
<a href=\"daily/\">daily/</a><a href=\"latest/\">latest/</a>"
    tor_json() { printf "{\"comment\":\"c\",\"downloads\":{\"linux-x86_64\":{\"ALL\":{\"binary\":\"https://dist.torproject.org/torbrowser/%s/tor-browser-linux-x86_64-%s.tar.xz\"}}},\"tag\":\"t\",\"version\":\"%s\"}\n" "$1" "$1" "$1"; }
    sums() {
        local h IMG=debian-13-generic-amd64-${1##*/}.qcow2; h=$(printf "IMAGE\n" | sha512sum); h=${h%% *}
        case ${STUB_SUMS:-ok} in
            ok) printf "%s  %s\n" "$h" "$IMG" ;;
            star) printf "%s *%s\n" "$h" "$IMG" ;;
            bad) printf "%0128d  %s\n" 0 "$IMG" ;;
            missing) printf "%s  other-%s\n" "$h" "$IMG" ;;
            dup) printf "%s  %s\n%s  %s\n" "$h" "$IMG" "$h" "$IMG" ;;
            fields) printf "%s  %s extra\n" "$h" "$IMG" ;;
            short) printf "abc  %s\n" "$IMG" ;;
        esac
    }
    curl() {
        local out="" url=${*: -1}
        printf "%s\n" "$*" >> "$d/curl.log"
        while (( $# )); do if [[ $1 == --output ]]; then out=$2; fi; shift; done
        [[ -z ${STUB_FAIL:-} || $url != *"$STUB_FAIL"* ]] || return 22
        case $url in
            https://cloud.debian.org/images/cloud/trixie/) printf "%s\n" "$index_html" > "$out" ;;
            */downloads.json)
                if [[ -n ${STUB_TORJSON:-} ]]; then printf "%s\n" "$STUB_TORJSON" > "$out"; else tor_json "$TOR" > "$out"; fi ;;
            */SHA512SUMS) sums "${url%/SHA512SUMS}" > "$out" ;;
            *.qcow2) printf "IMAGE\n" > "$out" ;;
            *.tar.xz.asc) printf "SIG\n" > "$out" ;;
            *.tar.xz) printf "ARCHIVE\n" > "$out" ;;
            */by-fingerprint/*) printf "KEY\n" > "$out" ;;
            *) return 22 ;;
        esac
    }
    gpg() {
        local prev="" a out=""
        printf "gpg %s\n" "$*" >> "$d/gpg.log"
        for a in "$@"; do [[ $prev == --output ]] && out=$a; prev=$a; done
        case " $* " in
            *" --with-colons "*) printf "fpr:::::::::%s:\n" "${STUB_FPR:-$FPR}" ;;
            *" --export "*) printf "KEYRING\n" > "$out" ;;
        esac
        return "${STUB_GPG_RC:-0}"
    }
    gpgv() { printf "gpgv %s\n" "$*" >> "$d/gpgv.log"; return "${STUB_GPGV_RC:-0}"; }
    pins=$MAYFLY_HOME/pins/build.pins
    no_work_dir() { ! compgen -G "$MAYFLY_HOME/downloads/verified.*" >/dev/null; }
'

# ---- state directory -------------------------------------------------------
check 'state: create makes the 0700 state directory and four 0700 subdirectories' \
    mf_st 'out=$(mf_state_init create); [[ $out == "$d/state" ]]
        for n in "" /pins /bases /secrets /downloads; do [[ $(stat -c %a "$d/state$n") == 700 ]]; done'
check 'state: create is idempotent and keeps existing files' \
    mf_st 'mf_state_init create >/dev/null; printf keep > "$d/state/pins/build.pins"
        mf_state_init create >/dev/null; mf_state_init create >/dev/null
        [[ $(< "$d/state/pins/build.pins") == keep && $(stat -c %a "$d/state/pins") == 700 ]]'
check 'state: default directory follows MAYFLY_HOME, then XDG_STATE_HOME, then HOME' \
    mf_st '[[ $(mf_state_dir) == "$d/state" ]]
        unset MAYFLY_HOME; export XDG_STATE_HOME=$d/xdg; [[ $(mf_state_dir) == "$d/xdg/mayfly" ]]
        unset XDG_STATE_HOME; [[ $(mf_state_dir) == "$HOME/.local/state/mayfly" ]]'
check 'state: the HOME default is created with private permissions' \
    mf_st 'unset MAYFLY_HOME; out=$(mf_state_init create); [[ $out == "$HOME/.local/state/mayfly" && $(stat -c %a "$out/secrets") == 700 ]]'
check 'state: a relative or unusual state path is refused' \
    mf_st 'for p in relative/dir "$d/a b" "$d/a;b" "$d/../x"; do ( MAYFLY_HOME=$p; mf_state_init create ) >/dev/null 2>&1 && exit 1; done; true'
check 'state: a symlinked state directory is refused and the target is left alone' \
    mf_st 'mkdir -m 700 "$d/real"; ln -s "$d/real" "$d/state"
        neg mf_state_init create >/dev/null 2>&1; [[ -z $(ls -A "$d/real") ]]'
check 'state: a symlinked subdirectory is refused' \
    mf_st 'mf_state_init create >/dev/null; rmdir "$d/state/bases"; mkdir "$d/other"; ln -s "$d/other" "$d/state/bases"
        neg mf_state_init create >/dev/null 2>&1; neg mf_state_init check >/dev/null 2>&1'
check 'state: a state directory with a loose mode is refused, never repaired' \
    mf_st 'mf_state_init create >/dev/null; chmod 755 "$d/state"
        neg mf_state_init create >/dev/null 2>&1; [[ $(stat -c %a "$d/state") == 755 ]]'
check 'state: a subdirectory with a loose mode is refused' \
    mf_st 'mf_state_init create >/dev/null; chmod 750 "$d/state/secrets"
        neg mf_state_init create >/dev/null 2>&1; neg mf_state_init check >/dev/null 2>&1'
check 'state: a directory owned by someone else is refused' \
    mf_st 'mf_state_init create >/dev/null
        stat() { command stat "$@" | sed "s/^$UID:/$((UID + 1)):/"; }
        neg mf_state_init create >/dev/null 2>&1'
check 'state: check mode never creates anything' \
    mf_st 'neg mf_state_init check >/dev/null 2>&1; [[ ! -e $d/state ]]
        mf_state_init create >/dev/null; rmdir "$d/state/downloads"
        neg mf_state_init check >/dev/null 2>&1; [[ ! -e $d/state/downloads ]]'
check 'state: the dedicated-user layout (root-owned 0711 top) is accepted for checks only' \
    mf_st '(( EUID != 0 )) || exit 0
        mf_state_init create >/dev/null; chmod 711 "$d/state"; rmdir "$d/state/downloads"
        stat() { if [[ ${*: -1} == "$d/state" ]]; then printf "0:711\n"; else command stat "$@"; fi; }
        neg mf_state_init create >/dev/null 2>&1; [[ ! -e $d/state/downloads ]]
        mkdir -m 700 "$d/state/downloads"; [[ $(mf_state_init create) == "$d/state" ]]'
check 'state: default pins and profile paths sit inside the state directory' \
    mf_st '[[ $(mf_state_pins_file /s) == /s/pins/build.pins && $(mf_state_profile_file /s) == /s/secrets/wireguard.conf ]]'

mf_st_bases='
    mf_state_init create >/dev/null
    mk() { mkdir -m 700 "$d/state/bases/$1"; : > "$d/state/bases/$1/gateway.qcow2"; : > "$d/state/bases/$1/browser.qcow2"
        : > "$d/state/bases/$1/browser.sha256"; touch -d "$2" "$d/state/bases/$1/browser.sha256"; }
'
check 'state: newest base is chosen by build time, not by name' \
    mf_st "$mf_st_bases"'mk zzz-old "2023-01-01"; mk aaa-new "2024-06-01"; mk mid "2024-01-01"
        [[ $(mf_state_newest_base "$d/state") == aaa-new ]]'
check 'state: equal build times fall back to the higher name' \
    mf_st "$mf_st_bases"'mk b-a "2024-01-01"; mk b-z "2024-01-01"; [[ $(mf_state_newest_base "$d/state") == b-z ]]'
check 'state: incomplete, symlinked and oddly named directories are never selected' \
    mf_st "$mf_st_bases"'mk good "2020-01-01"
        mkdir -m 700 "$d/state/bases/partial"; : > "$d/state/bases/partial/gateway.qcow2"
        mkdir -m 700 "$d/state/bases/partial2"; : > "$d/state/bases/partial2/browser.qcow2"; touch -d 2031-01-01 "$d/state/bases/partial2/browser.qcow2"
        mk "bad name" "2030-01-01"; mk ".hidden" "2030-01-01"
        ln -s "$d/state/bases/good" "$d/state/bases/linked"
        [[ $(mf_state_newest_base "$d/state") == good ]]'
check 'state: no base means a failure, not an empty name' \
    mf_st "$mf_st_bases"'neg mf_state_newest_base "$d/state" >/dev/null'

# ---- discovery parsers ------------------------------------------------------
export MF_IDX='<a href="/images/cloud/">Parent</a><a href="20250806-2196/">x</a><a href="20250806-2196/">20250806-2196/</a><a href="20261021-2638/">y</a><a href="daily/">d</a><a href="latest/">l</a><a href="?C=N;O=D">n</a>'
check 'discovery: Debian index picks the highest DATE-BUILD directory' \
    mf_st '[[ $(mf_pins_parse_debian_index <<< "$MF_IDX") == 20261021-2638 ]]'
check 'discovery: Debian build numbers compare as numbers' \
    mf_st '[[ $(mf_pins_parse_debian_index <<< "<a href=\"20260101-999/\"></a><a href=\"20260101-1000/\"></a><a href=\"20251231-5000/\"></a>") == 20260101-1000 ]]'
check 'discovery: hostile Debian index entries are all ignored' \
    mf_st 'for h in "../20991231-9/" "http://evil.example/20991231-9/" "20991231-9/../x/" "20991231-9" "2099123-9/" "20991231-/" "20991231-1234567890/" "/images/20991231-9/" "20991231-9/;id/" "daily/" "latest/"; do
            neg mf_pins_parse_debian_index <<< "<a href=\"$h\">x</a>"; done
        [[ $(mf_pins_parse_debian_index <<< "<a href=\"../20991231-9/\"></a><a href=\"20240101-1/\"></a><a href=\"20991231-9/../x/\"></a>") == 20240101-1 ]]'
check 'discovery: an empty or non-HTML Debian index is an error' \
    mf_st 'neg mf_pins_parse_debian_index <<< ""; neg mf_pins_parse_debian_index <<< "{\"version\":\"20260101-1\"}"'
check 'discovery: Tor version comes from a stable downloads.json and ignores extra fields' \
    mf_st "$mf_st_fetch_stubs"'[[ $(tor_json 15.0.26 | mf_pins_parse_tor_json) == 15.0.26 ]]
        [[ $(tor_json 14.5.2 | jq -c ". + {extra: [1,2], tag: \"x\"}" | mf_pins_parse_tor_json) == 14.5.2 ]]'
check 'discovery: alpha, rc, traversal and odd Tor versions are rejected' \
    mf_st "$mf_st_fetch_stubs"'for v in 15.0a3 15.0.1-rc1 15 15. .15 15..1 ../../1.2 "15.0.1 " "1.2;id" 15.0b1 "$(printf "1.%.0s" {1..20})9"; do
            neg mf_pins_parse_tor_json <<< "$(tor_json "$v")"; done'
check 'discovery: Tor JSON that is malformed, empty or of the wrong type is rejected' \
    mf_st 'for j in "" "not json" "{}" "[]" "{\"version\":15.0}" "{\"version\":null}" "{\"version\":[\"15.0.1\"]}" "{\"version\":\"15.0.1\"}"; do
            neg mf_pins_parse_tor_json <<< "$j"; done'
check 'discovery: a Tor version that disagrees with the linux-x86_64 archive URL is rejected' \
    mf_st "$mf_st_fetch_stubs"'neg mf_pins_parse_tor_json <<< "$(tor_json 15.0.9 | sed "s/torbrowser\/15.0.9\//torbrowser\/15.0.8\//")"
        neg mf_pins_parse_tor_json <<< "$(tor_json 15.0.9 | sed "s/dist.torproject.org/evil.example/")"
        neg mf_pins_parse_tor_json <<< "$(tor_json 15.0.9 | jq -c "del(.downloads)")"'

# ---- fetch-pins end to end --------------------------------------------------
check 'fetch-pins: success writes exactly four validated fields, mode 0600' \
    mf_st "$mf_st_fetch_stubs"'run mf_fetch_pins --yes; [[ $rc == 0 && -f $pins ]]
        [[ $(stat -c %a "$pins") == 600 && $(wc -l < "$pins") == 4 ]]
        mf_build_config "$pins"
        isha=$(printf "IMAGE\n" | sha256sum); isha=${isha%% *}; tsha=$(printf "ARCHIVE\n" | sha256sum); tsha=${tsha%% *}
        [[ $(< "$pins") == "IMAGE_URL=https://cloud.debian.org/images/cloud/trixie/$DEB/$IMG
IMAGE_SHA256=$isha
TOR_URL=https://dist.torproject.org/torbrowser/$TOR/$ARC
TOR_SHA256=$tsha" ]]'
check 'fetch-pins: discovery picks the highest Debian build and the stable Tor version' \
    mf_st "$mf_st_fetch_stubs"'run mf_fetch_pins --yes; [[ $rc == 0 ]]
        grep -q "trixie/$DEB/$IMG\$" "$d/curl.log"
        grep -q "torbrowser/$TOR/$ARC\$" "$d/curl.log"
        neg grep -q "20250806-2196/debian" "$d/curl.log"'
check 'fetch-pins: every download is https-only, TLS 1.2+, three redirects at most' \
    mf_st "$mf_st_fetch_stubs"'run mf_fetch_pins --yes; [[ $rc == 0 ]]
        [[ $(wc -l < "$d/curl.log") -ge 7 ]]
        while IFS= read -r line; do
            [[ $line == *"--proto =https "* && $line == *"--proto-redir =https "* && $line == *"--tlsv1.2 "* &&
               $line == *"--max-redirs 3 "* && $line == *"--fail "* && ${line##* } == https://* ]] || exit 1
        done < "$d/curl.log"'
check 'fetch-pins: gpgv gets an absolute keyring path and the pinned Tor key is requested by fingerprint' \
    mf_st "$mf_st_fetch_stubs"'run mf_fetch_pins --yes; [[ $rc == 0 ]]
        grep -Eq "^gpgv --homedir gnupg --keyring /[^ ]+/tor-keyring.gpg tor-browser.*\.asc tor-browser" "$d/gpgv.log"
        grep -q "keys.openpgp.org/vks/v1/by-fingerprint/EF6E286DDA85EA2A4BA7DE684E2C6E8793298290\$" "$d/curl.log"'
check 'fetch-pins: the signing fingerprint constant matches lib/build.sh' \
    bash -c 'source "$1/lib/policy.sh"; source "$1/lib/pins.sh"
        [[ $MF_TOR_FPR == EF6E286DDA85EA2A4BA7DE684E2C6E8793298290 ]] && grep -q "fpr=EF6E286DDA85EA2A4BA7DE684E2C6E8793298290" "$1/lib/build.sh"' _ "$project"
check 'fetch-pins: states plainly that Debian has no detached signature and shows exact URLs' \
    mf_st "$mf_st_fetch_stubs"'run mf_fetch_pins --yes
        grep -q "publishes no detached signature" "$d/out"
        grep -q "https://cloud.debian.org/images/cloud/trixie/$DEB/$IMG" "$d/out"
        grep -q "https://dist.torproject.org/torbrowser/$TOR/$ARC" "$d/out"'
check 'fetch-pins: a SHA512SUMS entry in the star form is accepted' \
    mf_st "$mf_st_fetch_stubs"'export STUB_SUMS=star; run mf_fetch_pins --yes; [[ $rc == 0 && -f $pins ]]'
mf_st_fp_fail='
    run mf_fetch_pins --yes
    [[ $rc != 0 ]]
    [[ ! -e $pins && ! -L $pins ]]
    no_work_dir
    grep -q "^BLOCKED: fetch-pins: " "$d/out"
'
for mf_case in \
    'STUB_SUMS=bad|SHA-512 check failed' \
    'STUB_SUMS=missing|exactly once' \
    'STUB_SUMS=dup|exactly once' \
    'STUB_SUMS=fields|exactly once' \
    'STUB_SUMS=short|not a SHA-512 digest' \
    'STUB_GPGV_RC=1|signature check failed' \
    'STUB_GPG_RC=2|key import failed' \
    'STUB_FPR=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA|fingerprint mismatch' \
    'STUB_FAIL=.qcow2|image download failed' \
    'STUB_FAIL=SHA512SUMS|SHA512SUMS download failed' \
    'STUB_FAIL=tor-browser-linux-x86_64-15.0.9.tar.xz|Tor Browser' \
    'STUB_FAIL=by-fingerprint|signing key download failed'; do
    check "fetch-pins: no pins file and a named failure for ${mf_case%%|*}" \
        mf_st "$mf_st_fetch_stubs"'export "'"${mf_case%%|*}"'"'"$mf_st_fp_fail"'grep -q "'"${mf_case#*|}"'" "$d/out"'
done
check 'fetch-pins: a hostile discovered Tor version stops before any archive download' \
    mf_st "$mf_st_fetch_stubs"'export STUB_TORJSON=$(tor_json 15.0a3); '"$mf_st_fp_fail"'grep -q "no valid stable Tor" "$d/out"; neg grep -q "tar.xz\|qcow2" "$d/curl.log"'
check 'fetch-pins: a hostile Debian index stops before any image download' \
    mf_st "$mf_st_fetch_stubs"'index_html="<a href=\"../20991231-1/\">x</a>"; '"$mf_st_fp_fail"'grep -q "no valid DATE-BUILD" "$d/out"; neg grep -q "qcow2" "$d/curl.log"'
check 'fetch-pins: an existing pins file is refused and left untouched, with no download' \
    mf_st "$mf_st_fetch_stubs"'mf_state_init create >/dev/null; printf KEEP > "$pins"
        run mf_fetch_pins --yes; [[ $rc != 0 && $(< "$pins") == KEEP && ! -e $d/curl.log ]]
        rm -f "$pins"; ln -s "$d/target" "$pins"; run mf_fetch_pins --yes; [[ $rc != 0 && ! -e $d/target && ! -e $d/curl.log ]]'
check 'fetch-pins: an explicit absolute pins file path is used, a relative one refused' \
    mf_st "$mf_st_fetch_stubs"'mf_state_init create >/dev/null; run mf_fetch_pins --yes "$d/state/pins/custom.pins"; [[ $rc == 0 && -f $d/state/pins/custom.pins && ! -e $pins ]]
        run mf_fetch_pins --yes custom.pins; [[ $rc != 0 ]]; run mf_fetch_pins --yes /a /b; [[ $rc != 0 ]]'
check 'fetch-pins: a pins file that fails the build validators is removed and reported' \
    mf_st "$mf_st_fetch_stubs"'mf_state_init create >/dev/null; run mf_fetch_pins --yes "$d/state/pins/a,b.pins"
        [[ $rc != 0 && ! -e $d/state/pins/a,b.pins ]]; grep -q "failed validation" "$d/out"; no_work_dir'
check 'fetch-pins: --debian and --tor skip discovery entirely' \
    mf_st "$mf_st_fetch_stubs"'run mf_fetch_pins --yes --debian 20250806-2196 --tor 14.5.2
        [[ $rc == 0 ]]; neg grep -q "downloads.json" "$d/curl.log"; neg grep -q "trixie/\$" "$d/curl.log"
        grep -q "trixie/20250806-2196/debian-13-generic-amd64-20250806-2196.qcow2" "$d/curl.log"; grep -q "^IMAGE_URL=.*20250806-2196" "$pins"'
check 'fetch-pins: malformed --debian, --tor and options are refused before any network use' \
    mf_st "$mf_st_fetch_stubs"'for a in "--debian ../x" "--debian 20250806" "--debian latest" "--tor 15.0a3" "--tor 1.2;id" "--tor" "--debian" "--bogus"; do
            run mf_fetch_pins --yes $a; [[ $rc != 0 && ! -e $d/curl.log && ! -e $pins ]]; done'
check 'fetch-pins: without a terminal and without --yes it refuses after the version lookup only' \
    mf_st "$mf_st_fetch_stubs"'mf_stdin_is_tty() { return 1; }
        run mf_fetch_pins; [[ $rc != 0 && ! -e $pins ]]; grep -q -- "--yes" "$d/out"
        [[ $(wc -l < "$d/curl.log") == 2 ]]; neg grep -q "qcow2\|tar.xz" "$d/curl.log"; no_work_dir'
check 'fetch-pins: explicit versions without a terminal or --yes download nothing at all' \
    mf_st "$mf_st_fetch_stubs"'mf_stdin_is_tty() { return 1; }
        run mf_fetch_pins --debian 20250806-2196 --tor 14.5.2; [[ $rc != 0 && ! -e $d/curl.log && ! -e $pins ]]'
check 'fetch-pins: the prompt accepts only y, Y or yes' \
    mf_st "$mf_st_fetch_stubs"'mf_stdin_is_tty() { return 0; }
        for a in n N "" no yep " y" "y "; do rm -rf "$d/curl.log" "$d/state"; run mf_fetch_pins --debian 20250806-2196 --tor 14.5.2 <<< "$a"
            [[ $rc != 0 && ! -e $pins && ! -e $d/curl.log ]]; grep -q "Continue? \[y/N\]" "$d/out"; done
        for a in y Y yes; do rm -rf "$d/curl.log" "$d/state"; run mf_fetch_pins --debian 20250806-2196 --tor 14.5.2 <<< "$a"; [[ $rc == 0 && -f $pins ]]; done
        rm -rf "$d/state"; run mf_fetch_pins --debian 20250806-2196 --tor 14.5.2 < /dev/null; [[ $rc != 0 && ! -e $pins ]]'

# ---- core-dump policy -------------------------------------------------------
mf_st_core='
    export MF_PROC_SYS=$d/proc; mkdir -p "$MF_PROC_SYS/kernel/random" "$MF_PROC_SYS/fs"
    BOOT=0123abcd-0123-4abc-8abc-0123456789ab
    printf "%s\n" "$BOOT" > "$MF_PROC_SYS/kernel/random/boot_id"
    setcore() { printf "%s\n" "$1" > "$MF_PROC_SYS/kernel/core_pattern"; printf "%s\n" "$2" > "$MF_PROC_SYS/fs/suid_dumpable"; }
    getcore() { printf "%s|%s\n" "$(< "$MF_PROC_SYS/kernel/core_pattern")" "$(< "$MF_PROC_SYS/fs/suid_dumpable")"; }
    rd=$(realpath -e "$d")/root; mkdir -p "$rd"; printf "#!/bin/sh\n" > "$rd/systemd-coredump"; chmod 755 "$rd/systemd-coredump"; cp "$rd/systemd-coredump" "$rd/apport"; mkdir -p "$rd/np" "$rd/ln"
    declare -A FAKE=()
    mf_core_stat_info() { if [[ -n ${FAKE[$1]:-} ]]; then printf "%s\n" "${FAKE[$1]}"; else printf "0 755\n"; fi; }
    PIPE="|$rd/systemd-coredump %P %u %g"
    setcore "$PIPE" 2
    snap=$MAYFLY_HOME/core-policy/$BOOT/original.conf
    sysctl() {
        local kv line
        printf "sysctl %s\n" "$*" >> "$d/sysctl.log"
        case $1 in
            -w) shift
                for kv in "$@"; do
                    case $kv in
                        kernel.core_pattern=*) printf "%s\n" "${kv#*=}" > "$MF_PROC_SYS/kernel/core_pattern" ;;
                        fs.suid_dumpable=*) [[ ${STUB_SYSCTL_FAIL:-} == partial ]] && return 1
                            printf "%s\n" "${kv#*=}" > "$MF_PROC_SYS/fs/suid_dumpable" ;;
                    esac
                done ;;
            -p) while IFS= read -r line; do
                    case $line in
                        kernel.core_pattern=*) printf "%s\n" "${line#*=}" > "$MF_PROC_SYS/kernel/core_pattern" ;;
                        fs.suid_dumpable=*) printf "%s\n" "${line#*=}" > "$MF_PROC_SYS/fs/suid_dumpable" ;;
                    esac
                done < "$2" ;;
        esac
    }
    sudo() { printf "sudo %s\n" "$1" >> "$d/sudo.log"; "$@"; }
    pgrep() { return "${STUB_PGREP_RC:-1}"; }
'
check 'core-policy: apply snapshots once (0600 in 0700 dirs), sets /dev/null and 0, explains itself' \
    mf_st "$mf_st_core"'mf_core_apply > "$d/o" 2>&1
        [[ $(getcore) == "/dev/null|0" && $(stat -c %a "$snap") == 600 ]]
        [[ $(stat -c %a "$d/state/core-policy") == 700 && $(stat -c %a "$d/state/core-policy/$BOOT") == 700 ]]
        [[ $(< "$snap") == "kernel.core_pattern=$PIPE
fs.suid_dumpable=2" ]]
        grep -q "^sysctl -w kernel.core_pattern=/dev/null fs.suid_dumpable=0\$" "$d/sysctl.log"
        grep -q "do not hibernate" "$d/o"
        (( EUID == 0 )) || { grep -q "^sudo sysctl\$" "$d/sudo.log"; grep -q "whole host" "$d/o"; }'
check 'core-policy: apply does nothing when the host already satisfies the requirement' \
    mf_st "$mf_st_core"'setcore /dev/null 0; mf_core_apply > "$d/o" 2>&1; grep -q "already satisfies" "$d/o"
        [[ ! -e $d/sysctl.log && ! -e $d/state/core-policy ]]
        setcore core 0; mf_core_apply > "$d/o" 2>&1; [[ ! -e $d/sysctl.log ]]'
check 'core-policy: a snapshot is created once per boot and never overwritten' \
    mf_st "$mf_st_core"'mf_core_apply >/dev/null 2>&1; before=$(sha256sum < "$snap"); mf_core_restore >/dev/null 2>&1
        setcore core 1; mf_core_apply >/dev/null 2>&1
        [[ $(sha256sum < "$snap") == "$before" && $(getcore) == "/dev/null|0" ]]
        mf_core_restore >/dev/null 2>&1; [[ $(getcore) == "$PIPE|2" ]]'
check 'core-policy: restore re-applies the saved values, including a piped collector' \
    mf_st "$mf_st_core"'mf_core_apply >/dev/null 2>&1; mf_core_restore >/dev/null 2>&1
        [[ $(getcore) == "$PIPE|2" ]]; grep -qF "sysctl -w kernel.core_pattern=$PIPE fs.suid_dumpable=2" "$d/sysctl.log"; neg grep -q "sysctl -p" "$d/sysctl.log"'
check 'core-policy: restore is refused while a QEMU process exists or inspection fails' \
    mf_st "$mf_st_core"'mf_core_apply >/dev/null 2>&1; : > "$d/sysctl.log"
        for rc in 0 2 127; do STUB_PGREP_RC=$rc; neg mf_core_restore >/dev/null 2>&1; [[ $(getcore) == "/dev/null|0" && ! -s $d/sysctl.log ]]; done
        STUB_PGREP_RC=1; mf_core_restore >/dev/null 2>&1; [[ $(getcore) == "$PIPE|2" ]]'
check 'core-policy: restore without a snapshot changes nothing' \
    mf_st "$mf_st_core"'neg mf_core_restore >/dev/null 2>&1; [[ ! -e $d/sysctl.log && $(getcore) == "$PIPE|2" ]]'
check 'core-policy: a tampered snapshot is refused (mode, symlink, hard link, shape, values)' \
    mf_st "$mf_st_core"'snap=$(mf_core_snapshot_path); good="kernel.core_pattern=core
fs.suid_dumpable=0"
        put() { rm -f "$snap" "$snap.x"; printf "%s\n" "$1" > "$snap"; chmod "${2:-600}" "$snap"; }
        put "$good" 644; neg mf_core_restore >/dev/null 2>&1
        put "$good"; ln "$snap" "$snap.x"; neg mf_core_restore >/dev/null 2>&1; rm -f "$snap.x"
        rm -f "$snap"; printf "%s\n" "$good" > "$d/real"; ln -s "$d/real" "$snap"; neg mf_core_restore >/dev/null 2>&1; rm -f "$snap"
        put "$good
extra=1"; neg mf_core_restore >/dev/null 2>&1
        put "kernel.core_pattern=core
fs.suid_dumpable=7"; neg mf_core_restore >/dev/null 2>&1
        put "kernel.core_pattern=
fs.suid_dumpable=1"; neg mf_core_restore >/dev/null 2>&1
        put "fs.suid_dumpable=1
kernel.core_pattern=core"; neg mf_core_restore >/dev/null 2>&1
        [[ ! -e $d/sysctl.log ]]
        put "$good"; mf_core_restore >/dev/null 2>&1; [[ $(getcore) == "core|0" ]]'
check 'core-policy: snapshot text is data, and a hostile pipe or odd pattern never reaches sudo or sysctl' \
    mf_st "$mf_st_core"'(( EUID == 0 )) && exit 0
        snap=$(mf_core_snapshot_path); chmod 600 "$d/state/core-policy/$BOOT/original.conf" 2>/dev/null || :
        ln -s "$rd/systemd-coredump" "$rd/ln/apport"; cp "$rd/systemd-coredump" "$rd/np/apport"; chmod 644 "$rd/np/apport"
        hostile() { # label, pattern, [fake path, fake stat]
            rm -f "$d/sysctl.log" "$d/sudo.log"; FAKE=(); [[ -z ${3:-} ]] || FAKE[$3]=$4
            printf "kernel.core_pattern=%s\nfs.suid_dumpable=0\n" "$2" > "$snap"; chmod 600 "$snap"
            neg mf_core_restore >/dev/null 2>&1
            [[ ! -e $d/sysctl.log && ! -e $d/sudo.log && ! -e $d/PWNED && $(getcore) == "$PIPE|2" ]] || { echo "leaked: $1" >&2; exit 1; }
        }
        hostile user-owned-helper "|$rd/systemd-coredump %P" "$rd/systemd-coredump" "$UID 755"
        hostile writable-helper "|$rd/systemd-coredump %P" "$rd/systemd-coredump" "0 775"
        hostile world-writable-helper "|$rd/systemd-coredump %P" "$rd/systemd-coredump" "0 757"
        hostile user-owned-ancestor "|$rd/systemd-coredump %P" "$rd" "$UID 755"
        hostile writable-ancestor "|$rd/systemd-coredump %P" "$rd" "0 777"
        hostile writable-upper-ancestor "|$rd/systemd-coredump %P" "$(dirname "$rd")" "0 775"
        hostile relative "|handler %P"; hostile dot-relative "|./handler %P"; hostile traversal "|$rd/../root/handler %P"
        hostile symlink "|$rd/ln/apport %P"; hostile missing "|$rd/np/systemd-coredump %P"; hostile not-executable "|$rd/np/apport %P"
        hostile env-script "|/usr/bin/env /home/u/evil.sh"; hostile bash-script "|/usr/bin/bash /home/u/x"; hostile env-S "|/usr/bin/env -S x"
        hostile python-c "|/usr/bin/python3 -c%c"; hostile perl "|/usr/bin/perl %P"; hostile sh "|/bin/sh -c%c"
        hostile renamed-interpreter "|$rd/systemd-coredump2 %P"; hostile prefix-name "|$rd/not-apport %P"; hostile suffix-name "|$rd/apport.sh %P"
        hostile coredump-path-arg "|$rd/systemd-coredump /home/u/x"; hostile coredump-dash-S "|$rd/systemd-coredump -S"
        hostile coredump-long-opt "|$rd/systemd-coredump --exec=%P"; hostile coredump-glued-path "|$rd/systemd-coredump -p/home/u/x"
        hostile coredump-pp "|$rd/systemd-coredump -pp"; hostile coredump-ps "|$rd/systemd-coredump -ps"; hostile coredump-bare-opt "|$rd/systemd-coredump -p"; hostile coredump-two-letter "|$rd/systemd-coredump -pp%p"; hostile coredump-bare-word "|$rd/systemd-coredump P"
        hostile coredump-digit "|$rd/systemd-coredump -p5"; hostile coredump-eq "|$rd/systemd-coredump x=%P"; hostile coredump-pct-pair "|$rd/systemd-coredump %PP"
        hostile double-space "|$rd/systemd-coredump  %P"; hostile trailing-space "|$rd/systemd-coredump %P "; hostile leading-space "| $rd/systemd-coredump %P"
        hostile tab "|$rd/systemd-coredump	%P"; hostile tab-arg "|$rd/systemd-coredump %P	/home/u/x"; hostile newline-arg "|$rd/systemd-coredump %P
/home/u/x"
        hostile metachar "|$rd/systemd-coredump %P;id"; hostile subshell "|$rd/systemd-coredump \$(touch $d/PWNED)"
        hostile empty-pipe "|"; hostile space-pipe "| "
        hostile cmd-subst "\$(touch $d/PWNED)"; hostile plain-space "core file"; hostile plain-semicolon "core;id"; hostile plain-backtick "core\`id\`"
        printf "kernel.core_pattern=core\nfs.suid_dumpable=1\nkernel.core_pattern=|/home/u/evil\n" > "$snap"; neg mf_core_restore >/dev/null 2>&1; [[ ! -e $d/sysctl.log ]]'
check 'core-policy: the reviewer repro (env with a user script) is refused and the allow-list is a fixed readonly array' \
    mf_st "$mf_st_core"'neg mf_core_pattern_safe "|/usr/bin/env /home/u/evil" 0; neg mf_core_pattern_safe "|/usr/bin/env /home/u/evil.sh" 2
        mf_core_pattern_safe "|$rd/apport -p%p -- %E" 0; [[ $(declare -p MF_CORE_COLLECTORS) == "declare -ar"* ]]
        [[ ${MF_CORE_COLLECTORS[*]} == "systemd-coredump apport abrt-hook-ccpp" ]]'
check 'core-policy: an exported scalar MF_CORE_COLLECTORS cannot widen the allow-list' \
    env MF_CORE_COLLECTORS=env bash -c 'source "$1/lib/policy.sh"; source "$1/lib/host.sh"; source "$1/lib/corepolicy.sh"; source "$1/lib/corepolicy.sh"
        [[ ${MF_CORE_COLLECTORS[*]} == "systemd-coredump apport abrt-hook-ccpp" && $(declare -p MF_CORE_COLLECTORS) == "declare -ar"* ]] && ! mf_core_collector_known env' _ "$project"
check 'core-policy: value pairs reaching sudo (suid_dumpable and pattern) follow the pairing rules' \
    mf_st "$mf_st_core"'(( EUID == 0 )) && exit 0
        snap=$(mf_core_snapshot_path)
        pair() { # pattern suid; restore must be refused with sudo and sysctl never called
            rm -f "$d/sysctl.log" "$d/sudo.log"; printf "kernel.core_pattern=%s\nfs.suid_dumpable=%s\n" "$1" "$2" > "$snap"; chmod 600 "$snap"
            neg mf_core_restore >/dev/null 2>&1
            [[ ! -e $d/sysctl.log && ! -e $d/sudo.log && $(getcore) == "$PIPE|2" ]] || { echo "leaked: $1 $2" >&2; exit 1; }
        }
        pair /etc/cron.d/zz 2; pair /etc/profile.d/x.sh 2; pair /var/crash/core.%p 2; pair core 2; pair core.%p 2; pair /dev/null 2
        pair core 1; pair /dev/null 1; pair "|$rd/systemd-coredump %P" 1; pair /etc/cron.d/zz 0; pair /var/crash/core.%p 0; pair /dev/null/x 0
        pair .hidden 0; pair ../core 0; pair a..b 0; pair a/b 0; pair -core 0; pair "core file" 0; pair core 7
        ok() { setcore "$PIPE" 2; rm -f "$d/sysctl.log"; printf "kernel.core_pattern=%s\nfs.suid_dumpable=%s\n" "$1" "$2" > "$snap"; chmod 600 "$snap"
            mf_core_restore >/dev/null 2>&1; [[ $(getcore) == "$1|$2" ]] || { echo "refused: $1 $2" >&2; exit 1; }; }
        ok core 0; ok /dev/null 0; ok "core.%e.%p:%t" 0; ok "|$rd/systemd-coredump %P %u %g" 0; ok "|$rd/systemd-coredump %P %u %g" 2
        ok "|$rd/apport -p%p -s%s -c%c -d%d -P%P -u%u -g%g -- %E" 2'
check 'wrapper: loading the core-policy helpers drops inherited overrides and fixes the state path' \
    mf_sub 'MF_PROG='"$project"'; MF_STATE=/var/lib/mayfly; export MF_PROC_SYS=/tmp/evil-proc MF_CORE_STATE=/tmp/evil-state
        mf_load_core_policy
        [[ -z ${MF_PROC_SYS+x} && $MF_CORE_STATE == /var/lib/mayfly ]]
        [[ $(mf_core_value kernel/core_pattern) == "$(< /proc/sys/kernel/core_pattern)" ]]'
check 'core-policy: known collectors behind root-owned directories with specifier-only arguments, and plain patterns, are accepted' \
    mf_st "$mf_st_core"'(( EUID == 0 )) && exit 0
        snap=$(mf_core_snapshot_path)
        for p in "|$rd/systemd-coredump %P %u %g" "|$rd/apport -p%p -s%s -c%c -d%d -P%P -u%u -g%g -- %E" "|$rd/systemd-coredump %P %u %g %s %t %c %h" "|$rd/systemd-coredump" "core" "/dev/null" "core.%e.%p:%t"; do
            setcore "$PIPE" 2; rm -f "$d/sysctl.log"; printf "kernel.core_pattern=%s\nfs.suid_dumpable=0\n" "$p" > "$snap"; chmod 600 "$snap"
            mf_core_restore >/dev/null 2>&1; [[ $(getcore) == "$p|0" ]]; grep -qF "sysctl -w kernel.core_pattern=$p fs.suid_dumpable=0" "$d/sysctl.log"
        done'
check 'core-policy: sysctl only ever receives the validated values, even if the snapshot is swapped mid-restore' \
    mf_st "$mf_st_core"'(( EUID == 0 )) && exit 0
        snap=$(mf_core_snapshot_path); printf "kernel.core_pattern=core\nfs.suid_dumpable=0\n" > "$snap"; chmod 600 "$snap"
        mf_core_sessions_running() { printf "kernel.core_pattern=|/home/u/evil\nfs.suid_dumpable=0\n" > "$snap"; return 1; }
        mf_core_restore >/dev/null 2>&1; [[ $(getcore) == "core|0" ]]
        neg grep -q "evil" "$d/sysctl.log"; neg grep -q "sysctl -p" "$d/sysctl.log"'
check 'core-policy: the trusted owner is fixed to root and cannot be set from the environment' \
    bash -c 'source "$1/lib/policy.sh"; source "$1/lib/host.sh"; source "$1/lib/corepolicy.sh"
        [[ $(MF_CORE_TRUSTED_UID=1000 mf_core_trusted_owner) == 0 ]] && ! grep -q "MF_CORE_TRUSTED" "$1/lib/corepolicy.sh"' _ "$project"
check 'core-policy: without sudo it fails clearly and changes nothing' \
    mf_st "$mf_st_core"'(( EUID == 0 )) && exit 0
        unset -f sudo; PATH=$d/nopath; neg mf_core_apply 2> "$d/o" >/dev/null
        [[ $(< "$d/o") == *"sudo is not available"* && $(getcore) == "$PIPE|2" && ! -e $d/sysctl.log && ! -e $d/state/core-policy ]]'
check 'core-policy: a failing sudo or sysctl leaves the snapshot and reports failure' \
    mf_st "$mf_st_core"'sudo() { return 1; }; (( EUID == 0 )) && exit 0
        neg mf_core_apply >/dev/null 2>&1; [[ $(getcore) == "$PIPE|2" && $(stat -c %a "$snap") == 600 ]]'
check 'core-policy: root mode keeps the snapshot under MF_CORE_STATE, not the user state directory' \
    mf_st "$mf_st_core"'export MF_CORE_STATE=$d/cs; mkdir -m 700 "$d/cs"
        mf_core_apply >/dev/null 2>&1; [[ -f $d/cs/core-policy/$BOOT/original.conf && ! -e $d/state ]]'
check 'core-policy: status reads only, and reports requirement, snapshot and sessions' \
    mf_st "$mf_st_core"'mf_core_status > "$d/o"; grep -q "requirement: not met" "$d/o"; grep -q "snapshot for this boot: none" "$d/o"
        grep -q "QEMU processes: none" "$d/o"; [[ ! -e $d/state ]]
        mf_core_apply >/dev/null 2>&1; STUB_PGREP_RC=0; mf_core_status > "$d/o"
        grep -q "requirement: met" "$d/o"; grep -q "snapshot for this boot: present" "$d/o"; grep -q "running or unknown" "$d/o"'
check 'core-policy: dispatch accepts only apply, restore and status' \
    mf_st "$mf_st_core"'mf_core_cmd status >/dev/null; rc=0; mf_core_cmd bogus || rc=$?; [[ $rc == 64 ]]; rc=0; mf_core_cmd || rc=$?; [[ $rc == 64 ]]'

check 'guard: applies, runs the command with the policy active, then restores and returns its status' \
    mf_st "$mf_st_core"'cmd() { getcore > "$d/during"; return 4; }
        run mf_core_guarded cmd; [[ $rc == 4 && $(< "$d/during") == "/dev/null|0" && $(getcore) == "$PIPE|2" ]]
        [[ $(grep -c "" "$d/sysctl.log") == 2 ]]; grep -q "^sysctl -w" "$d/sysctl.log"; tail -1 "$d/sysctl.log" | grep -qF "sysctl -w kernel.core_pattern=|"'
check 'guard: never restores a policy it did not apply' \
    mf_st "$mf_st_core"'setcore /dev/null 0; cmd() { exit 5; }
        run mf_core_guarded cmd; [[ $rc == 5 && $(getcore) == "/dev/null|0" && ! -e $d/sysctl.log ]]
        setcore core 0; run mf_core_guarded cmd; [[ $rc == 5 && ! -e $d/sysctl.log ]]'
check 'guard: a policy applied earlier by hand is not restored by a later guarded run' \
    mf_st "$mf_st_core"'mf_core_apply >/dev/null 2>&1; MF_CORE_OURS=0; : > "$d/sysctl.log"; cmd() { :; }
        run mf_core_guarded cmd; [[ $rc == 0 && $(getcore) == "/dev/null|0" && ! -s $d/sysctl.log ]]'
check 'guard: an abnormal exit, TERM or HUP still restores what it applied' \
    mf_st "$mf_st_core"'for body in "exit 5" "kill -TERM \$BASHPID" "kill -HUP \$BASHPID"; do
            setcore "$PIPE" 2; rm -rf "$d/state" "$d/sysctl.log"
            eval "cmd() { $body; }"; run mf_core_guarded cmd
            [[ $rc != 0 && $(getcore) == "$PIPE|2" ]]; grep -qF "sysctl -w kernel.core_pattern=|" "$d/sysctl.log"
        done'
check 'guard: TERM exits 143 and INT lets the command finish' \
    mf_st "$mf_st_core"'cmd() { kill -TERM $BASHPID; }; run mf_core_guarded cmd; [[ $rc == 143 ]]
        setcore "$PIPE" 2; rm -rf "$d/state"
        cmd() { kill -INT $BASHPID; : > "$d/after"; return 6; }; run mf_core_guarded cmd
        [[ $rc == 6 && -e $d/after && $(getcore) == "$PIPE|2" ]]'
check 'guard: leaves the policy in place and says so while a QEMU process still runs' \
    mf_st "$mf_st_core"'STUB_PGREP_RC=0; cmd() { :; }; run mf_core_guarded cmd
        [[ $rc == 0 && $(getcore) == "/dev/null|0" ]]; grep -q "left in place" "$d/out"; grep -q "mayfly core-policy restore" "$d/out"
        grep -q "^sysctl -w" "$d/sysctl.log"; neg grep -qF "core_pattern=|" "$d/sysctl.log"'
check 'guard: a half-applied policy is undone and the command never runs' \
    mf_st "$mf_st_core"'(( EUID == 0 )) && exit 0
        export STUB_SYSCTL_FAIL=partial; cmd() { : > "$d/ran"; }
        run mf_core_guarded cmd; [[ $rc != 0 && ! -e $d/ran && $(getcore) == "$PIPE|2" ]]'
check 'guard: without sudo the command never runs and nothing changes' \
    mf_st "$mf_st_core"'(( EUID == 0 )) && exit 0
        unset -f sudo; PATH=$d/nopath; cmd() { : > "$d/ran"; }
        set +e; ( mf_core_guarded cmd ) > "$d/out" 2>&1; rc=$?; set -e
        [[ $rc != 0 && ! -e $d/ran && $(getcore) == "$PIPE|2" && ! -e $d/sysctl.log ]]'
check 'guard: the guarded command keeps errexit (no silent continue after a failure)' \
    mf_st "$mf_st_core"'cmd() { set -e; false; : > "$d/reached"; }
        run mf_core_guarded cmd; [[ $rc != 0 && ! -e $d/reached && $(getcore) == "$PIPE|2" ]]'
check 'guard: errexit state is restored for the caller' \
    mf_st "$mf_st_core"'cmd() { :; }; mf_core_guarded cmd >/dev/null 2>&1; [[ $- == *e* ]]; trap -p EXIT > "$d/traps"; [[ ! -s $d/traps ]]'

# ---- setup ------------------------------------------------------------------
mf_st_setup="$mf_st_core"'
    setcore core 0
    calls=$d/calls; : > "$calls"
    mf_preflight() { echo preflight >> "$calls"; echo "preflight ok"; }
    mf_profile_check() { echo "check-profile core=$(< "$MF_PROC_SYS/kernel/core_pattern")" >> "$calls"; echo "Profile syntax accepted."; }
    mf_fetch_pins() { echo "fetch-pins $*" >> "$calls"; printf "x\n" > "${@: -1}"; }
    mf_build() { echo "build $1 $2" >> "$calls"; mkdir -m 700 "$2"; : > "$2/gateway.qcow2"; : > "$2/browser.qcow2"; : > "$2/browser.sha256"; }
    put_profile() { mf_state_init create >/dev/null; printf "SECRETMARK\n" > "$d/state/secrets/wireguard.conf"; chmod 600 "$d/state/secrets/wireguard.conf"; }
    base=base-$(date +%Y%m%d)
'
check 'setup: without a profile it explains where to put it, exits 0 and does nothing else' \
    mf_st "$mf_st_setup"'run mf_setup; [[ $rc == 0 && $(< "$calls") == preflight ]]
        grep -q "$d/state/secrets/wireguard.conf" "$d/out"; grep -q "0600" "$d/out"; grep -q "mayfly setup\" again" "$d/out"
        [[ $(stat -c %a "$d/state/secrets") == 700 ]]'
check 'setup: it never prints the profile' \
    mf_st "$mf_st_setup"'put_profile; run mf_setup; [[ $rc == 0 ]]; neg grep -q SECRETMARK "$d/out"'
check 'setup: first run does preflight, profile check, pins, base in that order and ends with the next step' \
    mf_st "$mf_st_setup"'put_profile; run mf_setup; [[ $rc == 0 ]]
        [[ $(< "$calls") == "preflight
check-profile core=core
fetch-pins $d/state/pins/build.pins
build $d/state/pins/build.pins $d/state/bases/$base" ]]
        grep -q "Next: mayfly launch" "$d/out"'
check 'setup: a second run skips every finished step' \
    mf_st "$mf_st_setup"'put_profile; run mf_setup; : > "$calls"; run mf_setup; [[ $rc == 0 && $(< "$calls") == preflight ]]
        [[ $(grep -c "already done" "$d/out") -ge 4 ]]; grep -q "Next: mayfly launch" "$d/out"'
check 'setup: existing pins skip the download but a missing base is still built' \
    mf_st "$mf_st_setup"'put_profile; printf "x\n" > "$d/state/pins/build.pins"; run mf_setup
        [[ $(< "$calls") == "preflight
check-profile core=core
build $d/state/pins/build.pins $d/state/bases/$base" ]]'
check 'setup: an unmet core-dump policy stops before any download and names both remedies' \
    mf_st "$mf_st_setup"'setcore "$PIPE" 2; put_profile; run mf_setup
        [[ $rc == 78 && $(< "$calls") == preflight && ! -e $d/sysctl.log ]]; grep -q -- "--core-policy" "$d/out"; grep -q "mayfly core-policy apply" "$d/out"'
check 'setup: --core-policy applies for the profile check only and then restores' \
    mf_st "$mf_st_setup"'setcore "$PIPE" 2; put_profile; run mf_setup --core-policy; [[ $rc == 0 ]]
        grep -q "^check-profile core=/dev/null\$" "$calls"; grep -q "^fetch-pins" "$calls"; [[ $(getcore) == "$PIPE|2" ]]'
check 'setup: failed preflight stops before touching the state directory' \
    mf_st "$mf_st_setup"'mf_preflight() { echo preflight >> "$calls"; return 78; }; run mf_setup
        [[ $rc == 78 && $(< "$calls") == preflight && ! -e $d/state ]]'
check 'setup: --yes reaches fetch-pins and unknown options are refused' \
    mf_st "$mf_st_setup"'put_profile; run mf_setup --yes; grep -q "^fetch-pins --yes $d/state/pins/build.pins\$" "$calls"
        run mf_setup --bogus; [[ $rc == 64 ]]'
check 'setup: a failed download stops before the build' \
    mf_st "$mf_st_setup"'put_profile; mf_fetch_pins() { echo fetch >> "$calls"; return 1; }; run mf_setup
        [[ $rc != 0 ]]; neg grep -q "^build" "$calls"'

# ---- CLI defaults -----------------------------------------------------------
mf_st_cmds="$mf_st_core"'
    mf_launch() { printf "launch %s\n" "$*" > "$d/launch.log"; getcore > "$d/during"; }
    mf_build() { printf "build %s\n" "$*" > "$d/build.log"; }
    mf_profile_check() { printf "check %s\n" "$*" > "$d/check.log"; getcore > "$d/during"; }
    setcore core 0
'"$mf_st_bases"'
    put_profile() { printf "x\n" > "$d/state/secrets/wireguard.conf"; chmod 600 "$d/state/secrets/wireguard.conf"; }
    S=$d/state
'
check 'launch: no argument uses the newest base, the default profile and /dev/shm' \
    mf_st "$mf_st_cmds"'mk base-old 2023-01-01; mk base-new 2024-01-01; put_profile
        run mf_cmd_launch; [[ $rc == 0 && $(< "$d/launch.log") == "launch $S/bases/base-new $S/secrets/wireguard.conf /dev/shm $root" ]]
        grep -q "do not hibernate" "$d/out"'
check 'launch: a NAME selects that base; an absolute base path keeps the default profile' \
    mf_st "$mf_st_cmds"'mk base-old 2023-01-01; mk base-new 2024-01-01; put_profile
        run mf_cmd_launch base-old; [[ $(< "$d/launch.log") == "launch $S/bases/base-old $S/secrets/wireguard.conf /dev/shm $root" ]]
        run mf_cmd_launch /abs/base; [[ $(< "$d/launch.log") == "launch /abs/base $S/secrets/wireguard.conf /dev/shm $root" ]]'
check 'launch: the absolute long form is passed through unchanged (wrapper contract)' \
    mf_st "$mf_st_cmds"'run mf_cmd_launch /b /p; [[ $(< "$d/launch.log") == "launch /b /p /dev/shm $root" ]]
        run mf_cmd_launch /b /p /ram; [[ $(< "$d/launch.log") == "launch /b /p /ram $root" ]]
'
check 'launch: bad words are refused with status 64 and launch is never called' \
    mf_st "$mf_st_cmds"'mk b 2024-01-01; put_profile
        for a in "../x" "a/b" "-netdev" "has space" ".hidden" "/b relative" "relative /p" "/b /p /ram /extra"; do
            rm -f "$d/launch.log"; run mf_cmd_launch $a; [[ $rc == 64 && ! -e $d/launch.log ]]; done'
check 'launch: no state, no base or no profile gives status 66 or a clear failure, and creates nothing' \
    mf_st "$mf_st_cmds"'rm -rf "$d/state"; run mf_cmd_launch; [[ $rc != 0 && ! -e $d/state && ! -e $d/launch.log ]]; grep -q "mayfly setup" "$d/out"
        mf_state_init create >/dev/null; put_profile; run mf_cmd_launch; [[ $rc == 66 && ! -e $d/launch.log ]]; grep -q "mayfly setup" "$d/out"
        mk b 2024-01-01; rm "$d/state/secrets/wireguard.conf"; run mf_cmd_launch; [[ $rc == 66 && ! -e $d/launch.log ]]; grep -q "$S/secrets/wireguard.conf" "$d/out"'
check 'launch: --core-policy runs the launcher with the policy applied, then restores it' \
    mf_st "$mf_st_cmds"'setcore "$PIPE" 2; mk b 2024-01-01; put_profile
        run mf_cmd_launch --core-policy; [[ $rc == 0 && $(< "$d/during") == "/dev/null|0" && $(getcore) == "$PIPE|2" ]]
        grep -q "launch $S/bases/b " "$d/launch.log"'
check 'launch: without the flag it never touches the core-dump policy' \
    mf_st "$mf_st_cmds"'setcore "$PIPE" 2; mk b 2024-01-01; put_profile; run mf_cmd_launch; [[ ! -e $d/sysctl.log && $(getcore) == "$PIPE|2" ]]'
check 'build: defaults to the state pins and a dated base name' \
    mf_st "$mf_st_cmds"'printf x > "$S/pins/build.pins"; run mf_cmd_build; [[ $rc == 0 && $(< "$d/build.log") == "build $S/pins/build.pins $S/bases/base-$(date +%Y%m%d) $project $root" ]]'
check 'build: NAME, PINS and PINS NAME resolve inside the state directory' \
    mf_st "$mf_st_cmds"'printf x > "$S/pins/build.pins"; : > "$d/x.pins"
        run mf_cmd_build mine; [[ $(< "$d/build.log") == "build $S/pins/build.pins $S/bases/mine $project $root" ]]
        run mf_cmd_build "$d/x.pins"; [[ $(< "$d/build.log") == "build $d/x.pins $S/bases/base-$(date +%Y%m%d) $project $root" ]]
        run mf_cmd_build "$d/x.pins" mine; [[ $(< "$d/build.log") == "build $d/x.pins $S/bases/mine $project $root" ]]'
check 'build: the absolute long form is unchanged' \
    mf_st "$mf_st_cmds"'printf x > "$S/pins/build.pins"; run mf_cmd_build "$S/pins/build.pins" /abs/new-base
        [[ $(< "$d/build.log") == "build $S/pins/build.pins /abs/new-base $project $root" ]]'
check 'build: refuses to overwrite an existing base, a missing pins file and bad words' \
    mf_st "$mf_st_cmds"'printf x > "$S/pins/build.pins"; mk "base-$(date +%Y%m%d)" 2024-01-01
        run mf_cmd_build; [[ $rc == 73 && ! -e $d/build.log ]]; grep -q "never overwrite" "$d/out"
        run mf_cmd_build mine2; [[ $rc == 0 ]]; rm -f "$S/pins/build.pins"; rm -f "$d/build.log"; run mf_cmd_build mine3; [[ $rc == 66 && ! -e $d/build.log ]]
        printf x > "$S/pins/build.pins"; for a in "--unsafe" "../x" "a b" "/p a b" "/a /b /c"; do run mf_cmd_build $a; [[ $rc == 64 && ! -e $d/build.log ]]; rm -f "$d/build.log"; done'
check 'check-profile: default path, explicit absolute path, relative path refused, flag applies policy' \
    mf_st "$mf_st_cmds"'put_profile; run mf_cmd_check_profile; [[ $(< "$d/check.log") == "check $S/secrets/wireguard.conf" ]]
        run mf_cmd_check_profile /x/p.conf; [[ $(< "$d/check.log") == "check /x/p.conf" ]]
        run mf_cmd_check_profile rel.conf; [[ $rc == 64 ]]; run mf_cmd_check_profile --bogus; [[ $rc == 64 ]]
        setcore "$PIPE" 2; run mf_cmd_check_profile --core-policy; [[ $(< "$d/during") == "/dev/null|0" && $(getcore) == "$PIPE|2" ]]
        rm "$S/secrets/wireguard.conf"; run mf_cmd_check_profile; [[ $rc == 66 ]]'
check 'cli: mayfly.sh refuses cleanly with no state and does not create it' \
    mf_st 'run bash "$project/mayfly.sh" launch; [[ $rc != 0 && ! -e $d/state ]]; grep -q "mayfly setup" "$d/out"
        run bash "$project/mayfly.sh" check-profile; [[ $rc != 0 && ! -e $d/state ]]'
check 'cli: mayfly.sh rejects bad subcommand words with status 64' \
    mf_st 'for a in "core-policy" "core-policy bogus" "core-policy apply now" "setup --bogus" "launch -netdev user" "build --unsafe" "bogus"; do
            run bash "$project/mayfly.sh" $a; [[ $rc == 64 ]]; done'
check 'cli: help names the new commands and states the Debian trust limit' \
    mf_st 'run bash "$project/mayfly.sh"; [[ $rc == 64 ]]
        for w in "setup" "fetch-pins" "core-policy apply|restore|status" "--core-policy" "no detached signature" "mayfly.sh launch [--attach FILE] [--core-policy] BASE-DIRECTORY PROFILE-FILE"; do grep -qF -- "$w" "$d/out"; done'
check 'cli: core-policy status runs read-only against the real host' \
    mf_st 'run bash "$project/mayfly.sh" core-policy status; [[ $rc == 0 ]]; grep -q "^requirement:" "$d/out"; [[ ! -e $d/state ]]'

# ---- dedicated-user wrapper and installer -----------------------------------
mf_wst='
    d=$(mktemp -d "${TMPDIR:-/tmp}/pbst.XXXXXXXX"); trap "rm -rf -- $d" EXIT
'
check 'wrapper: usage lists setup, fetch-pins, core-policy and optional names' \
    mf_sub 'out=$(mf_usage); for w in "sudo mayfly setup" "fetch-pins" "core-policy apply|restore|status" "--core-policy" "[BASE-NAME]" "build [NEW-BASE-NAME]"; do [[ $out == *"$w"* ]] || exit 1; done'
check 'wrapper: launch parsing takes --core-policy and an optional name' \
    mf_sub 'mf_parse_launch --core-policy test-09 && [[ $MF_ARG_CORE == 1 && $MF_ARG_NAME == test-09 ]]
        mf_parse_launch && [[ $MF_ARG_CORE == 0 && -z $MF_ARG_NAME ]]
        mf_parse_launch --diag --core-policy --display wayland-1 && [[ $MF_ARG_CORE == 1 && $MF_ARG_DIAG == 1 ]]
        neg mf_parse_launch ../x; neg mf_parse_launch --core-policy a b; neg mf_parse_launch --core'
check 'wrapper: fetch-pins parsing passes only validated words' \
    mf_sub 'mf_parse_fetch_pins --yes --debian 20260101-77 --tor 15.0.9 && [[ ${MF_FP_ARGS[*]} == "--yes --debian 20260101-77 --tor 15.0.9" ]]
        mf_parse_fetch_pins && [[ ${#MF_FP_ARGS[@]} == 0 ]]
        for a in "--debian ../x" "--debian latest" "--tor 15.0a3" "--tor 1.2;id" "--tor" "--debian" "/etc/passwd" "--output x" "--yes extra"; do
            neg mf_parse_fetch_pins $a; done'
check 'wrapper: the newest base is chosen by build time and only complete service-user bases count' \
    mf_sub 'd=$(mktemp -d "${TMPDIR:-/tmp}/pbst.XXXXXXXX"); trap "rm -rf -- $d" EXIT
        MF_STATE=$d; id() { command id -u; }
        mk() { mkdir -m 700 -p "$d/bases/$1"; : > "$d/bases/$1/gateway.qcow2"; : > "$d/bases/$1/browser.qcow2"; : > "$d/bases/$1/browser.sha256"; touch -d "$2" "$d/bases/$1/browser.sha256"; }
        neg mf_newest_base; mkdir -p "$d/bases"; neg mf_newest_base
        mk zzz 2023-01-01; mk aaa 2024-01-01; mkdir -m 700 "$d/bases/partial"; : > "$d/bases/partial/gateway.qcow2"; mk "bad name" 2030-01-01
        mk foreign 2032-01-01; stat() { if [[ ${*: -1} == */bases/foreign ]]; then printf "4242\n"; else command stat "$@"; fi; }
        [[ $(mf_newest_base) == aaa ]]'
mf_wst_cmds='
    d=$(mktemp -d "${TMPDIR:-/tmp}/pbst.XXXXXXXX"); trap "rm -rf -- $d" EXIT
    MF_STATE=$d; id() { command id -u; }; mf_check_install() { :; }
    mf_run_as() { printf "%s\n" "$*" >> "$d/ra"; if [[ $* == *fetch-pins* ]]; then mkdir -p "$d/pins"; : > "$d/pins/build.pins"; fi; }
    mk() { mkdir -m 700 -p "$d/bases/$1"; : > "$d/bases/$1/gateway.qcow2"; : > "$d/bases/$1/browser.qcow2"; }
    day=$(date +%Y%m%d)
'
check 'wrapper: fetch-pins runs as the service user with a fixed state home and no caller paths' \
    mf_sub "$mf_wst_cmds"'mf_cmd_fetch_pins --yes --tor 15.0.1
        [[ $(< "$d/ra") == "MAYFLY_HOME=$MF_STATE bash /usr/local/lib/mayfly/mayfly.sh fetch-pins --yes --tor 15.0.1" ]]
        rc=0; ( mf_cmd_fetch_pins /etc/shadow ) >/dev/null 2>&1 || rc=$?; [[ $rc == 64 ]]'
check 'wrapper: build without a name creates base-YYYYMMDD from the installed pins and never overwrites' \
    mf_sub "$mf_wst_cmds"'mkdir -p "$d/pins"; : > "$d/pins/build.pins"
        mf_cmd_build ""; [[ $(< "$d/ra") == "LIBGUESTFS_BACKEND=direct bash /usr/local/lib/mayfly/mayfly.sh build $d/pins/build.pins $d/bases/base-$day" ]]
        mk "base-$day"; rc=0; ( mf_cmd_build "" ) >/dev/null 2>&1 || rc=$?; [[ $rc != 0 ]]
        rc=0; ( mf_cmd_build "../x" ) >/dev/null 2>&1 || rc=$?; [[ $rc == 64 ]]'
check 'wrapper: setup fetches pins and builds only what is missing' \
    mf_sub "$mf_wst_cmds"'mkdir -p "$d/secrets"; : > "$d/secrets/wireguard.conf"
        mf_cmd_setup --yes >/dev/null
        [[ $(sed -n 1p "$d/ra") == "MAYFLY_HOME=$MF_STATE bash /usr/local/lib/mayfly/mayfly.sh fetch-pins --yes" ]]
        [[ $(sed -n 2p "$d/ra") == "LIBGUESTFS_BACKEND=direct bash /usr/local/lib/mayfly/mayfly.sh build $d/pins/build.pins $d/bases/base-$day" ]]
        rm "$d/ra"; mkdir -p "$d/pins"; : > "$d/pins/build.pins"; mk have
        out=$(mf_cmd_setup); [[ ! -e $d/ra && $out == *"already done: pins file exists"* && $out == *"already done: base have"* ]]
        rc=0; ( mf_cmd_setup --bogus ) >/dev/null 2>&1 || rc=$?; [[ $rc == 64 ]]
        rm "$d/secrets/wireguard.conf"; rc=0; ( mf_cmd_setup ) >/dev/null 2>&1 || rc=$?; [[ $rc != 0 ]]'
mf_wst_launch="$mf_st_core"'
    MF_STATE=$d/st; mkdir -p "$MF_STATE/bases/test-09" "$MF_STATE/secrets"; : > "$MF_STATE/bases/test-09/gateway.qcow2"; : > "$MF_STATE/bases/test-09/browser.qcow2"
    : > "$MF_STATE/secrets/wireguard.conf"
    id() { printf "%s\n" 1234; }
    mf_check_install() { :; }; mf_caller_uid() { printf "%s\n" 1000; }; mf_wayland_name() { printf "%s\n" wayland-0; }
    stat() {
        local fmt=$2 path=${*: -1}
        case $path in
            */bases/test-09) if [[ $fmt == %u ]]; then printf "%s\n" 1234; else printf "%s\n" 1234:700; fi ;;
            */secrets/wireguard.conf) printf "%s\n" 1234:600 ;;
            /run/user/1000/wayland-0) printf "%s\n" 1000 ;;
            *) command stat "$@" ;;
        esac
    }
    mf_load_core_policy() { for f in policy host corepolicy; do source "$project/lib/$f.sh"; done; MF_CORE_STATE=$d/cs; mkdir -p -m 700 "$MF_CORE_STATE"; mf_core_stat_info() { printf "0 755\n"; }; }
    mf_launch_ns() { getcore > "$d/during"; printf "ns %s\n" "$*" > "$d/ns.log"; }
    mf_run_as() { getcore > "$d/during"; printf "ra %s\n" "$*" > "$d/ra.log"; }
'
check 'wrapper: launch --core-policy does not exec; it applies, runs the namespace launcher, restores' \
    mf_sub 'project='"$project"'; d=$(mktemp -d "${TMPDIR:-/tmp}/pbst.XXXXXXXX"); trap "rm -rf -- $d" EXIT; export MAYFLY_HOME=$d/state; '"$mf_wst_launch"'
        mf_cmd_launch --core-policy --display wayland-0 test-09 >/dev/null 2>&1
        [[ $(< "$d/ns.log") == "ns 1000 wayland-0 0 test-09" && $(< "$d/during") == "/dev/null|0" && $(getcore) == "$PIPE|2" ]]
        [[ -f $d/cs/core-policy/$BOOT/original.conf ]]
        : > "$d/sysctl.log"; mf_cmd_launch --core-policy >/dev/null 2>&1; [[ $(< "$d/ns.log") == "ns 1000 wayland-0 0 test-09" ]]'
check 'wrapper: launch without a name uses the newest base, and without the flag still execs' \
    mf_sub 'project='"$project"'; d=$(mktemp -d "${TMPDIR:-/tmp}/pbst.XXXXXXXX"); trap "rm -rf -- $d" EXIT; export MAYFLY_HOME=$d/state; '"$mf_wst_launch"'
        exec() { printf "exec %s\n" "$*" > "$d/exec.log"; }
        mf_cmd_launch --display wayland-0
        [[ $(< "$d/exec.log") == "exec env MF_IN_NS=1 unshare --mount --propagation private -- /usr/local/sbin/mayfly __ns-launch 1000 wayland-0 0 test-09" ]]
        [[ ! -e $d/sysctl.log ]]'
check 'wrapper: check-profile --core-policy applies for the check as the service user, then restores' \
    mf_sub 'project='"$project"'; d=$(mktemp -d "${TMPDIR:-/tmp}/pbst.XXXXXXXX"); trap "rm -rf -- $d" EXIT; export MAYFLY_HOME=$d/state; '"$mf_wst_launch"'
        mf_cmd_check_profile --core-policy >/dev/null 2>&1
        [[ $(< "$d/during") == "/dev/null|0" && $(getcore) == "$PIPE|2" && $(< "$d/ra.log") == "ra bash /usr/local/lib/mayfly/mayfly.sh check-profile $MF_STATE/secrets/wireguard.conf" ]]
        rc=0; ( mf_cmd_check_profile --bogus ) >/dev/null 2>&1 || rc=$?; [[ $rc == 64 ]]'
check 'wrapper: core-policy subcommand loads the verified helpers only after the integrity check' \
    bash -c 'f=$1; a=$(grep -n "mf_check_install" "$f" | grep -A0 "" | head -0); 
        awk "/^mf_cmd_core_policy\\(\\)/,/^}/" "$f" | grep -n "mf_check_install\|mf_load_core_policy" | head -2 | tr "\n" " " | grep -q "1:.*mf_check_install.*2:.*mf_load_core_policy"
        awk "/^mf_cmd_launch\\(\\)/,/^}/" "$f" | grep -n "mf_check_install\|mf_load_core_policy" | head -2 | tr "\n" " " | grep -q "mf_check_install.*mf_load_core_policy"
        grep -q "source \"\$MF_PROG/lib/corepolicy.sh\"" "$f" && grep -qF "core-policy)" "$f" && grep -qF "fetch-pins)" "$f" && grep -qF "setup)" "$f"' _ "$mf_wrapper"
check 'wrapper: every existing safety property is still present after the changes' \
    bash -c 'f=$1; grep -Fq "env -i LC_ALL=C PATH=/usr/bin:/bin" "$f" && grep -Fq "unshare --mount --propagation private" "$f" &&
        grep -Fq "setfacl -m \"u:\$MF_USER:rw\" -- \"\$MF_NS_TARGET\"" "$f" && grep -Fq "sha256sum --check --quiet --strict MANIFEST.sha256" "$f" &&
        grep -Fq "trap mf_ns_revoke EXIT" "$f" && grep -Fq "! -L /run/user/\$uid/\$wl" "$f"' _ "$mf_wrapper"

mf_ist='
    d=$(mktemp -d "${TMPDIR:-/tmp}/pbsi.XXXXXXXX"); trap "rm -rf -- $d" EXIT
    thome=$d/thome; mkdir -p "$thome/.local/state/mayfly/secrets" "$thome/.local/state/mayfly/pins"
    getent() { if [[ $1 == passwd && ${2:-} == tester ]]; then printf "tester:x:1000:1000::%s:/bin/bash\n" "$thome"; else command getent "$@"; fi; }
    export SUDO_USER=tester SUDO_UID=1000 MF_REPLACE=0
    MF_STATE=$d/var
    prof=$thome/.local/state/mayfly/secrets/wireguard.conf; pinf=$thome/.local/state/mayfly/pins/build.pins
'
check 'installer: default files in the invoking user state directory are found, plain files only' \
    mf_sub_installer "$mf_ist"'neg mf_default_user_file secrets/wireguard.conf "$MF_STATE/secrets/wireguard.conf" profile 2>/dev/null
        printf x > "$prof"; [[ $(mf_default_user_file secrets/wireguard.conf "$MF_STATE/secrets/wireguard.conf" profile 2>/dev/null) == "$prof" ]]
        rm "$prof"; printf x > "$d/other"; ln -s "$d/other" "$prof"; neg mf_default_user_file secrets/wireguard.conf "$MF_STATE/secrets/wireguard.conf" profile 2>/dev/null
        (unset SUDO_USER; printf x > "$pinf"; neg mf_default_user_file pins/build.pins "$MF_STATE/pins/build.pins" pins 2>/dev/null)
        (SUDO_UID=abc; neg mf_default_user_file pins/build.pins "$MF_STATE/pins/build.pins" pins 2>/dev/null)
        (SUDO_UID=0; neg mf_default_user_file pins/build.pins "$MF_STATE/pins/build.pins" pins 2>/dev/null)'
check 'installer: an already installed destination is kept unless --replace is given' \
    mf_sub_installer "$mf_ist"'printf x > "$pinf"; mkdir -p "$MF_STATE/pins"; : > "$MF_STATE/pins/build.pins"
        neg mf_default_user_file pins/build.pins "$MF_STATE/pins/build.pins" pins 2>/dev/null
        MF_REPLACE=1; [[ $(mf_default_user_file pins/build.pins "$MF_STATE/pins/build.pins" pins 2>/dev/null) == "$pinf" ]]'
check 'installer: dry run uses the default profile and pins when the options are omitted' \
    mf_sub_installer "$mf_ist"'printf x > "$prof"; printf x > "$pinf"
        out=$(mf_install_main --dry-run --allow-dirty 2>&1)
        [[ $out == *"+ copy $prof -> $MF_STATE/secrets/wireguard.conf as mayfly (mode 0600)"* ]]
        [[ $out == *"+ copy $pinf -> $MF_STATE/pins/build.pins as mayfly (mode 0600)"* ]]
        [[ $out == *"sudo mayfly setup"* && $out == *"sudo mayfly launch --core-policy"* ]]'
check 'installer: dry run with no defaults and no options installs neither file' \
    mf_sub_installer "$mf_ist"'out=$(mf_install_main --dry-run --allow-dirty 2>&1); [[ $out != *"wireguard.conf"* && $out != *"build.pins"* ]]'
check 'installer: an explicit --profile wins over the default' \
    mf_sub_installer "$mf_ist"'printf x > "$prof"; printf x > "$d/mine.conf"
        out=$(mf_install_main --dry-run --allow-dirty --profile "$d/mine.conf" 2>&1)
        [[ $out == *"+ copy $d/mine.conf -> "* && $out != *"+ copy $prof"* ]]'

# ---- DEPLOYMENT.md manual restore block, executed as written ---------------
MF_DOCS_BLOCK=$(awk '/^\*\*Restore\*\*/ {f = 1} f && /^```bash/ {g = 1; next} g && /^```/ {exit} g {print}' "$project/DEPLOYMENT.md")
export MF_DOCS_BLOCK
mf_st_docs='
    [[ -n $MF_DOCS_BLOCK ]]
    export MF_STATE=$d/mstate; boot=$(cat /proc/sys/kernel/random/boot_id)
    mkdir -p -m 700 "$MF_STATE/core-policy/$boot"; snapf=$MF_STATE/core-policy/$boot/original.conf
    sudo() { printf "sudo %s\n" "$1" >> "$d/sudo.log"; "$@"; }
    sysctl() { printf "sysctl %s\n" "$*" >> "$d/sysctl.log"; }
    pgrep() { return "${STUB_PGREP_RC:-1}"; }
    blk() { # pattern suid [answer]
        printf "kernel.core_pattern=%s\nfs.suid_dumpable=%s\n" "$1" "$2" > "$snapf"; chmod 600 "$snapf"; rm -f "$d/sudo.log" "$d/sysctl.log"
        set +e; ( eval "$MF_DOCS_BLOCK" ) <<< "${3-RESTORE}" > "$d/out" 2>&1; rc=$?; set -e
    }
    refused() { blk "$@"; [[ $rc != 0 && ! -e $d/sudo.log && ! -e $d/sysctl.log ]] || { echo "applied: $1 $2" >&2; exit 1; }; neg grep -q "$(printf "\033")" "$d/out"; }
'
check 'docs: the manual restore block never applies a pipe, control characters or a bad pairing' \
    mf_st "$mf_st_docs"'refused "|/usr/lib/systemd/systemd-coredump %P %u %g" 0; refused "|/usr/lib/systemd/systemd-coredump %P" 2
        refused "|/usr/bin/env /home/u/evil.sh" 0; refused "$(printf "|/x\033[2J\033[1;1Hcore")" 0; refused "$(printf "core\rx")" 0
        refused "$(printf "core\tx")" 0; refused "$(printf "co\033re")" 0; refused "$(printf "|/x\r")" 2
        refused /etc/cron.d/zz 0; refused /var/crash/core.%p 0; refused core 2; refused core 1; refused /dev/null 2
        refused ../core 0; refused .hidden 0; refused a/b 0; refused "core file" 0; refused core 0 NO; refused core 0 ""
        STUB_PGREP_RC=0; refused core 0'
check 'docs: the manual restore block applies a plain relative name or /dev/null with suid 0, through sysctl -w from variables' \
    mf_st "$mf_st_docs"'blk core 0; [[ $rc == 0 ]]; grep -qF "sysctl -w kernel.core_pattern=core fs.suid_dumpable=0" "$d/sysctl.log"
        blk /dev/null 0; [[ $rc == 0 ]]; grep -qF "sysctl -w kernel.core_pattern=/dev/null fs.suid_dumpable=0" "$d/sysctl.log"
        neg grep -q "sysctl -p" "$d/sysctl.log"'

