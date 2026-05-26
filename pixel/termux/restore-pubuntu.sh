#!/data/data/com.termux/files/usr/bin/bash
# Restore the pubuntu LXC inside Alpine, remotely from Termux via SSH.
# Thin wrapper around alpine-run.sh + pixel/podroid/restore.sh — the
# actual restore logic lives in podroid/restore.sh; this just streams
# it to Alpine and runs it there.
#
# Usage:
#   bash restore-pubuntu.sh                  # interactive: pick from list
#   bash restore-pubuntu.sh --latest         # restore newest
#   bash restore-pubuntu.sh <alpine-path>    # restore specific tarball
#                                            # (path is ON ALPINE, e.g.
#                                            # /var/lib/podroid-backups/pubuntu-...)
#   bash restore-pubuntu.sh --list           # list backups on Alpine
#
# Encrypted backups prompt for the passphrase used by backup.sh.
# Restoring renames the current LXC to <name>-prev-<ts> so you can
# roll back if something went wrong (pass --no-keep-prev to skip).
#
# Workflow when restoring from a backup that's only in Termux right now:
#   1. Push it to Alpine first:
#        bash ~/linux-setups/pixel/podroid/sync-backups.sh --push
#   2. Then run this script:
#        bash restore-pubuntu.sh --latest
#
# Env overrides forwarded to podroid/restore.sh:
#   LXC_NAME, BACKUP_DIR

set -euo pipefail

LSDIR="${LINUX_SETUPS_DIR:-$HOME/linux-setups}"
exec bash "$LSDIR/pixel/termux/alpine-run.sh" \
    "$LSDIR/pixel/podroid/restore.sh" "$@"
