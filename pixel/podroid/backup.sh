#!/usr/bin/env bash
# Snapshot the 'dev' LXC to a tarball on the shared Android storage.
#
# Runs ON THE ALPINE HOST inside Podroid, NOT inside the LXC. The
# resulting tarball lands under SHARED_HOST (default /mnt/shared/),
# which Podroid maps to /sdcard/Download/Podroid/ on Android — safely
# outside the app sandbox, so it survives a Podroid app data wipe or
# even a Podroid uninstall.
#
# Usage:
#   ./backup.sh           # tarballs the 'dev' LXC
#   LXC_NAME=foo ./backup.sh
#
# To restore (on a fresh Alpine host with the LXC absent):
#   sudo tar -xvpzf /mnt/shared/dev-backup-YYYY-MM-DD.tar.gz -C /var/lib/lxc/
#   sudo lxc-start -n dev

set -euo pipefail

LXC_NAME="${LXC_NAME:-dev}"
SHARED_HOST="${SHARED_HOST:-/mnt/shared}"
BACKUP_PREFIX="${BACKUP_PREFIX:-${LXC_NAME}-backup}"

log()  { printf '\033[1;34m[backup]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; }

if [ ! -d "/var/lib/lxc/${LXC_NAME}" ]; then
    err "LXC '${LXC_NAME}' not found at /var/lib/lxc/${LXC_NAME}"
    exit 1
fi
if [ ! -d "$SHARED_HOST" ]; then
    err "shared dir $SHARED_HOST missing — is Podroid's persistence mount active?"
    exit 1
fi

# ---- stop the container so the rootfs is consistent during tar ------------
was_running=0
if sudo lxc-info -n "$LXC_NAME" -s 2>/dev/null | grep -q RUNNING; then
    was_running=1
    log "stopping LXC '${LXC_NAME}' for a consistent snapshot"
    sudo lxc-stop -n "$LXC_NAME"
fi

# ---- tar ------------------------------------------------------------------
tarball="${SHARED_HOST}/${BACKUP_PREFIX}-$(date +%F-%H%M).tar.gz"
log "writing $tarball"
sudo tar -czpf "$tarball" -C /var/lib/lxc/ "$LXC_NAME"
sudo chmod 644 "$tarball"
size=$(du -h "$tarball" | awk '{print $1}')
log "done — $size"

# ---- restart if we stopped it ---------------------------------------------
if [ "$was_running" -eq 1 ]; then
    log "restarting LXC"
    sudo lxc-start -n "$LXC_NAME"
fi
