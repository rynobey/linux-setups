#!/data/data/com.termux/files/usr/bin/bash
# Tar + age-encrypt a proot-distro container (rootfs + manifest + sysdata)
# into a single restorable artifact. Designed to be called from
# 02-snapshot.sh as one step in the larger snapshot, OR run standalone.
#
# Why we tar the container dir directly instead of using
# `proot-distro backup`:
#   - It captures the manifest.json + sysdata/ alongside the rootfs, so
#     `proot-distro list` shows the container immediately after restore.
#   - It's a streamable pipeline (tar | age), so the only on-disk copy
#     is the encrypted file — no plaintext intermediate.
#   - proot-distro's own backup/restore commands have varied across
#     versions; this is version-agnostic.
#
# The restore counterpart is in helper/restore-proot.sh.
#
# Usage:
#   helper/backup-proot.sh <output-path.tar.gz.age> [distro_name]
#
# Example:
#   helper/backup-proot.sh ~/storage/shared/Download/proot-ubuntu-2026-05-28-1430.tar.gz.age ubuntu
#
# Encryption: age -p (passphrase). On first run age will prompt twice
# (initial passphrase + verify). 02-snapshot.sh runs a follow-up
# test-decrypt to catch typos before destroying any source.

set -euo pipefail

if [ "$#" -lt 1 ]; then
    echo "usage: $0 <output-file> [distro_name=ubuntu]" >&2
    exit 1
fi

OUT_FILE="$1"
DISTRO="${2:-ubuntu}"

# proot-distro v4 uses installed-rootfs/<name>/; v5+ uses containers/<name>/rootfs.
# Auto-detect the layout this Termux happens to have.
CONTAINERS_DIR=""
CONTAINER_DIR=""
BASH_PATH=""
for parent in \
    "$PREFIX/var/lib/proot-distro/containers" \
    "$PREFIX/var/lib/proot-distro/installed-rootfs"; do
    if [ -d "$parent/$DISTRO" ]; then
        CONTAINERS_DIR="$parent"
        CONTAINER_DIR="$parent/$DISTRO"
        # bash sits one dir deeper in v5+ (under rootfs/), at the top in v4
        if [ -x "$CONTAINER_DIR/rootfs/usr/bin/bash" ]; then
            BASH_PATH="$CONTAINER_DIR/rootfs/usr/bin/bash"
        elif [ -x "$CONTAINER_DIR/usr/bin/bash" ]; then
            BASH_PATH="$CONTAINER_DIR/usr/bin/bash"
        fi
        break
    fi
done

log()  { printf '\033[1;34m[backup-proot]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; }

# ---- sanity ----------------------------------------------------------------
if [ -z "$CONTAINER_DIR" ]; then
    err "no proot-distro container '$DISTRO' found in either layout:"
    err "    $PREFIX/var/lib/proot-distro/containers/$DISTRO       (v5+)"
    err "    $PREFIX/var/lib/proot-distro/installed-rootfs/$DISTRO  (v4)"
    err "    install one first: proot-distro install $DISTRO"
    exit 1
fi
if [ -z "$BASH_PATH" ]; then
    err "rootfs at $CONTAINER_DIR is missing /usr/bin/bash — looks broken"
    exit 1
fi
if ! command -v age >/dev/null 2>&1; then
    err "age not installed — pkg install -y age"
    exit 1
fi

mkdir -p "$(dirname "$OUT_FILE")"

# Approximate the un-tarred size for a hint to the user.
rootfs_size=$(du -sh "$CONTAINER_DIR" 2>/dev/null | awk '{print $1}')
log "tarring $DISTRO ($rootfs_size on disk) → age → $OUT_FILE"
log "    age will prompt for a passphrase (use the same one as for pixel-home if you want a single one to remember)"

# Stream: tar produces the container dir into stdout → age encrypts to disk.
# -C with the parent dir means the archive contains 'ubuntu/...' relative
# paths — clean restore via `tar -C parent -xf -`.
if ! tar -C "$CONTAINERS_DIR" -cf - "$DISTRO" \
        | age -p -o "$OUT_FILE"; then
    err "backup pipeline failed — partial file at $OUT_FILE removed"
    rm -f "$OUT_FILE"
    exit 1
fi

out_size=$(du -h "$OUT_FILE" | awk '{print $1}')
log "wrote $out_size at $OUT_FILE"

# Test-decrypt: catch a wrong-passphrase typo NOW, not on the day you need it.
# Same approach as 02-snapshot.sh's $HOME verification.
log ""
log "verifying — enter the SAME passphrase once more"
if age -d "$OUT_FILE" > /dev/null; then
    log "✓ passphrase verified — proot backup is recoverable"
else
    err "✗ DECRYPT TEST FAILED."
    err "The bundle at $OUT_FILE may not be recoverable."
    err "Re-verify manually:  age -d $OUT_FILE > /dev/null"
    exit 1
fi
