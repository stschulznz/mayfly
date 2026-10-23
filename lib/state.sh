#!/bin/bash
# Default state directory, default file locations and the first-run setup flow.
# Mode 2 keeps state under the user's own home. Mode 1 points MAYFLY_HOME at
# the root-owned /var/lib/mayfly layout, whose subdirectories belong to the
# service user.

MF_STATE_SUBDIRS=(pins bases secrets downloads)
MF_BASE_NAME_RE='^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$'

mf_valid_base_name() {
    [[ ${1:-} =~ $MF_BASE_NAME_RE ]]
}

# Print the state directory path. It is not created or validated here.
mf_state_dir() {
    local dir
    if [[ -n ${MAYFLY_HOME:-} ]]; then
        dir=$MAYFLY_HOME
    elif [[ -n ${XDG_STATE_HOME:-} ]]; then
        dir=$XDG_STATE_HOME/mayfly
    elif [[ -n ${HOME:-} ]]; then
        dir=$HOME/.local/state/mayfly
    else
        mf_error 'cannot work out the state directory; set MAYFLY_HOME'
        return 1
    fi
    [[ $dir == /* ]] || { mf_error 'the state directory must be an absolute path'; return 1; }
    printf '%s\n' "$dir"
}

# Strict check of one private directory. Refuses symlinks, other owners and
# any mode other than 0700. Never repairs anything.
mf_state_dir_ok() {
    local dir=$1
    [[ -d $dir && ! -L $dir ]] ||
        { mf_error 'state path is missing, not a directory, or a symlink'; return 1; }
    [[ $(stat -c '%u:%a' -- "$dir") == "$UID:700" ]] ||
        { mf_error 'state directory has the wrong owner or mode (need your user and 0700)'; return 1; }
}

# mf_state_init create|check
# Prints the canonical state directory. "create" makes missing 0700
# directories; "check" only validates what exists. Call it in a subshell.
mf_state_init() (
    set -euo pipefail
    umask 077
    local action=${1:-create} dir name top
    dir=$(mf_state_dir) || exit 1
    [[ $dir =~ ^/[A-Za-z0-9_./-]+$ && $dir != *'/../'* && $dir != */.. && $dir != *'//'* ]] ||
        { mf_error 'the state directory path may only use letters, digits, _ . / and -'; exit 1; }
    [[ ! -L $dir ]] || { mf_error 'the state directory must not be a symlink'; exit 1; }
    if [[ ! -e $dir ]]; then
        [[ $action == create ]] ||
            { mf_error 'no state directory yet; run: mayfly setup'; exit 1; }
        mkdir -p -m 700 -- "$dir" || exit 1
    fi
    dir=$(realpath -e -- "$dir") || exit 1
    top=$(stat -c '%u:%a' -- "$dir") || exit 1
    if [[ $top == "$UID:700" ]]; then
        :
    elif [[ $top == 0:711 && $UID != 0 ]]; then
        # Dedicated-user layout: root owns the top, subdirectories are ours.
        action=check
    else
        mf_error 'state directory has the wrong owner or mode (need your user and 0700)'
        exit 1
    fi
    for name in "${MF_STATE_SUBDIRS[@]}"; do
        if [[ ! -e $dir/$name && ! -L $dir/$name ]]; then
            [[ $action == create ]] ||
                { mf_error "state subdirectory missing: $name"; exit 1; }
            mkdir -m 700 -- "$dir/$name" || exit 1
        fi
        mf_state_dir_ok "$dir/$name" || exit 1
    done
    printf '%s\n' "$dir"
)

mf_state_pins_file() { printf '%s\n' "$1/pins/build.pins"; }
mf_state_profile_file() { printf '%s\n' "$1/secrets/wireguard.conf"; }

