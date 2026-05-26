#!/usr/bin/env bash
# Create an encrypted LXC backup on Alpine, then sync it down to this
# client. Workflow (a) from pixel/README.md.
#
# Two-step (sequential):
#   1. Stream pixel/podroid/helper/backup.sh to Alpine via SSH; the
#      Alpine-side script snapshots the LXC into /var/lib/podroid-backups/.
#   2. scp the resulting tarball from Alpine to this client's local dir
#      via pixel/podroid/helper/sync-backups.sh --pull.
#
# Run from your CLIENT machine (Termux on Pixel, or any Linux box with
# Tailscale or direct SSH access to Alpine).
#
# Prereqs:
#   - Podroid running with sshd reachable on localhost:9922 (Termux) or
#     pixel:9922 (laptop via Tailscale)
#   - This client's pubkey authorized as root on Alpine
#
# Flags:
#   --plain                 unencrypted backup (no age, no passphrase prompt)
#   --no-pull               just make the backup on Alpine; skip the local pull
#   --local <dir>           where to pull to on this client
#                           (default: ~/recovery-bundle on Termux,
#                                     ~/podroid-backups elsewhere)
#   --delete-after          after a successful pull, remove the Alpine copy
#
# Encrypted backups (default) prompt for an age passphrase. Save it to
# your password manager IMMEDIATELY — if you forget it, the backup is
# unrecoverable.

set -euo pipefail

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helper"
. "$_LIB_DIR/_lib.sh"

NO_PULL=0
PLAIN=0
LOCAL_DIR_OVERRIDE=""
DELETE_AFTER=0
while [ $# -gt 0 ]; do
    case "$1" in
        --plain)        PLAIN=1; shift ;;
        --no-pull)      NO_PULL=1; shift ;;
        --local)        LOCAL_DIR_OVERRIDE="$2"; shift 2 ;;
        --delete-after) DELETE_AFTER=1; shift ;;
        -h|--help)      sed -n '2,30p' "$0"; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done

# ---- 1. backup on Alpine --------------------------------------------------
log "[1/2] creating backup on Alpine"
BACKUP_ARGS=()
[ "$PLAIN" -eq 1 ] && BACKUP_ARGS+=(--plain)
bash "$LSDIR/pixel/client/helper/alpine-run.sh" \
    "$LSDIR/pixel/podroid/helper/backup.sh" "${BACKUP_ARGS[@]}"

# ---- 2. pull to this client -----------------------------------------------
if [ "$NO_PULL" -eq 1 ]; then
    log "[2/2] skipping pull (--no-pull). Backup lives on Alpine in /var/lib/podroid-backups/."
    log "To pull later:"
    log "  bash $LSDIR/pixel/podroid/helper/sync-backups.sh --pull"
    exit 0
fi

log "[2/2] pulling backup(s) from Alpine"
SYNC_ARGS=(--pull)
[ -n "$LOCAL_DIR_OVERRIDE" ] && SYNC_ARGS+=(--local "$LOCAL_DIR_OVERRIDE")
[ "$DELETE_AFTER" -eq 1 ]    && SYNC_ARGS+=(--delete-after)
bash "$LSDIR/pixel/podroid/helper/sync-backups.sh" "${SYNC_ARGS[@]}"

log ""
log "Done. Test the backup decrypts BEFORE doing anything destructive:"
log "  age -d <path-to-backup>.tar.gz.age | head -c 1024 > /dev/null"
log "(an 'incorrect passphrase' here means the file or passphrase is wrong.)"
