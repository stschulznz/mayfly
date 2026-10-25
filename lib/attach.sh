#!/bin/bash
# One-way text transfer: one validated file becomes a tiny read-only ISO that
# is attached to the browser VM only. Nothing here reads the file by path more
# than once, and file contents are never printed.

MF_ATTACH_MAX=1048576
MF_ATTACH_DEFAULT_NAME=transfer.txt
MF_ATTACH_STAGED_RE='^/run/mayfly/attach/([A-Za-z0-9][A-Za-z0-9._-]{0,63})$'

# In-guest file name. Anything outside the safe set, or starting with - or .,
# becomes transfer.txt.
mf_attach_name() {
    local name=${1##*/}
    if [[ $name =~ ^[A-Za-z0-9._-]{1,64}$ && $name != -* && $name != .* ]]; then
        printf '%s\n' "$name"
    else
        printf '%s\n' "$MF_ATTACH_DEFAULT_NAME"
    fi
}

# mf_attach_read SOURCE OWNER-UID DEST
# Opens SOURCE once and validates the open descriptor: regular file, same
# object the path named (so not a symlink), owned by OWNER-UID (0 also accepts
# the container overflow root), 1..1 MiB, no NUL bytes. The bytes go to DEST
# (0600) from that descriptor. Fixed error text only.
mf_attach_read() {
    local src=$1 uid=$2 dest=$3 fd owner size kind actual
    [[ $src == /* && $uid =~ ^[0-9]+$ ]] ||
        { mf_error 'attach file must be given as an absolute path'; return 1; }
    [[ -f $src && ! -L $src ]] ||
        { mf_error 'attach file must be an existing regular file and not a symlink'; return 1; }
    if ! { exec {fd}< "$src"; } 2>/dev/null; then
        mf_error 'cannot open the attach file'; return 1
    fi
    read -r owner size kind < <(stat -Lc '%u %s %f' "/proc/self/fd/$fd" 2>/dev/null) || owner=''
    if [[ $(stat -Lc '%d %i' "/proc/self/fd/$fd" 2>/dev/null) != "$(stat -c '%d %i' -- "$src" 2>/dev/null)" ]]; then
        exec {fd}<&-
        mf_error 'the attach file changed while it was opened'; return 1
    fi
    if [[ ! $kind =~ ^[a-fA-F0-9]+$ ]] || (( (16#$kind & 0170000) != 0100000 )); then
        exec {fd}<&-
        mf_error 'attach file must be a regular file'; return 1
    fi
    if [[ $owner != "$uid" ]] && ! { [[ $uid == 0 ]] && mf_root_owner "$owner"; }; then
        exec {fd}<&-
        mf_error 'attach file must be owned by you'; return 1
    fi
    if [[ ! $size =~ ^[0-9]+$ ]] || (( size < 1 || size > MF_ATTACH_MAX )); then
        exec {fd}<&-
        mf_error 'attach file must be 1 to 1048576 bytes'; return 1
    fi
    if ! (umask 077; head -c "$((MF_ATTACH_MAX + 1))" <&"$fd" > "$dest") 2>/dev/null; then
        exec {fd}<&-
        rm -f -- "$dest"
        mf_error 'could not read the attach file'; return 1
    fi
    exec {fd}<&-
    chmod 600 -- "$dest"
    actual=$(stat -c %s -- "$dest")
    if [[ $actual != "$size" ]] ||
        [[ $(LC_ALL=C tr -d '\000' < "$dest" | wc -c) != "$size" ]]; then
        rm -f -- "$dest"
        mf_error 'attach file must be plain text (no NUL bytes) and must not change while it is read'; return 1
    fi
}

# mf_make_transfer_iso DEST DIRECTORY: ISO9660 with Rock Ridge (-r makes
# everything world-readable and root-owned so the unprivileged guest user can
# read it), volume label "transfer", holding exactly DIRECTORY's contents.
mf_make_transfer_iso() {
    local dest=$1 dir=$2 tool
    tool=$(mf_iso_tool) ||
        { mf_error 'an ISO tool (genisoimage, mkisofs or xorriso) is required for --attach'; return 1; }
    if [[ $tool == xorriso ]]; then
        xorriso -no_rc -as mkisofs -quiet -output "$dest" -volid transfer -r "$dir" >/dev/null 2>&1 ||
            { rm -f -- "$dest"; mf_error 'could not build the transfer ISO'; return 1; }
    else
        "$tool" -quiet -output "$dest" -volid transfer -r "$dir" >/dev/null 2>&1 ||
            { rm -f -- "$dest"; mf_error 'could not build the transfer ISO'; return 1; }
    fi
    [[ -s $dest ]] || { rm -f -- "$dest"; mf_error 'could not build the transfer ISO'; return 1; }
    chmod 600 -- "$dest"
}

# mf_attach_prepare MODE PATH RUN
# MODE user: PATH is the caller's own file (owner must be the current user).
# MODE staged: PATH is the root-owned copy the dedicated-user wrapper made
# inside its private /run/mayfly mount; no other path is accepted.
# Sets MF_ATTACH_ISO. Everything it creates lives in RUN and goes with the session.
mf_attach_prepare() {
    local mode=$1 path=$2 run=$3 dir name
    MF_ATTACH_ISO=''
    dir=$run/transfer
    case $mode in
        user)
            name=$(mf_attach_name "$path")
            mkdir -m 700 -- "$dir" || return 1
            mf_attach_read "$path" "$UID" "$dir/$name" || return 1 ;;
        staged)
            [[ $path =~ $MF_ATTACH_STAGED_RE ]] ||
                { mf_error 'the staged attach path is not the wrapper path'; return 1; }
            name=${BASH_REMATCH[1]}
            mkdir -m 700 -- "$dir" || return 1
            mf_attach_read "$path" 0 "$dir/$name" || return 1 ;;
        *) mf_error 'unknown attach mode'; return 1 ;;
    esac
    mf_make_transfer_iso "$run/transfer.iso" "$dir" || return 1
    MF_ATTACH_ISO=$run/transfer.iso
}
