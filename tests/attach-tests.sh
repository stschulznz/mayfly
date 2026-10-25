# Offline checks for launch --attach (one-way text transfer to the browser VM).
# Sourced by run.sh after setup-tests.sh. The ISO tool, QEMU and sudo never
# run: tool and mount commands are shell functions in each test.

mf_att='
    src=$d/src; mkdir -p "$src"; good=$src/post.txt
    printf "Hello POSTMARK text\n" > "$good"
    mf_iso_tool() { printf "%s\n" "${STUB_TOOL:-genisoimage}"; }
    mkiso() {
        local out="" prev="" a
        for a in "$@"; do [[ $prev == -output ]] && out=$a; prev=$a; done
        [[ -z ${STUB_ISO_FAIL:-} ]] || return 1
        printf "ISO\n" > "$out"
    }
    genisoimage() { printf "genisoimage %s\n" "$*" >> "$d/iso.log"; mkiso "$@"; }
    xorriso() { printf "xorriso %s\n" "$*" >> "$d/iso.log"; mkiso "$@"; }
    refuse() { # path [uid]: refused, destination never created, content never printed
        rm -f "$d/o"; neg mf_attach_read "$1" "${2:-$UID}" "$d/o" 2> "$d/err" > "$d/stdout"
        [[ ! -e $d/o ]] || { echo "kept output: $1" >&2; exit 1; }
        neg grep -q POSTMARK "$d/err" "$d/stdout"
    }
'