# Print the newest base name under a state directory. A base is a real
# directory holding gateway.qcow2 and browser.qcow2. Newest means the latest
# browser.sha256 modification time (a build writes it last), then the name.
mf_state_newest_base() {
    local dir=$1/bases entry name stamp
    local -a rows=()
    [[ -d $dir && ! -L $dir ]] || return 1
    for entry in "$dir"/*; do
        name=${entry##*/}
        [[ -d $entry && ! -L $entry ]] && mf_valid_base_name "$name" || continue
        [[ -f $entry/gateway.qcow2 && -f $entry/browser.qcow2 ]] || continue
        stamp=$(stat -c %Y -- "$entry/browser.qcow2" 2>/dev/null) || continue
        if [[ -f $entry/browser.sha256 ]]; then
            stamp=$(stat -c %Y -- "$entry/browser.sha256" 2>/dev/null) || continue
        fi
        rows+=("$stamp $name")
    done
    (( ${#rows[@]} )) || return 1
    printf '%s\n' "${rows[@]}" | sort -k1,1nr -k2,2r | { read -r _ name; printf '%s\n' "$name"; }
}

mf_profile_help() {
    local file=$1
    printf '%s\n' \
        "No WireGuard profile at: $file" \
        "Put your provider's file there with mode 0600, for example:" \
        "  install -m 600 /path/to/your-profile.conf \"$file\"" \
        'Mayfly accepts one [Interface] (IPv4 /32 Address, one numeric IPv4 DNS) and' \
        'one [Peer] (AllowedIPs = 0.0.0.0/0, numeric IPv4 Endpoint). See the README.' \
        'Mayfly does not read or print the file at this step.' \
        'Then run "mayfly setup" again.'
}

# Explicit returns: this also runs while errexit is off (inside the core-policy guard).
mf_profile_check() {
    mf_profile_dump_guard || return 1
    mf_open_profile "$1" "$root" || return 1
    mf_parse_profile <&"$MF_PROFILE_FD" || { exec {MF_PROFILE_FD}<&-; return 1; }
    exec {MF_PROFILE_FD}<&-
    printf '%s\n' 'Profile syntax accepted. No keys printed, VM started or live route verified.'
}

# mf_setup [--core-policy] [--yes]
# Call it as a plain command under set -e (never after || or inside if), so
# that mf_build and mf_fetch_pins keep their errexit protection.
mf_setup() {
    local want_core=0 state pins profile base name
    local -a yes=()
    while (( $# )); do
        case $1 in
            --core-policy) want_core=1 ;;
            --yes) yes=(--yes) ;;
            *) return 64 ;;
        esac
        shift
    done
    printf '%s\n' '[1/6] Preflight'
    mf_preflight
    printf '%s\n' '[2/6] State directories'
    state=$(mf_state_init create)
    printf 'ok: %s\n' "$state"
    pins=$(mf_state_pins_file "$state")
    profile=$(mf_state_profile_file "$state")
    printf '%s\n' '[3/6] WireGuard profile'
    if [[ ! -f $profile || -L $profile ]]; then
        mf_profile_help "$profile"
        return 0
    fi
    printf '%s\n' 'already done: profile present (not read here)'
    base=$(mf_state_newest_base "$state" 2>/dev/null) || base=''
    printf '%s\n' '[4/6] Profile syntax check'
    if [[ -e $pins && -n $base ]]; then
        printf '%s\n' 'already done: pins and base exist; the profile is checked again at launch'
    else
        if (( want_core == 0 )) && ! mf_core_satisfied; then
            printf '%s\n' \
                'The host core-dump policy blocks profile parsing. Run "mayfly setup --core-policy"' \
                'or "mayfly core-policy apply", then run "mayfly setup" again.' >&2
            return 78
        fi
        if (( want_core )); then
            mf_core_guarded mf_profile_check "$profile"
        else
            mf_profile_check "$profile"
        fi
    fi
    printf '%s\n' '[5/6] Download pins'
    if [[ -e $pins || -L $pins ]]; then
        printf '%s\n' 'already done: pins file exists'
    else
        mf_fetch_pins "${yes[@]}" "$pins"
    fi
    printf '%s\n' '[6/6] Base image'
    if [[ -n $base ]]; then
        printf 'already done: base %s\n' "$base"
    else
        name=base-$(date +%Y%m%d)
        mf_build "$pins" "$state/bases/$name" "$project" "$root"
    fi
    printf '%s\n' 'Setup finished. Next: mayfly launch'
}

# Split "--core-policy" from other words. Sets MF_CORE_FLAG and MF_ARGS.
mf_split_core_flag() {
    local arg
    MF_CORE_FLAG=0 MF_ARGS=()
    for arg in "$@"; do
        case $arg in
            --core-policy) MF_CORE_FLAG=1 ;;
            -*) usage; exit 64 ;;
            *) MF_ARGS+=("$arg") ;;
        esac
    done
}

