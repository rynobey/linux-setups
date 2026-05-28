#!/data/data/com.termux/files/usr/bin/bash
# Restore a proot-distro container from an age-encrypted tarball
# produced by helper/backup-proot.sh. Called by 03-restore-snapshot.sh
# during full snapshot restore, or runnable standalone.
#
# Usage:
#   helper/restore-proot.sh <input-file.tar.gz.age> [distro_name]
#
# What it does:
#   1. Decrypts the file with `age -d` (passphrase prompt).
#   2. Untars into $PREFIX/var/lib/proot-distro/containers/.
#   3. Sanity-checks /usr/bin/bash exists in the restored rootfs.
#   4. Runs `proot-distro login <name> -- /bin/true` to confirm proot
#      can actually exec into it.
#
# Idempotent in the destructive sense: if the target container already
# exists, you'll be asked to confirm before overwrite.
#
# IMPORTANT: do NOT run this if you've migrated Termux installations
# (Play Store ↔ F-Droid, or fresh install ↔ data-cleared install). The
# rootfs files are fine to move, but the surrounding Termux SELinux
# context determines whether proot can exec into them. See the project
# memory `termux-proot-broken-pixel10-android16` for the saga.

set -euo pipefail

if [ "$#" -lt 1 ]; then
    echo "usage: $0 <input-file> [distro_name=ubuntu]" >&2
    exit 1
fi

IN_FILE="$1"
DISTRO="${2:-ubuntu}"

# Determine which proot-distro layout this Termux uses. Prefer v5+ if both
# parents exist (unlikely, but harmless). The backup tarball is restored
# into whichever parent dir matches the install on THIS machine.
CONTAINERS_DIR=""
CONTAINER_DIR=""
if [ -d "$PREFIX/var/lib/proot-distro/containers" ] && \
   ! [ -d "$PREFIX/var/lib/proot-distro/installed-rootfs" ]; then
    CONTAINERS_DIR="$PREFIX/var/lib/proot-distro/containers"
elif [ -d "$PREFIX/var/lib/proot-distro/installed-rootfs" ]; then
    CONTAINERS_DIR="$PREFIX/var/lib/proot-distro/installed-rootfs"
else
    # neither exists yet — make the v4 layout since proot-distro 4.x is what
    # current Termux ships. If we later upgrade to v5+, proot-distro itself
    # would normalize layouts.
    CONTAINERS_DIR="$PREFIX/var/lib/proot-distro/installed-rootfs"
fi
CONTAINER_DIR="$CONTAINERS_DIR/$DISTRO"

# Where the rootfs's bash lives depends on layout:
#   v5+: $CONTAINER_DIR/rootfs/usr/bin/bash
#   v4:  $CONTAINER_DIR/usr/bin/bash
check_bash() {
    [ -x "$CONTAINER_DIR/rootfs/usr/bin/bash" ] || [ -x "$CONTAINER_DIR/usr/bin/bash" ]
}

log()  { printf '\033[1;34m[restore-proot]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; }

# ---- sanity ----------------------------------------------------------------
if [ ! -f "$IN_FILE" ]; then
    err "input file not found: $IN_FILE"
    exit 1
fi
if ! command -v age >/dev/null 2>&1; then
    err "age not installed — pkg install -y age"
    exit 1
fi
if ! command -v proot-distro >/dev/null 2>&1; then
    err "proot-distro not installed — pkg install -y proot-distro"
    exit 1
fi

# ---- 1. overwrite confirmation --------------------------------------------
if [ -d "$CONTAINER_DIR" ]; then
    warn "$DISTRO already exists at $CONTAINER_DIR"
    if [ -t 0 ]; then
        read -r -p "  remove + restore from $IN_FILE? [y/N] " ans
        case "$ans" in y|Y|yes|YES) ;; *) log "aborted by user"; exit 0 ;; esac
    else
        warn "stdin is not a tty — pass FORCE=1 to overwrite non-interactively"
        if [ "${FORCE:-0}" != "1" ]; then exit 1; fi
    fi
    log "removing existing $CONTAINER_DIR"
    proot-distro remove "$DISTRO" 2>/dev/null || rm -rf "$CONTAINER_DIR"
fi

mkdir -p "$CONTAINERS_DIR"

# ---- 2. decrypt + extract --------------------------------------------------
log "decrypting + extracting $IN_FILE → $CONTAINERS_DIR/"
if ! age -d "$IN_FILE" | tar -C "$CONTAINERS_DIR" -xf -; then
    err "decrypt/extract failed"
    rm -rf "$CONTAINER_DIR"
    exit 1
fi

# ---- 3. sanity check the restored rootfs ----------------------------------
if ! check_bash; then
    err "restored rootfs is missing /usr/bin/bash — backup might be corrupt"
    err "    (looked in both $CONTAINER_DIR/rootfs/usr/bin/bash (v5+) and"
    err "    $CONTAINER_DIR/usr/bin/bash (v4))"
    exit 1
fi
log "  rootfs bash present"

# ---- 4. live exec test ----------------------------------------------------
log "running 'proot-distro login $DISTRO -- /bin/true' to confirm exec works"
if proot-distro login "$DISTRO" -- /bin/true 2>&1 | sed 's/^/    /'; then
    log "✓ proot-distro can enter $DISTRO — restore complete"
else
    err "proot-distro can't exec into the restored rootfs."
    err "If you see 'execve(\"/usr/bin/bash\"): No such file or directory',"
    err "this is the Termux+Android-16 SELinux-context issue (memory:"
    err "project_termux_proot_broken_pixel10_android16). Fix: Settings →"
    err "Apps → Termux → Storage → Clear all data, then redo this."
    exit 1
fi
