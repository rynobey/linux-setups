#!/data/data/com.termux/files/usr/bin/bash
# Snapshot the pubuntu LXC inside Alpine, remotely from Termux via SSH.
# Thin wrapper around alpine-run.sh + pixel/podroid/backup.sh — the
# actual backup logic lives in podroid/backup.sh; this just streams it
# to Alpine and runs it there.
#
# Usage:
#   bash backup-pubuntu.sh                # encrypted backup (prompts for passphrase)
#   bash backup-pubuntu.sh --plain        # unencrypted .tar.gz (no prompt)
#   bash backup-pubuntu.sh --list         # list existing backups on Alpine
#
# Env overrides forwarded to podroid/backup.sh:
#   LXC_NAME, BACKUP_DIR, BACKUP_PREFIX

set -euo pipefail

LSDIR="${LINUX_SETUPS_DIR:-$HOME/linux-setups}"
exec bash "$LSDIR/pixel/termux/alpine-run.sh" \
    "$LSDIR/pixel/podroid/backup.sh" "$@"