# mf_cmd_check_profile [--core-policy] [ABSOLUTE-PROFILE]
mf_cmd_check_profile() {
    local state profile
    mf_split_core_flag "$@"
    (( ${#MF_ARGS[@]} <= 1 )) || { usage; exit 64; }
    if (( ${#MF_ARGS[@]} == 1 )); then
        [[ ${MF_ARGS[0]} == /* ]] || { usage; exit 64; }
        profile=${MF_ARGS[0]}
    else
        state=$(mf_state_init check)
        profile=$(mf_state_profile_file "$state")
        [[ -f $profile ]] || { mf_profile_help "$profile" >&2; exit 66; }
    fi
    if (( MF_CORE_FLAG )); then
        mf_core_guarded mf_profile_check "$profile"
    else
        mf_profile_check "$profile"
    fi
}

# mf_cmd_build [PINS-FILE] [NAME | NEW-BASE-DIRECTORY]
mf_cmd_build() {
    local state pins='' out='' name=''
    (( $# <= 2 )) || { usage; exit 64; }
    if (( $# == 2 )); then
        [[ $1 == /* ]] || { usage; exit 64; }
        pins=$1
        if [[ $2 == /* ]]; then
            out=$2
        else
            mf_valid_base_name "$2" || { usage; exit 64; }
            name=$2
        fi
    elif (( $# == 1 )); then
        if [[ $1 == /* ]]; then
            pins=$1
        else
            mf_valid_base_name "$1" || { usage; exit 64; }
            name=$1
        fi
    fi
    state=$(mf_state_init create)
    [[ -n $pins ]] || pins=$(mf_state_pins_file "$state")
    [[ -e $pins ]] || mf_die "no pins file at $pins; run: mayfly fetch-pins" 66
    if [[ -z $out ]]; then
        [[ -n $name ]] || name=base-$(date +%Y%m%d)
        out=$state/bases/$name
        [[ ! -e $out && ! -L $out ]] ||
            mf_die "base $name already exists and builds never overwrite; pick a name: mayfly build ${name}-2" 73
    fi
    mf_build "$pins" "$out" "$project" "$root"
}

# mf_cmd_launch [--core-policy] [NAME | BASE-DIRECTORY [PROFILE-FILE [RAM-PARENT]]]
# Absolute BASE-DIRECTORY PROFILE-FILE [RAM-PARENT] is the long form used by
# the dedicated-user wrapper.
mf_cmd_launch() {
    local state base profile parent=/dev/shm name
    mf_split_core_flag "$@"
    case ${#MF_ARGS[@]} in
        0|1)
            state=$(mf_state_init check)
            profile=$(mf_state_profile_file "$state")
            if (( ${#MF_ARGS[@]} == 0 )); then
                name=$(mf_state_newest_base "$state") ||
                    mf_die 'no base found; run: mayfly setup' 66
                base=$state/bases/$name
            elif [[ ${MF_ARGS[0]} == /* ]]; then
                base=${MF_ARGS[0]}
            else
                mf_valid_base_name "${MF_ARGS[0]}" || { usage; exit 64; }
                base=$state/bases/${MF_ARGS[0]}
            fi
            [[ -f $profile && ! -L $profile ]] ||
                { mf_profile_help "$profile" >&2; exit 66; } ;;
        2|3)
            [[ ${MF_ARGS[0]} == /* && ${MF_ARGS[1]} == /* && ${MF_ARGS[2]:-/dev/shm} == /* ]] ||
                { usage; exit 64; }
            base=${MF_ARGS[0]} profile=${MF_ARGS[1]} parent=${MF_ARGS[2]:-/dev/shm} ;;
        *) usage; exit 64 ;;
    esac
    printf '%s\n' "$MF_REMINDER" >&2
    if (( MF_CORE_FLAG )); then
        mf_core_guarded mf_launch_sub "$base" "$profile" "$parent" "$root"
    else
        mf_launch "$base" "$profile" "$parent" "$root"
    fi
}

mf_die() {
    mf_error "$1" || :
    exit "${2:-1}"
}

# A subshell, so mf_launch keeps its own EXIT trap and the core-policy guard
# in this shell stays armed until the session has fully ended.
mf_launch_sub() ( mf_launch "$@" )
