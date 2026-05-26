#!/usr/bin/env bash
# Restore an LXC from a backup. Workflow (b) from pixel/README.md.
#
# Handles both scenarios automatically:
#   - LXC doesn't exist yet → calls 05-setup-lxc-fresh.sh first to create
#     the LXC shell + user (without bootstrap), then restores into it.
#   - LXC already exists    → just push backup + restore in place.
#
# Three-step (sequential):
#   1. Ensure LXC exists. If not, call 05-setup-lxc-fresh.sh --no-bootstrap
#      to create + user it (no deps/Tailscale yet — restore brings those
#      back from the backup).
#   2. Push backup from this client to Alpine via sync-backups.sh --push.
#   3. Stream pixel/podroid/helper/restore.sh to Alpine via SSH; it
#      decrypts (prompts for passphrase) + extracts into the LXC.
#
# Run from your CLIENT machine.
#
# Prereqs:
#   - Podroid running, Alpine sshd reachable
#   - Backup tarball in your local dir (~/recovery-bundle on Termux,
#     ~/podroid-backups elsewhere)
#
# Flags:
#   --skip-push          backup is already on Alpine; just restore
#   --skip-create-lxc    don't auto-create LXC if missing; fail instead
#   --latest             restore the newest backup non-interactively
#   --local <dir>        local dir holding the backup (override default)

set -euo pipefail

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helper"
. "$_LIB_DIR/_lib.sh"

SKIP_PUSH=0
SKIP_CREATE=0
LATEST=0
LOCAL_DIR_OVERRIDE=""
PASSTHROUGH=()
while [ $# -gt 0 ]; do
    case "$1" in
        --skip-push)        SKIP_PUSH=1; shift ;;
        --skip-create-lxc)  SKIP_CREATE=1; shift ;;
        --latest)           LATEST=1; PASSTHROUGH+=(--latest); shift ;;
        --local)            LOCAL_DIR_OVERRIDE="$2"; shift 2 ;;
        -h|--help)          sed -n '2,32p' "$0"; exit 0 ;;
        *) PASSTHROUGH+=("$1"); shift ;;
    esac
done

# ---- 1. ensure LXC exists --------------------------------------------------
if lxc_exists "$LXC_NAME"; then
    log "[1/3] LXC '$LXC_NAME' exists on Alpine"
elif [ "$SKIP_CREATE" -eq 1 ]; then
    err "LXC '$LXC_NAME' doesn't exist and --skip-create-lxc was passed."
    err "Run: pixel/client/05-setup-lxc-fresh.sh first."
    exit 1
else
    log "[1/3] LXC '$LXC_NAME' doesn't exist on Alpine — creating it first"
    bash "$LSDIR/pixel/client/05-setup-lxc-fresh.sh" --skip-bootstrap
fi

# ---- 2. push backup to Alpine ---------------------------------------------
if [ "$SKIP_PUSH" -eq 1 ]; then
    log "[2/3] skipping push (--skip-push); assuming backup is already on Alpine"
else
    log "[2/3] pushing local backup to Alpine"
    SYNC_ARGS=(--push)
    [ -n "$LOCAL_DIR_OVERRIDE" ] && SYNC_ARGS+=(--local "$LOCAL_DIR_OVERRIDE")
    bash "$LSDIR/pixel/podroid/helper/sync-backups.sh" "${SYNC_ARGS[@]}"
fi

# ---- 3. restore on Alpine -------------------------------------------------
log "[3/3] restoring LXC from backup (passphrase prompt incoming if encrypted)"
bash "$LSDIR/pixel/client/helper/alpine-run.sh" \
    "$LSDIR/pixel/podroid/helper/restore.sh" "${PASSTHROUGH[@]}"

log ""
log "Done. LXC '$LXC_NAME' restored. If the backup was made on a different"
log "Alpine, you may also want to re-run the bootstrap steps to refresh"
log "host-side state:"
log "  pixel/client/06-bootstrap-ssh-lxc.sh    # SSH + key + authorized_keys"
log "  pixel/client/08-install-tailscale-lxc.sh # re-auth Tailscale on new identity"
