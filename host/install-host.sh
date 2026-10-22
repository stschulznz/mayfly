#!/bin/bash
# One-time root setup for the dedicated mayfly user. Run it yourself:
#   sudo bash host/install-host.sh --profile PATH --pins PATH [--expect-rev SHA]
# It never reboots, never changes network or firewall settings, and never reads
# your profile (it copies the file into the new user's private directory).
# Re-run it after you update the source; guest scripts are baked into bases,
# so build a new base after reinstalling.
set +x
set -euo pipefail
export LC_ALL=C
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
umask 022

MF_USER=mayfly
MF_STATE=/var/lib/mayfly
MF_PROG=/usr/local/lib/mayfly
MF_WRAPPER=/usr/local/sbin/mayfly

# Exact runtime files copied to the root-owned tree. Tests and docs stay out.
MF_RUNTIME_FILES=(
    mayfly.sh
    lib/build.sh
    lib/host.sh
    lib/policy.sh
    lib/preflight.sh
    lib/runtime.sh
    guest/browser-prepare.sh
    guest/desktop.sh
    guest/diag.sh
    guest/firefox-policies.json
    guest/i2pd.conf
    guest/i2p-tunnels.conf
    guest/i2p-user.js
    guest/network.sh
    guest/prepare.sh
    guest/mayfly.service
)

mf_die() {
    printf 'install-host: %s\n' "$1" >&2
    exit "${2:-1}"
}

mf_step() {
    printf '+'
    printf ' %q' "$@"
    printf '\n'
    (( MF_DRY )) || "$@"
}

# Read a regular file owned by the invoking user to stdout. The file is opened
# once and the opened object is verified, so swapping the path afterwards cannot
# make root read anything else.
mf_read_user_file() {
    local path=$1 limit=$2 fd owner size mode
    [[ -f $path && ! -L $path ]] || return 1
    if ! { exec {fd}< "$path"; } 2>/dev/null; then
        return 1
    fi
    read -r owner size mode < <(stat -L -c '%u %s %f' "/proc/self/fd/$fd") || { exec {fd}<&-; return 1; }
    if [[ $owner != "${SUDO_UID:-0}" || ! $size =~ ^[0-9]+$ ]] || (( size > limit )) ||
        (( (0x$mode & 0xF000) != 0x8000 )); then
        exec {fd}<&-
        return 1
    fi
    head -c "$limit" <&"$fd"
    exec {fd}<&-
}

# Copy a user-owned source file into a root-owned destination.
mf_copy_user_file() {
    local src=$1 dest=$2 mode=$3
    printf '+ copy %q -> %q (mode %s, root:root)\n' "$src" "$dest" "$mode"
    (( MF_DRY )) && return 0
    (umask 077; mf_read_user_file "$src" 1048576 > "$dest") ||
        mf_die "could not safely read $src"
    chown root:root -- "$dest"
    chmod "$mode" -- "$dest"
}

mf_ensure_user() {
    local shell
    if id -u "$MF_USER" >/dev/null 2>&1; then
        shell=$(getent passwd "$MF_USER" | cut -d: -f7)
        [[ $shell == */nologin || $shell == /bin/false || $shell == /usr/bin/false ]] ||
            mf_die "$MF_USER exists but is not a no-login account"
        (( $(id -u "$MF_USER") < 1000 )) ||
            mf_die "$MF_USER exists but is not a system account"
        printf 'user %s already exists\n' "$MF_USER"
    else
        local nologin
        nologin=$(command -v nologin || true)
        [[ -n $nologin ]] || nologin=/usr/sbin/nologin
        mf_step useradd --system --user-group --home-dir "$MF_STATE" --no-create-home \
            --shell "$nologin" --comment 'Mayfly browser VMs' "$MF_USER"
    fi
    mf_ensure_kvm_access
}

