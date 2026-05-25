#!/usr/bin/env bash
# Restore a 'dev' LXC snapshot produced by backup.sh.
#
# Runs ON THE ALPINE HOST inside Podroid, NOT inside the LXC. Reads
# backups from /mnt/shared/podroid-backups/ (Android's
# /sdcard/Download/Podroid/podroid-backups/) — meaning a fresh
# Podroid install with no LXC at all can still restore from here as
# long as a previous backup was made before the Podroid uninstall.
#
# Encrypted backups (.tar.gz.age) prompt for the passphrase the
# backup was written with. Plain .tar.gz backups need no passphrase.
#
# Usage:
#   ./restore.sh                       # interactive: pick from list
#   ./restore.sh --latest              # restore the newest backup, no picker
#   ./restore.sh <path-to-backup>      # restore a specific file
#   ./restore.sh --list                # just list backups (same as backup.sh --list)
#
# Restoring overwrites the current /var/lib/lxc/${LXC_NAME}/ directory.
# By default the script renames the existing LXC to <name>-prev-<ts>
# before unpacking so you can roll back if the restore went sideways.
# Pass --no-keep-prev to skip the rename and delete the existing LXC
# outright.
#
# Env overrides:
#   LXC_NAME       default: dev
#   SHARED_HOST    default: /mnt/shared
#   BACKUP_DIR     default: ${SHARED_HOST}/podroid-backups

set -euo pipefail

LXC_NAME="${LXC_NAME:-dev}"
SHARED_HOST="${SHARED_HOST:-/mnt/shared}"
BACKUP_DIR="${BACKUP_DIR:-${SHARED_HOST}/podroid-backups}"

log()  { printf '\033[1;34m[restore]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; }

# ---- args ------------------------------------------------------------------
PICK_LATEST=0
LIST_ONLY=0
KEEP_PREV=1
BACKUP_FILE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --latest)        PICK_LATEST=1; shift ;;
        --list|-l)       LIST_ONLY=1; shift ;;
        --no-keep-prev)  KEEP_PREV=0; shift ;;
        -h|--help)       sed -n '2,30p' "$0"; exit 0 ;;
        -*)              err "unknown arg: $1"; exit 1 ;;
        *)               BACKUP_FILE="$1"; shift ;;
    esac
done

# ---- enumerate backups -----------------------------------------------------
mapfile -t BACKUPS < <(
    [ -d "$BACKUP_DIR" ] && \
        find "$BACKUP_DIR" -maxdepth 1 -type f \( -name '*.tar.gz' -o -name '*.tar.gz.age' \) 2>/dev/null \
        | sort -r
)

# ---- list mode (or empty dir) ---------------------------------------------
if [ "$LIST_ONLY" -eq 1 ] || [ "${#BACKUPS[@]}" -eq 0 ]; then
    if [ "${#BACKUPS[@]}" -eq 0 ]; then
        log "no backups in $BACKUP_DIR"
        [ "$LIST_ONLY" -eq 1 ] && exit 0 || exit 1
    fi
    log "backups in $BACKUP_DIR (newest first):"
    i=1
    for f in "${BACKUPS[@]}"; do
        size=$(du -h "$f" 2>/dev/null | awk '{print $1}')
        ts=$(stat -c '%y' "$f" 2>/dev/null | cut -d. -f1)
        printf '  [%2d]  %-40s  %6s  %s\n' "$i" "$(basename "$f")" "$size" "$ts"
        i=$((i + 1))
    done
    [ "$LIST_ONLY" -eq 1 ] && exit 0
fi

# ---- pick the backup -------------------------------------------------------
if [ -n "$BACKUP_FILE" ]; then
    # Explicit path — accept absolute or relative-to-BACKUP_DIR.
    if [ ! -f "$BACKUP_FILE" ] && [ -f "${BACKUP_DIR}/${BACKUP_FILE}" ]; then
        BACKUP_FILE="${BACKUP_DIR}/${BACKUP_FILE}"
    fi
    [ -f "$BACKUP_FILE" ] || { err "$BACKUP_FILE not found"; exit 1; }
