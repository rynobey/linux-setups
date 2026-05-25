#!/usr/bin/env bash
# Restore a 'pubuntu' LXC snapshot produced by backup.sh.
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
#   LXC_NAME       default: pubuntu
#   SHARED_HOST    default: /mnt/shared
#   BACKUP_DIR     default: ${SHARED_HOST}/podroid-backups

set -euo pipefail

LXC_NAME="${LXC_NAME:-pubuntu}"
SHARED_HOST="${SHARED_HOST:-/mnt/shared}"
BACKUP_DIR="${BACKUP_DIR:-${SHARED_HOST}/podroid-backups}"

log()  { printf '\033[1;34m[restore]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; }

# See the matching block in backup.sh for the rationale — long
# extract/decrypt ops trigger Android's LMK against Podroid, taking
# the whole Alpine VM down mid-restore. Wrapping in tmux protects
# against SSH disconnects; the README documents the full mitigation
# stack.
warn_not_in_tmux() {
    [ -n "${TMUX:-}" ] && return
    [ "${SKIP_TMUX_CHECK:-0}" = 1 ] && return
    cat <<'EOF' >&2

⚠  Not running inside tmux.

Long backup/restore ops have been observed to die mid-flight when
Android's LMK reaps Podroid under memory pressure (taking the whole
Alpine VM with it). For multi-GB tarballs you almost certainly want:

  1. Run from Podroid's own terminal app (on the phone), not over SSH
  2. Plug the phone in to charge
  3. Keep the screen on (Settings → Developer options → Stay awake)
  4. Settings → Apps → Podroid → Battery → Unrestricted
  5. Wrap this command in tmux:  apk add tmux && tmux new -s restore './restore.sh ...'

Set SKIP_TMUX_CHECK=1 to suppress this prompt next time.
EOF
    if [ -r /dev/tty ]; then
        read -r -p "Continue anyway? [y/N] " ok < /dev/tty
        case "$ok" in y|Y|yes) ;; *) err "aborted"; exit 1 ;; esac
    else
        err "no terminal to confirm on; export SKIP_TMUX_CHECK=1 if you really mean it"
        exit 1
    fi
}

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
# Use a string + here-string instead of `< <(...)`; process substitution
# requires /dev/fd/<N>, which isn't reliably set up in Podroid's
# minimal Alpine host VM.
if [ -d "$BACKUP_DIR" ]; then
    backups_str=$(find "$BACKUP_DIR" -maxdepth 1 -type f \
        \( -name '*.tar.gz' -o -name '*.tar.gz.age' \) 2>/dev/null | sort -r)
else
    backups_str=""
fi
if [ -n "$backups_str" ]; then
    mapfile -t BACKUPS <<< "$backups_str"
else
    BACKUPS=()
fi

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

# ---- tmux / Android-LMK warning -------------------------------------------
warn_not_in_tmux

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

# ---- stream (age) → tar -xz, with on-the-fly rename if needed --------------
#
# We extract into a staging dir under /var/lib/lxc/ rather than straight
# into /var/lib/lxc/. Two reasons:
#   1. The tarball's top-level dir is whatever the LXC was *originally*
#      called (e.g. "dev"). If the user is restoring it under a
#      different LXC_NAME ("pubuntu"), we need to rename the dir and
#      patch lxc.uts.name / /etc/hostname / /etc/hosts before bringing
#      it up — otherwise lxc-start can't find the container and the
#      in-container shell prompt is still the old name.
#   2. /var/lib/lxc/ is on the same filesystem as the staging dir, so
#      the final `mv` is instant (no extra disk overhead beyond the
#      single extracted rootfs).
staging="/var/lib/lxc/.restore-staging-$$"
sudo mkdir -p "$staging"
trap 'sudo rm -rf "$staging" 2>/dev/null || true' EXIT

log "restoring into staging dir"
if [ "$ENCRYPTED" -eq 1 ]; then
    log "passphrase prompt incoming"
    age -d "$BACKUP_FILE" | sudo tar -xzpf - -C "$staging"
else
    sudo tar -xzpf "$BACKUP_FILE" -C "$staging"
fi

# Identify the LXC dir inside the tarball.
shopt -s nullglob
staged_dirs=("$staging"/*/)
shopt -u nullglob
if [ "${#staged_dirs[@]}" -ne 1 ]; then
    err "expected exactly one top-level LXC dir in the tarball, found ${#staged_dirs[@]}"
    exit 1
fi
staged="${staged_dirs[0]%/}"
original_name="$(basename "$staged")"
log "tarball contained LXC '$original_name'"

# If we're restoring under a different name, patch the bits of state
# that bake the name in. Best-effort on the rootfs files — missing
# /etc/hosts or /etc/hostname inside the rootfs aren't fatal, the LXC
# will still start.
if [ "$original_name" != "$LXC_NAME" ]; then
    log "renaming on restore: '$original_name' → '${LXC_NAME}'"
    config="$staged/config"
    if [ -f "$config" ]; then
        sudo sed -i -E "s|^([[:space:]]*lxc\.uts\.name[[:space:]]*=).*|\1 ${LXC_NAME}|" "$config"
        sudo sed -i "s|/var/lib/lxc/${original_name}/|/var/lib/lxc/${LXC_NAME}/|g" "$config"
    fi
    if [ -f "$staged/rootfs/etc/hostname" ]; then
        echo "${LXC_NAME}" | sudo tee "$staged/rootfs/etc/hostname" >/dev/null
    fi
    if [ -f "$staged/rootfs/etc/hosts" ]; then
        sudo sed -i "s|^\(127\.0\.1\.1[[:space:]]\+\)${original_name}\b|\1${LXC_NAME}|" "$staged/rootfs/etc/hosts"
    fi
fi

# Move into final location.
sudo mv "$staged" "/var/lib/lxc/${LXC_NAME}"
sudo rm -rf "$staging"
trap - EXIT

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