# Debian, Ubuntu and Arch ship /dev/kvm as root:kvm 0660; Fedora and Bazzite
# make it world-accessible through a udev rule. Grant the group only when needed.
mf_ensure_kvm_access() {
    local mode group
    [[ -c ${MF_KVM_DEV:-/dev/kvm} ]] || { printf 'warning: /dev/kvm is missing; VMs will not start\n'; return 0; }
    mode=$(stat -c "%a" "${MF_KVM_DEV:-/dev/kvm}")
    (( (8#$mode & 6) == 6 )) && return 0
    group=$(stat -c "%G" "${MF_KVM_DEV:-/dev/kvm}")
    [[ $group != root && $group != UNKNOWN ]] || mf_die "/dev/kvm is not accessible and has no usable group"
    getent group "$group" >/dev/null || mf_die "group $group (owner of /dev/kvm) is not resolvable"
    mf_step usermod --append --groups "$group" "$MF_USER"
}

mf_ensure_state() {
    local name
    # A root-owned parent stops the service user from swapping its own
    # subdirectories for symlinks that a later root write could follow.
    mf_step install -d -m 0711 -o root -g root -- "$MF_STATE"
    for name in home downloads pins secrets bases reports; do
        [[ ! -L $MF_STATE/$name ]] || mf_die "$MF_STATE/$name is a symlink; remove it and rerun"
        mf_step install -d -m 0700 -o "$MF_USER" -g "$MF_USER" -- "$MF_STATE/$name"
    done
}

mf_check_sources() {
    local file
    for file in "${MF_RUNTIME_FILES[@]}" host/mayfly-wrapper.sh; do
        [[ -f $MF_SOURCE/$file && ! -L $MF_SOURCE/$file ]] ||
            mf_die "source file missing or a symlink: $file"
        [[ $(realpath -e -- "$MF_SOURCE/$file") == "$MF_SOURCE/$file" ]] ||
            mf_die "source path crosses a symlink: $file"
    done
}

# Run git as the invoking user, never as root: a checkout the user controls can
# carry configuration that executes commands.
mf_git() {
    if (( EUID == 0 )); then
        [[ -n ${SUDO_USER:-} ]] || return 1
        runuser -u "$SUDO_USER" -- env -i PATH=/usr/bin:/bin git -C "$MF_SOURCE" "$@"
    else
        git -C "$MF_SOURCE" "$@"
    fi
}

mf_source_revision() {
    local status
    MF_REV=unknown MF_DIRTY=unknown
    if MF_REV=$(mf_git rev-parse HEAD 2>/dev/null) &&
        status=$(mf_git status --porcelain -- . 2>/dev/null); then
        if [[ -z $status ]]; then
            MF_DIRTY=no
        else
            MF_DIRTY=yes
        fi
    else
        MF_REV=unknown MF_DIRTY=unknown
    fi
}

mf_install_tree() {
    local file
    [[ $MF_PROG == /usr/local/lib/mayfly ]] || mf_die 'unexpected program path'
    mf_step install -d -m 0755 -o root -g root -- /usr/local/sbin
    mf_step rm -rf --one-file-system -- "$MF_PROG"
    mf_step install -d -m 0755 -o root -g root -- "$MF_PROG" "$MF_PROG/lib" "$MF_PROG/guest"
    for file in "${MF_RUNTIME_FILES[@]}"; do
        mf_copy_user_file "$MF_SOURCE/$file" "$MF_PROG/$file" 0644
    done
    if (( MF_DRY )); then
        printf '+ write %s/MANIFEST.sha256 and REVISION\n' "$MF_PROG"
    else
        (cd -- "$MF_PROG" && sha256sum -- "${MF_RUNTIME_FILES[@]}" > MANIFEST.sha256)
        printf '%s\n' "$MF_REV" > "$MF_PROG/REVISION"
        chown root:root "$MF_PROG/MANIFEST.sha256" "$MF_PROG/REVISION"
        chmod 0644 "$MF_PROG/MANIFEST.sha256" "$MF_PROG/REVISION"
    fi
    mf_copy_user_file "$MF_SOURCE/host/mayfly-wrapper.sh" "$MF_WRAPPER" 0755
    if command -v restorecon >/dev/null 2>&1; then
        mf_step restorecon -R "$MF_PROG" "$MF_WRAPPER"
    fi
}

mf_install_private_file() {
    local label=$1 source=$2 dest=$3 limit=$4 tmp
    if [[ -e $dest && $MF_REPLACE != 1 ]]; then
        mf_die "$label already installed; add --replace to overwrite it"
    fi
    printf '+ copy %q -> %q as %s (mode 0600)\n' "$source" "$dest" "$MF_USER"
    (( MF_DRY )) && return 0
    tmp=$(mktemp)
    # Verify and read once as root into a private temp file, then let the
    # service user write the destination so no root write follows its links.
    if ! mf_read_user_file "$source" "$limit" > "$tmp"; then
        rm -f -- "$tmp"
        mf_die "$label must be a regular file you own, at most $limit bytes, not a symlink"
    fi
    runuser -u "$MF_USER" -- bash -c 'umask 077; cat > "$1.new" && mv -f -- "$1.new" "$1"' _ "$dest" < "$tmp" ||
        { rm -f -- "$tmp"; mf_die "could not install the $label"; }
    rm -f -- "$tmp"
}

mf_install_main() {
    local profile='' pins='' allow_dirty=0 expect_rev=''
    MF_DRY=0 MF_REPLACE=0
    while (( $# )); do
        case $1 in
            --profile) (( $# >= 2 )) || mf_die 'missing profile path' 64; profile=$2; shift 2 ;;
            --pins) (( $# >= 2 )) || mf_die 'missing pins path' 64; pins=$2; shift 2 ;;
            --replace) MF_REPLACE=1; shift ;;
            --allow-dirty) allow_dirty=1; shift ;;
            --expect-rev)
                (( $# >= 2 )) || mf_die 'missing revision' 64
                [[ $2 =~ ^[0-9a-f]{40}$ ]] || mf_die '--expect-rev needs a full 40-character commit hash' 64
                expect_rev=$2; shift 2 ;;
            --dry-run) MF_DRY=1; shift ;;
            *) mf_die 'usage: install-host.sh [--profile FILE] [--pins FILE] [--replace] [--allow-dirty] [--expect-rev SHA] [--dry-run]' 64 ;;
        esac
    done
    MF_SOURCE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
    (( MF_DRY || EUID == 0 )) || mf_die 'run with sudo: sudo bash host/install-host.sh' 77
    mf_check_sources
    mf_source_revision
    printf 'Source: %s\nRevision: %s (uncommitted changes: %s)\n' "$MF_SOURCE" "$MF_REV" "$MF_DIRTY"
    if [[ $MF_DIRTY != no && $allow_dirty != 1 ]]; then
        mf_die 'the source tree is not a clean commit; commit it or pass --allow-dirty'
    fi
    if [[ -n $expect_rev && $MF_REV != "$expect_rev" ]]; then
        mf_die "the checkout is at $MF_REV, not the revision you expected"
    fi
    mf_ensure_user
    mf_ensure_state
    mf_install_tree
    if [[ -n $profile ]]; then
        mf_install_private_file 'profile' "$profile" "$MF_STATE/secrets/wireguard.conf" 16384
    fi
    if [[ -n $pins ]]; then
        mf_install_private_file 'pins file' "$pins" "$MF_STATE/pins/build.pins" 4096
    fi
    if (( ! MF_DRY )); then
        printf 'Installed wrapper sha256: %s\n' "$(sha256sum "$MF_WRAPPER" | cut -d' ' -f1)"
    fi
    printf '%s\n' \
        'The installer ran files from your user-writable checkout as root. Review' \
        'the diff of host/ and lib/ against your last trusted commit before you rely on it.' \
        'Done. Next, as your normal user:' \
        '  sudo mayfly check-profile' \
        '  sudo mayfly doctor' \
        '  sudo mayfly build NAME' \
        '  sudo mayfly launch NAME' \
        'If sudo cannot find the command, use /usr/local/sbin/mayfly.' \
        'Your own copies of the profile and old bases are no longer used; delete them.'
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    mf_install_main "$@"
fi