elif [ "$PICK_LATEST" -eq 1 ]; then
    BACKUP_FILE="${BACKUPS[0]}"
else
    # Interactive picker
    log ""
    read -rp "Pick a backup [1-${#BACKUPS[@]}]: " choice < /dev/tty
    case "$choice" in
        ''|*[!0-9]*) err "not a number"; exit 1 ;;
    esac
    if [ "$choice" -lt 1 ] || [ "$choice" -gt "${#BACKUPS[@]}" ]; then
        err "out of range"; exit 1
    fi
    BACKUP_FILE="${BACKUPS[$((choice - 1))]}"
fi

log "selected: $BACKUP_FILE"
case "$BACKUP_FILE" in
    *.tar.gz.age) ENCRYPTED=1 ;;
    *.tar.gz)     ENCRYPTED=0 ;;
    *) err "unrecognised backup extension"; exit 1 ;;
esac

# ---- confirm --------------------------------------------------------------
if sudo lxc-info -n "$LXC_NAME" -s &>/dev/null; then
    state=$(sudo lxc-info -n "$LXC_NAME" -s | awk '{print $2}')
    if [ "$KEEP_PREV" -eq 1 ]; then
        warn "existing LXC '${LXC_NAME}' (state=$state) will be renamed to <name>-prev-<ts>"
    else
        warn "existing LXC '${LXC_NAME}' (state=$state) will be DELETED"
    fi
    read -rp "continue? [y/N] " ok < /dev/tty
    case "$ok" in y|Y|yes) ;; *) log "aborted"; exit 1 ;; esac
fi

# ---- ensure age if needed --------------------------------------------------
if [ "$ENCRYPTED" -eq 1 ] && ! command -v age >/dev/null 2>&1; then
    log "installing age (apk add age)"
    if command -v apk >/dev/null 2>&1; then
        sudo apk add --no-cache age
    elif command -v apt-get >/dev/null 2>&1; then
        sudo apt-get update -y && sudo apt-get install -y age
    else
        err "no apk/apt-get to install age"
        exit 1
    fi
fi

# ---- stop + move-aside / delete the existing LXC --------------------------
if sudo lxc-info -n "$LXC_NAME" -s &>/dev/null; then
    if sudo lxc-info -n "$LXC_NAME" -s | grep -q RUNNING; then
        log "stopping current '${LXC_NAME}'"
        sudo lxc-stop -n "$LXC_NAME"
    fi
    if [ "$KEEP_PREV" -eq 1 ]; then
        prev_name="${LXC_NAME}-prev-$(date +%F-%H%M)"
        log "preserving current as '${prev_name}'"
        sudo mv "/var/lib/lxc/${LXC_NAME}" "/var/lib/lxc/${prev_name}"
    else
        log "deleting current '${LXC_NAME}'"
        sudo rm -rf "/var/lib/lxc/${LXC_NAME}"
    fi
fi

# ---- stream (age) → tar -xz ------------------------------------------------
log "restoring into /var/lib/lxc/"
if [ "$ENCRYPTED" -eq 1 ]; then
    log "passphrase prompt incoming"
    # age writes to stdout; tar reads from stdin. sudo on tar so the
    # extracted rootfs lands with root ownership.
    age -d "$BACKUP_FILE" | sudo tar -xzpf - -C /var/lib/lxc/
else
    sudo tar -xzpf "$BACKUP_FILE" -C /var/lib/lxc/
fi

# ---- start ----------------------------------------------------------------
log "starting restored '${LXC_NAME}'"
sudo lxc-start -n "$LXC_NAME"
sudo lxc-wait  -n "$LXC_NAME" -s RUNNING -t 30
log "running."
log "attach with: sudo lxc-attach -n ${LXC_NAME}"
if [ "$KEEP_PREV" -eq 1 ]; then
    log "the previous LXC is preserved at /var/lib/lxc/${LXC_NAME}-prev-* —"
    log "delete it with 'sudo rm -rf /var/lib/lxc/${LXC_NAME}-prev-*' once you're satisfied."
fi