# ---- guest file name --------------------------------------------------------
check 'attach: safe names are kept, everything else becomes transfer.txt' \
    mf_st "$mf_att"'for n in post.txt a.b-c_d notes.md A1 x; do [[ $(mf_attach_name "/h/u/$n") == "$n" ]] || exit 1; done
        [[ $(mf_attach_name post.txt) == post.txt && $(mf_attach_name /a/b/c/post.txt) == post.txt ]]
        long=$(printf "a%.0s" {1..64}); [[ $(mf_attach_name "$long") == "$long" ]]
        for n in "" . .. -x.txt .hidden --help "a b.txt" "a;b" "a\$(id)" "a\`id\`" "a|b" "a&b" "a*b" "a?b" "a:b" "a,b" "a=b" "$(printf "a%.0s" {1..65})" "caf$(printf "\xc3\xa9").txt" "$(printf "a\tb")" "$(printf "a\033[2Jb")"; do
            [[ $(mf_attach_name "/h/u/$n") == transfer.txt ]] || { echo "name kept: $n" >&2; exit 1; }
        done'

# ---- validation on the open descriptor ---------------------------------------
check 'attach: a good file is copied byte for byte into a 0600 file' \
    mf_st "$mf_att"'mf_attach_read "$good" "$UID" "$d/o"; [[ $(sha256sum < "$good") == "$(sha256sum < "$d/o")" ]]; [[ $(stat -c %a "$d/o") == 600 ]]
        printf "caf\xc3\xa9 text \xe2\x9c\x93 end" > "$src/u.txt"; mf_attach_read "$src/u.txt" "$UID" "$d/u"; [[ $(sha256sum < "$src/u.txt") == "$(sha256sum < "$d/u")" ]]
        printf "x" > "$src/one.txt"; mf_attach_read "$src/one.txt" "$UID" "$d/one"
        head -c 1048576 /dev/zero | tr "\0" a > "$src/max.txt"; mf_attach_read "$src/max.txt" "$UID" "$d/max"; [[ $(stat -c %s "$d/max") == 1048576 ]]'
check 'attach: symlink, directory, FIFO, missing file and relative path are refused' \
    mf_st "$mf_att"'ln -s "$good" "$src/link.txt"; ln -s "$src" "$d/dirlink"; mkdir "$src/dir"; mkfifo "$src/fifo"
        refuse "$src/link.txt"; refuse "$src/dir"; refuse "$src/fifo"; refuse "$src/missing.txt"; refuse post.txt; refuse ./post.txt; refuse ""
        ln -s /etc/hostname "$src/etc.txt"; refuse "$src/etc.txt"; refuse /dev/null; refuse /proc/self/mem; refuse /etc'
check 'attach: empty, oversized and NUL-containing files are refused' \
    mf_st "$mf_att"': > "$src/empty"; refuse "$src/empty"
        head -c 1048577 /dev/zero | tr "\0" a > "$src/big"; refuse "$src/big"
        head -c 5000000 /dev/zero | tr "\0" a > "$src/huge"; refuse "$src/huge"
        printf "POSTMARK\0tail" > "$src/nul1"; refuse "$src/nul1"; printf "\0POSTMARK" > "$src/nul2"; refuse "$src/nul2"
        printf "POSTMARK\0" > "$src/nul3"; refuse "$src/nul3"; printf "\0" > "$src/nul4"; refuse "$src/nul4"
        head -c 1048575 /dev/zero | tr "\0" a > "$src/nul5"; printf "\0" >> "$src/nul5"; refuse "$src/nul5"'
check 'attach: a file owned by someone else is refused, and uid 0 does not accept a user file' \
    mf_st "$mf_att"'stat() { if [[ $* == *"%u %s %f"* ]]; then command stat "$@" | sed "s/^$UID /$((UID + 1)) /"; else command stat "$@"; fi; }
        refuse "$good"; unset -f stat; refuse "$good" 0; refuse "$good" 65534'
check 'attach: a path swapped for another file after the open is refused (no second open of the path)' \
    mf_st "$mf_att"'stat() { if [[ $* == *"%u %s %f"* && ! -e $d/swapped ]]; then : > "$d/swapped"; rm -f "$good"; printf "OTHER\n" > "$good"; fi; command stat "$@"; }
        refuse "$good"; [[ -e $d/swapped ]]
        rm -f "$d/swapped" "$good"; printf "Hello POSTMARK text\n" > "$good"; ln -s "$good" "$src/l"
        stat() { if [[ $* == *"%u %s %f"* && ! -e $d/swapped ]]; then : > "$d/swapped"; rm -f "$src/l"; printf "OTHER\n" > "$src/l"; fi; command stat "$@"; }
        refuse "$src/l"'
check 'attach: a file that is not the size it claimed is refused and its copy removed' \
    mf_st "$mf_att"'stat() { if [[ $* == *"%u %s %f"* ]]; then command stat "$@" | sed "s/^\([0-9]*\) [0-9]* /\1 5 /"; else command stat "$@"; fi; }
        refuse "$good"
        stat() { if [[ $* == *"%u %s %f"* ]]; then command stat "$@" | sed "s/^\([0-9]*\) [0-9]* /\1 5000000 /"; else command stat "$@"; fi; }
        refuse "$good"'
check 'attach: validation errors never include the file contents or its path' \
    mf_st "$mf_att"'printf "POSTMARK\0" > "$src/secretname.txt"; neg mf_attach_read "$src/secretname.txt" "$UID" "$d/o" 2> "$d/err"
        neg grep -q "POSTMARK\|secretname" "$d/err"; grep -q "^BLOCKED: " "$d/err"'

# ---- ISO build ---------------------------------------------------------------
check 'attach: genisoimage and mkisofs get Rock Ridge, label transfer, quiet, one directory, no Joliet' \
    mf_st "$mf_att"'mkdir "$d/in"; for t in genisoimage mkisofs; do
            rm -f "$d/iso.log" "$d/x.iso"; STUB_TOOL=$t
            eval "$t() { printf \"%s %s\n\" $t \"\$*\" >> \"\$d/iso.log\"; mkiso \"\$@\"; }"
            mf_make_transfer_iso "$d/x.iso" "$d/in"
            [[ $(< "$d/iso.log") == "$t -quiet -output $d/x.iso -volid transfer -r $d/in" ]]; [[ $(stat -c %a "$d/x.iso") == 600 ]]
        done'
check 'attach: xorriso is run through its mkisofs emulation without reading user config' \
    mf_st "$mf_att"'mkdir "$d/in"; STUB_TOOL=xorriso; mf_make_transfer_iso "$d/x.iso" "$d/in"
        [[ $(< "$d/iso.log") == "xorriso -no_rc -as mkisofs -quiet -output $d/x.iso -volid transfer -r $d/in" ]]'
check 'attach: a failing or missing ISO tool is an error that leaves no image' \
    mf_st "$mf_att"'mkdir "$d/in"; STUB_ISO_FAIL=1; neg mf_make_transfer_iso "$d/x.iso" "$d/in" 2> "$d/err"; [[ ! -e $d/x.iso ]]; grep -q "could not build" "$d/err"
        unset STUB_ISO_FAIL; mf_iso_tool() { return 1; }; neg mf_make_transfer_iso "$d/x.iso" "$d/in" 2> "$d/err"; grep -q "ISO tool" "$d/err"; [[ ! -e $d/x.iso ]]
        mf_iso_tool() { printf "genisoimage\n"; }; genisoimage() { :; }; neg mf_make_transfer_iso "$d/x.iso" "$d/in" 2>/dev/null; [[ ! -e $d/x.iso ]]'
check 'attach: a real ISO tool, when installed, builds an image labelled transfer holding the one file' \
    mf_st "$mf_att"'unset -f mf_iso_tool genisoimage xorriso; source "$project/lib/runtime.sh"; tool=$(mf_iso_tool) || exit 0
        mkdir "$d/in"; printf "Hello POSTMARK\n" > "$d/in/post.txt"; mf_make_transfer_iso "$d/x.iso" "$d/in"
        [[ $(dd if="$d/x.iso" bs=1 skip=32808 count=8 2>/dev/null) == transfer ]]
        grep -aq "POSTMARK" "$d/x.iso"; grep -aq "post.txt" "$d/x.iso"; grep -aq "RRIP\|RRIP_1991A\|IEEE_P1282\|IEEE_1282" "$d/x.iso"'

# ---- session preparation -------------------------------------------------------
check 'attach: user mode copies the file into the session, names it safely and builds the ISO there' \
    mf_st "$mf_att"'run=$d/run; mkdir -m 700 "$run"; mf_attach_prepare user "$good" "$run"
        [[ $MF_ATTACH_ISO == "$run/transfer.iso" && -s $run/transfer.iso && $(stat -c %a "$run/transfer.iso") == 600 ]]
        [[ $(ls -A "$run/transfer") == post.txt && $(stat -c %a "$run/transfer/post.txt") == 600 ]]; [[ $(sha256sum < "$good") == "$(sha256sum < "$run/transfer/post.txt")" ]]
        [[ $(< "$d/iso.log") == "genisoimage -quiet -output $run/transfer.iso -volid transfer -r $run/transfer" ]]
        for n in -evil.txt .hidden "a b.txt" "a;b"; do
            rm -rf "$run/transfer" "$run/transfer.iso"; cp "$good" "$src/$n"; mf_attach_prepare user "$src/$n" "$run"
            [[ $(ls -A "$run/transfer") == transfer.txt ]] || { echo "name: $n" >&2; exit 1; }
        done'
check 'attach: a refused file or a failing tool leaves no ISO and no attach path' \
    mf_st "$mf_att"'run=$d/run; mkdir -m 700 "$run"; printf "a\0b" > "$src/nul.txt"; MF_ATTACH_ISO=stale
        neg mf_attach_prepare user "$src/nul.txt" "$run" 2>/dev/null; [[ -z $MF_ATTACH_ISO && ! -e $run/transfer.iso ]]
        rm -rf "$run/transfer"; STUB_ISO_FAIL=1; neg mf_attach_prepare user "$good" "$run" 2>/dev/null; [[ -z $MF_ATTACH_ISO && ! -e $run/transfer.iso ]]
        neg mf_attach_prepare other "$good" "$run" 2>/dev/null'
check 'attach: staged mode accepts only the exact wrapper path and reads it as root-owned' \
    mf_st "$mf_att"'run=$d/run; mkdir -m 700 "$run"
        mf_attach_read() { printf "read %s %s %s\n" "$@" > "$d/read.log"; printf x > "$3"; }
        mf_attach_prepare staged /run/mayfly/attach/post.txt "$run"
        [[ $(< "$d/read.log") == "read /run/mayfly/attach/post.txt 0 $run/transfer/post.txt" && $MF_ATTACH_ISO == "$run/transfer.iso" ]]
        for p in "$good" /tmp/post.txt /run/mayfly/attach/../x /run/mayfly/attach/.h /run/mayfly/attach/-x /run/mayfly/attach/a/b /run/mayfly/attachX/a \
            /run/mayfly/attach/ /run/mayfly/attach "/run/mayfly/attach/$(printf "a%.0s" {1..65})" "/run/mayfly/attach/a b" run/mayfly/attach/x \
            "$(printf "/run/mayfly/attach/a\nb")" /run/mayfly/attach/x/../../../tmp/y /run/mayfly/attach/a\$b /run/mayfly/attach/a\;b; do
            rm -rf "$run/transfer" "$run/transfer.iso" "$d/read.log"
            neg mf_attach_prepare staged "$p" "$run" 2>/dev/null; [[ ! -e $d/read.log && ! -e $run/transfer.iso ]] || { echo "accepted: $p" >&2; exit 1; }
        done'

# ---- QEMU arguments ---------------------------------------------------------------
check 'attach: the gateway arguments never change, and the browser gains exactly one read-only CD-ROM' \
    mf_st "$mf_att"'mf_qemu_args gateway /b /r; g0=("${MF_QEMU[@]}"); mf_qemu_args browser /b /r; b0=("${MF_QEMU[@]}")
        MF_ATTACH_ISO=/r/transfer.iso
        mf_qemu_args gateway /b /r; [[ ${#MF_QEMU[@]} == "${#g0[@]}" && "${MF_QEMU[*]}" == "${g0[*]}" ]]
        mf_qemu_args browser /b /r; b1=("${MF_QEMU[@]}")
        [[ ${#b1[@]} == $(( ${#b0[@]} + 2 )) ]]
        extra=(); i=0; j=0
        for ((i=0; i<${#b1[@]}; i++)); do
            if (( j < ${#b0[@]} )) && [[ ${b1[i]} == "${b0[j]}" ]]; then ((j += 1)); else extra+=("${b1[i]}"); fi
        done
        [[ $j == "${#b0[@]}" && ${#extra[@]} == 2 && ${extra[0]} == -drive && ${extra[1]} == "file=/r/transfer.iso,format=raw,media=cdrom,readonly=on" ]]
        [[ $(printf "%s\n" "${b1[@]}" | grep -c "^-drive\$") == 2 ]]
        unset MF_ATTACH_ISO; mf_qemu_args browser /b /r; [[ "${MF_QEMU[*]}" == "${b0[*]}" ]]
        MF_ATTACH_ISO=""; mf_qemu_args browser /b /r; [[ "${MF_QEMU[*]}" == "${b0[*]}" ]]'
check 'attach: the new drive argument parses with the narrow fake QEMU 8 drive parser, and a writable or disk form does not' \
    mf_st "$mf_att"'source <(sed -n "/^repair_qemu8_drive_parse() {/,/^}/p" "$project/tests/regression-tests.sh")
        MF_ATTACH_ISO=/r/transfer.iso; mf_qemu_args browser /b /r
        for ((i=0; i<${#MF_QEMU[@]}; i++)); do [[ ${MF_QEMU[i]} != -drive ]] || last=${MF_QEMU[i+1]}; done
        repair_qemu8_drive_parse "$last"
        neg repair_qemu8_drive_parse "file=/r/t.iso,format=raw,media=cdrom"; neg repair_qemu8_drive_parse "file=/r/t.iso,format=raw,media=disk,readonly=on"
        neg repair_qemu8_drive_parse "file=/r/t.iso,format=raw,media=cdrom,readonly=off"; neg repair_qemu8_drive_parse "file=/r/t.iso,format=raw,media=cdrom,readonly=on,snapshot=on"'
check 'attach: the transfer drive is never given to a role other than browser, and the gateway has no extra device' \
    mf_st "$mf_att"'MF_ATTACH_ISO=/r/transfer.iso; mf_qemu_args gateway /b /r
        [[ " ${MF_QEMU[*]} " != *transfer* && $(printf "%s\n" "${MF_QEMU[@]}" | grep -c "^-drive\$") == 1 ]]
        [[ $(printf "%s\n" "${MF_QEMU[@]}" | grep -c "^-device\$") == $(MF_ATTACH_ISO="" ; mf_qemu_args gateway /b /r; printf "%s\n" "${MF_QEMU[@]}" | grep -c "^-device\$") ]]'

# ---- session lifecycle (mock launcher) -----------------------------------------------
mf_att_mock() { # mode expected-rc attach-file
    local mode=$1 expected=$2 file=$3 dir rc=0 pid role
    dir=$(mktemp -d "${TMPDIR:-/tmp}/mfat.XXXXXXXX"); chmod 700 "$dir"
    mkdir -m 700 "$dir/ev"
    bash "$project/tests/mock-launch.sh" "$mode" "$dir/ev" "$project" "$dir/profile.conf" "$file" >/dev/null 2>&1 || rc=$?
    MF_ATT_DIR=$dir
    [[ $rc == "$expected" ]] || { rm -rf "$dir"; return 1; }
}
mf_att_clean() { # no session directory, copy or ISO remains
    [[ $(find "$MF_ATT_DIR/ev" -mindepth 1 -maxdepth 1 -type d | wc -l) == 0 &&
       -z $(find "$MF_ATT_DIR/ev" \( -name 'transfer*' -o -name 'post.txt' \) -print -quit) ]]
}
mf_att_fixture() { # dir: profile and a good text file
    install -m 600 "$project/tests/fixtures/synthetic.conf" "$1/profile.conf"; printf 'Hello POSTMARK text\n' > "$1/post.txt"
}
mf_att_success() {
    local dir rc=0
    dir=$(mktemp -d "${TMPDIR:-/tmp}/mfat.XXXXXXXX"); mf_att_fixture "$dir"; mkdir -m 700 "$dir/ev"
    bash "$project/tests/mock-launch.sh" browser-first "$dir/ev" "$project" "$dir/profile.conf" "$dir/post.txt" >/dev/null 2>&1 || rc=$?
    MF_ATT_DIR=$dir
    [[ $rc == 0 ]] &&
        [[ $(< "$dir/ev/browser.args") == *"transfer.iso,format=raw,media=cdrom,readonly=on"* ]] &&
        [[ $(< "$dir/ev/gateway.args") != *transfer* ]] &&
        [[ $(< "$dir/ev/iso.args") == *"-volid transfer -r "*"/transfer" ]] &&
        mf_att_clean && [[ -f $dir/post.txt && $(< "$dir/post.txt") == 'Hello POSTMARK text' ]]
}
check 'attach: MOCK session attaches the ISO to the browser only and removes the ISO and copy at exit' \
    bash -c 'source "$1"; mf_att_success; rc=$?; rm -rf "$MF_ATT_DIR"; exit $rc' _ <(declare -f mf_att_success mf_att_fixture mf_att_clean | sed "1i project=$project")
mf_att_failure_case() {
    local kind=$1 mode=${2:-browser-first} dir rc=0
    dir=$(mktemp -d "${TMPDIR:-/tmp}/mfat.XXXXXXXX"); mf_att_fixture "$dir"; mkdir -m 700 "$dir/ev"
    case $kind in nul) printf 'a\0b' > "$dir/post.txt" ;; empty) : > "$dir/post.txt" ;; symlink) mv "$dir/post.txt" "$dir/real"; ln -s "$dir/real" "$dir/post.txt" ;; esac
    bash "$project/tests/mock-launch.sh" "$mode" "$dir/ev" "$project" "$dir/profile.conf" "$dir/post.txt" >/dev/null 2>&1 || rc=$?
    MF_ATT_DIR=$dir
    [[ $rc != 0 && ! -e $dir/ev/gateway.pid && ! -e $dir/ev/browser.pid && ! -e $dir/ev/gateway.args ]] &&
        mf_att_clean
}
for mf_kind in nul empty symlink; do
    check "attach: MOCK a $mf_kind attach file stops the launch before any VM starts and leaves nothing behind" \
        bash -c 'source "$1"; mf_att_failure_case '"$mf_kind"'; rc=$?; rm -rf "$MF_ATT_DIR"; exit $rc' _ \
        <(declare -f mf_att_failure_case mf_att_fixture mf_att_clean | sed "1i project=$project")
done
check 'attach: MOCK an ISO tool failure stops the launch before any VM starts and leaves nothing behind' \
    bash -c 'source "$1"; mf_att_failure_case good iso-failure; rc=$?; rm -rf "$MF_ATT_DIR"; exit $rc' _ \
    <(declare -f mf_att_failure_case mf_att_fixture mf_att_clean | sed "1i project=$project")
mf_att_signal() {
    local dir runner i rc=0
    dir=$(mktemp -d "${TMPDIR:-/tmp}/mfat.XXXXXXXX"); mf_att_fixture "$dir"; mkdir -m 700 "$dir/ev"; MF_ATT_DIR=$dir
    bash "$project/tests/mock-launch.sh" signal "$dir/ev" "$project" "$dir/profile.conf" "$dir/post.txt" >/dev/null 2>&1 &
    runner=$!
    for ((i=0; i<100; i++)); do [[ -f $dir/ev/browser.pid ]] && break; sleep .05; done
    [[ -n $(find "$dir/ev" -name 'transfer.iso' -print -quit) ]] || { kill -TERM "$runner" 2>/dev/null; wait "$runner" 2>/dev/null; return 1; }
    kill -TERM "$runner"; wait "$runner" || rc=$?
    [[ $rc == 143 ]] && mf_att_clean
}
check 'attach: MOCK TERM during a session removes the ISO and the copy' \
    bash -c 'source "$1"; mf_att_signal; rc=$?; rm -rf "$MF_ATT_DIR"; exit $rc' _ \
    <(declare -f mf_att_signal mf_att_fixture mf_att_clean | sed "1i project=$project")
check 'attach: a launch without --attach starts no ISO tool and adds no drive' \
    bash -c 'source "$1"; dir=$(mktemp -d); mf_att_fixture "$dir"; mkdir -m 700 "$dir/ev"
        bash "$2/tests/mock-launch.sh" browser-first "$dir/ev" "$2" "$dir/profile.conf" >/dev/null 2>&1
        [[ ! -e $dir/ev/iso.args && $(< "$dir/ev/browser.args") != *transfer* ]]; rc=$?; rm -rf "$dir"; exit $rc' _ \
    <(declare -f mf_att_fixture | sed "1i project=$project") "$project"

# ---- CLI --------------------------------------------------------------------------------
check 'attach CLI: the file is resolved against the current directory and passed as user mode, other forms unchanged' \
    mf_st "$mf_st_cmds"'mk b 2024-01-01; put_profile; mkdir "$d/cwd"; printf x > "$d/cwd/post.txt"; cd "$d/cwd"; here=$(pwd -P)
        run mf_cmd_launch --attach post.txt; [[ $rc == 0 && $(< "$d/launch.log") == "launch $S/bases/b $S/secrets/wireguard.conf /dev/shm $root user $here/post.txt" ]]
        run mf_cmd_launch --attach ./post.txt b; [[ $(< "$d/launch.log") == "launch $S/bases/b $S/secrets/wireguard.conf /dev/shm $root user $here/./post.txt" ]]
        run mf_cmd_launch --core-policy --attach "$d/cwd/post.txt"; [[ $(< "$d/launch.log") == *"user $d/cwd/post.txt" ]]
        run mf_cmd_launch /abs/base /abs/p /ram --attach "$d/cwd/post.txt"; [[ $(< "$d/launch.log") == "launch /abs/base /abs/p /ram $root user $d/cwd/post.txt" ]]
        run mf_cmd_launch; [[ $(< "$d/launch.log") == "launch $S/bases/b $S/secrets/wireguard.conf /dev/shm $root" ]]'
check 'attach CLI: an option-looking file name is a value, and bad forms are refused before any launch' \
    mf_st "$mf_st_cmds"'mk b 2024-01-01; put_profile; mkdir "$d/cwd"; cd "$d/cwd"; printf x > ./-x.txt; here=$(pwd -P)
        run mf_cmd_launch --attach -x.txt; [[ $rc == 0 && $(< "$d/launch.log") == *"user $here/-x.txt" ]]
        rm -f "$d/launch.log"
        for a in "--attach" "--attach ''" "--attach a --attach b" "--attach-staged" "--attach x --attach-staged /run/mayfly/attach/x"; do
            run eval "mf_cmd_launch $a"; [[ $rc == 64 && ! -e $d/launch.log ]] || { echo "accepted: $a" >&2; exit 1; }
        done
        run mf_cmd_launch --attach missing.txt; [[ $rc == 66 && ! -e $d/launch.log ]]; ln -s ./-x.txt link.txt; run mf_cmd_launch --attach link.txt; [[ $rc == 66 && ! -e $d/launch.log ]]
        mkdir sub; run mf_cmd_launch --attach sub; [[ $rc == 66 && ! -e $d/launch.log ]]'
check 'attach CLI: a refused attach file stops before the core-dump policy is touched' \
    mf_st "$mf_st_cmds"'setcore "$PIPE" 2; mk b 2024-01-01; put_profile; run mf_cmd_launch --core-policy --attach "$d/none.txt"
        [[ $rc == 66 && ! -e $d/sysctl.log && ! -e $d/sudo.log && ! -e $d/launch.log ]]'
check 'attach CLI: help describes the option and its limits' \
    mf_st 'run bash "$project/mayfly.sh"; for w in "--attach FILE" "1 MiB" "NUL" "/mnt/transfer" "rebuilt base"; do grep -qF -- "$w" "$d/out"; done'
check 'attach CLI: the launcher runs the attach code only in the launch path and the file is added to the installer list' \
    bash -c 'source "$1/host/install-host.sh"; printf "%s\n" "${MF_RUNTIME_FILES[@]}" | grep -qx lib/attach.sh && grep -q "lib/attach.sh" "$1/mayfly.sh" || grep -q "attach.sh" "$1/mayfly.sh"' _ "$project"

# ---- dedicated-user wrapper -----------------------------------------------------------------
check 'attach wrapper: launch parsing takes --attach FILE and never the internal staged option' \
    mf_sub 'mf_parse_launch --attach post.txt test-09 && [[ $MF_ARG_ATTACH == post.txt && $MF_ARG_NAME == test-09 ]]
        mf_parse_launch --core-policy --attach "/home/u/a b.txt" --diag && [[ $MF_ARG_ATTACH == "/home/u/a b.txt" ]]
        mf_parse_launch && [[ -z $MF_ARG_ATTACH ]]
        mf_parse_launch --attach -x.txt && [[ $MF_ARG_ATTACH == -x.txt ]]
        for a in "--attach" "--attach a --attach b" "--attach-staged /run/mayfly/attach/x" "--attach x --attach-staged y" "--attach=x"; do neg mf_parse_launch $a; done
        neg mf_parse_launch --attach ""; neg mf_parse_launch --attach "$(printf "a\nb")"; neg mf_parse_launch --attach "$(printf "a\033b")"'
check 'attach wrapper: the service-user command carries only the staged path, never a user path' \
    mf_sub 'mf_launch_cmd test-09 0 /run/mayfly/wayland-0; c="${MF_CMD[*]}"; [[ $c != *attach* ]]
        mf_launch_cmd test-09 0 /run/mayfly/wayland-0 /run/mayfly/attach/post.txt; c="${MF_CMD[*]}"
        [[ $c == *"mayfly.sh launch --attach-staged /run/mayfly/attach/post.txt /var/lib/mayfly/bases/test-09 /var/lib/mayfly/secrets/wireguard.conf /dev/shm" ]]
        [[ ${MF_CMD[0]} == env && ${MF_CMD[1]} == -i && $c != *" --attach "* ]]
        MF_ARG_ATTACH=/home/u/secret.txt; mf_launch_cmd test-09 0 /run/mayfly/wayland-0 /run/mayfly/attach/post.txt; [[ " ${MF_CMD[*]} " != *secret.txt* ]]'
mf_att_ns='
    project='"$project"'
    d=$(mktemp -d "${TMPDIR:-/tmp}/pbat.XXXXXXXX"); trap "rm -rf -- $d" EXIT
    log=$d/log; MF_RUN_DIR=$d/run; mkdir -p "$MF_RUN_DIR" "$d/home"; : > "$log"
    MF_IN_NS=1; MF_PROG=$project
    mf_check_install() { :; }
    install() { if [[ $1 == -d ]]; then mkdir -p -- "${@: -1}"; [[ $2 != -m ]] || chmod "$3" -- "${@: -1}"; fi; }
    chown() { printf "chown %s\n" "$*" >> "$log"; }
    mount() { printf "mount %s\n" "$*" >> "$log"; if [[ $1 == --bind ]]; then sockhook "$3"; fi; }
    setfacl() { printf "setfacl %s\n" "$*" >> "$log"; }
    sockhook() { rm -f -- "$1"; python3 -c "import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])" "$1"; }
    runuser() {
        printf "runuser %s\n" "$*" >> "$log"
        if [[ -f $MF_RUN_DIR/attach/post.txt ]]; then
            cp "$MF_RUN_DIR/attach/post.txt" "$d/seen"; stat -c %a "$MF_RUN_DIR/attach/post.txt" > "$d/seenmode"; stat -c %a "$MF_RUN_DIR/attach" > "$d/seendir"
        fi
        return 0
    }
    printf "Hello POSTMARK text\n" > "$d/home/post.txt"
'
check 'attach wrapper: the file is read as root on its descriptor into the private tmpfs and only that copy reaches the launcher' \
    mf_sub "$mf_att_ns"'rc=0; (mf_ns_launch $(id -u) wayland-0 0 test-09 "$d/home/post.txt") || rc=$?; [[ $rc == 0 ]]
        [[ $(sha256sum < "$d/seen") == "$(sha256sum < "$d/home/post.txt")" ]]; [[ $(< "$d/seenmode") == 640 && $(< "$d/seendir") == 750 ]]
        grep -q "^runuser .*launch --attach-staged $MF_RUN_DIR/attach/post.txt " "$log"; neg grep -q "$d/home" <(grep "^runuser" "$log")
        grep -q "^chown root:mayfly -- $MF_RUN_DIR/attach/post.txt\$" "$log"; grep -q "mount -t tmpfs .*size=3m" "$log"
        [[ ! -e $MF_RUN_DIR/attach/post.txt ]]; [[ -f $d/home/post.txt ]]'
check 'attach wrapper: refused files never start the launcher, leave no copy and print no contents' \
    mf_sub "$mf_att_ns"'ln -s "$d/home/post.txt" "$d/home/link.txt"; mkdir "$d/home/dir"; mkfifo "$d/home/fifo"; : > "$d/home/empty"; printf "POSTMARK\0x" > "$d/home/nul"
        head -c 1048577 /dev/zero | tr "\0" a > "$d/home/big"
        for f in link.txt dir fifo empty nul big missing; do
            : > "$log"; rc=0; (mf_ns_launch $(id -u) wayland-0 0 test-09 "$d/home/$f") > "$d/out" 2>&1 || rc=$?
            [[ $rc != 0 ]] || { echo "accepted $f" >&2; exit 1; }
            neg grep -q "^runuser" "$log"; [[ -z $(ls -A "$MF_RUN_DIR/attach") ]]; neg grep -q POSTMARK "$d/out"
        done
        rc=0; (mf_ns_launch $(id -u) wayland-0 0 test-09 relative.txt) >/dev/null 2>&1 || rc=$?; [[ $rc != 0 ]]; neg grep -q "^runuser" "$log"'
check 'attach wrapper: a file owned by another user is refused by the staging step' \
    mf_sub "$mf_att_ns"'source "$MF_PROG/lib/policy.sh"; source "$MF_PROG/lib/attach.sh"
        rc=0; (mf_ns_stage_attach "$d/home/post.txt" $(( $(id -u) + 1 ))) >/dev/null 2>&1 || rc=$?; [[ $rc != 0 && -z $(ls -A "$MF_RUN_DIR/attach") ]]
        rc=0; (mf_ns_stage_attach "$d/home/post.txt" 0) >/dev/null 2>&1 || rc=$?; [[ $rc != 0 ]]'
check 'attach wrapper: the staged copy is removed when the launcher fails or the namespace exits' \
    mf_sub "$mf_att_ns"'runuser() { printf "runuser %s\n" "$*" >> "$log"; [[ -f $MF_RUN_DIR/attach/post.txt ]] && : > "$d/existed"; return 7; }
        rc=0; (mf_ns_launch $(id -u) wayland-0 0 test-09 "$d/home/post.txt") || rc=$?; [[ $rc == 7 && -e $d/existed && ! -e $MF_RUN_DIR/attach/post.txt ]]
        runuser() { : > "$d/existed2"; kill -TERM $BASHPID; sleep 1; }
        { (mf_ns_launch $(id -u) wayland-0 0 test-09 "$d/home/post.txt") || :; } 2>/dev/null; [[ ! -e $MF_RUN_DIR/attach/post.txt ]]'
check 'attach wrapper: bad internal attach arguments are refused before the namespace is touched' \
    mf_sub "$mf_att_ns"'for a in relative.txt "$(printf "/a\nb")" "$(printf "/a\033b")"; do
            : > "$log"; rc=0; (mf_ns_launch $(id -u) wayland-0 0 test-09 "$a") >/dev/null 2>&1 || rc=$?; [[ $rc == 64 && ! -s $log ]]; done'
check 'attach wrapper: sudo launch resolves a relative file against the caller directory and passes it to the namespace' \
    mf_sub 'project='"$project"'; d=$(mktemp -d "${TMPDIR:-/tmp}/pbat.XXXXXXXX"); trap "rm -rf -- $d" EXIT; export MAYFLY_HOME=$d/state; '"$mf_wst_launch"'
        mkdir "$d/cwd"; printf x > "$d/cwd/rel.txt"; MF_CALLER_PWD=$d/cwd
        mf_cmd_launch --core-policy --attach rel.txt --display wayland-0 test-09 >/dev/null 2>&1
        [[ $(< "$d/ns.log") == "ns 1000 wayland-0 0 test-09 $d/cwd/rel.txt" ]]
        exec() { printf "exec %s\n" "$*" > "$d/exec.log"; }
        mf_cmd_launch --attach "$d/cwd/rel.txt" --display wayland-0 test-09
        [[ $(< "$d/exec.log") == *"__ns-launch 1000 wayland-0 0 test-09 $d/cwd/rel.txt" ]]
        mf_cmd_launch --display wayland-0 test-09; [[ $(< "$d/exec.log") == *"__ns-launch 1000 wayland-0 0 test-09" ]]
        :'
check 'attach wrapper: root never tests the caller path before the descriptor-based validation (no existence oracle)' \
    bash -c '! sed -n "/^mf_cmd_launch()/,/^}/p" "$1" | grep -qF -e "-f \$attach" -e "-e \$attach" -e "-L \$attach"' _ "$mf_wrapper"
check 'attach wrapper: the wrapper records the caller directory before it changes to /, and usage lists --attach' \
    bash -c 'f=$1; awk "/^MF_CALLER_PWD=/ {a = NR} /^cd \\/\$/ {b = NR} END {exit !(a && b && a < b)}" "$f" && grep -qF -- "--attach FILE" "$f"' _ "$mf_wrapper"

# ---- guest image -----------------------------------------------------------------------------------
check 'attach guest: Firefox policy and the I2P profile do not block file:// pages' \
    bash -c 'jq -e ".policies | (has(\"WebsiteFilter\") or has(\"Homepage\") | not) and (.HttpsOnlyMode == \"enabled\")" "$1/guest/firefox-policies.json" >/dev/null &&
        ! grep -Eiq "fileuri|network\.file|WebsiteFilter|file://|security\.fileuri|network.protocol-handler" "$1/guest/i2p-user.js" "$1/guest/firefox-policies.json"' _ "$project"
check 'attach guest: the mount is by label, read-only, nosuid,nodev,noexec, nofail and automounted' \
    bash -c 'grep -q "LABEL=transfer /mnt/transfer iso9660 ro,nosuid,nodev,noexec,nofail,x-systemd.automount,x-systemd.device-timeout=3s 0 0" "$1/guest/browser-prepare.sh" && ! grep -q "/dev/sr0" "$1/guest/browser-prepare.sh"' _ "$project"
