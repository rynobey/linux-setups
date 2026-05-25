#!/usr/bin/env bash
# Restore a Stock Terminal VM snapshot produced by backup.sh.
#
# Runs INSIDE the Stock Terminal Debian VM. Reads backups from
# /var/lib/stock-terminal-backups/ (regular dir on the VM's persistent
# disk). To restore from a backup that's only on your laptop (after
# running sync-backups.sh --pull), use sync-backups.sh --push to copy
# it back to BACKUP_DIR first, then run this script.
#
# Restore flow:
#   1. Pick a backup (interactive picker, --latest, or path arg)
#   2. (If encrypted) prompt for the passphrase
#   3. Untar into / (overwriting current files in the named paths)
#   4. Replay the dpkg package list:  apt install everything that was
#      in the snapshot but isn't here now
#
# This is NOT a full rootfs swap — paths outside what backup.sh tarred
# are left untouched. Cleanest results on a freshly-installed Stock
# Terminal VM that's never been customised.
#
# Usage:
#   ./restore.sh                       # interactive picker
#   ./restore.sh --latest              # newest backup, no picker
#   ./restore.sh <path-to-backup>      # specific file
#   ./restore.sh --list                # same as backup.sh --list
#   ./restore.sh --skip-packages       # untar only; don't replay apt list
#
# Env overrides:
#   BACKUP_DIR      default: /var/lib/stock-terminal-backups

set -euo pipefail

BACKUP_DIR="${BACKUP_DIR:-/var/lib/stock-terminal-backups}"

log()  { printf '\033[1;34m[restore]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; }

warn_not_in_tmux() {
    [ -n "${TMUX:-}" ] && return
    [ "${SKIP_TMUX_CHECK:-0}" = 1 ] && return
    cat <<'EOF' >&2

⚠  Not running inside tmux.

Restore untars + then runs apt-get to install missing packages, which
can take a while. If you're SSH'd in and your connection drops, the
work continues only if you've wrapped it in tmux:

  sudo apt install -y tmux
  tmux new -s restore './restore.sh --latest'

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
SKIP_PACKAGES=0
BACKUP_FILE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --latest)          PICK_LATEST=1; shift ;;
        --list|-l)         LIST_ONLY=1; shift ;;
        --skip-packages)   SKIP_PACKAGES=1; shift ;;
        -h|--help)         sed -n '2,32p' "$0"; exit 0 ;;
        -*)                err "unknown arg: $1"; exit 1 ;;
        *)                 BACKUP_FILE="$1"; shift ;;
    esac
done

# ---- enumerate backups -----------------------------------------------------
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
    if [ ! -f "$BACKUP_FILE" ] && [ -f "${BACKUP_DIR}/${BACKUP_FILE}" ]; then
        BACKUP_FILE="${BACKUP_DIR}/${BACKUP_FILE}"
    fi
    [ -f "$BACKUP_FILE" ] || { err "$BACKUP_FILE not found"; exit 1; }
elif [ "$PICK_LATEST" -eq 1 ]; then
    BACKUP_FILE="${BACKUPS[0]}"
else
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
warn "this will overwrite the files inside the backup's paths"
warn "(your current sway config, dotfiles, /etc/cloud tweaks, etc.)"
read -rp "continue? [y/N] " ok < /dev/tty
case "$ok" in y|Y|yes) ;; *) log "aborted"; exit 1 ;; esac

warn_not_in_tmux

# ---- ensure age if needed --------------------------------------------------
if [ "$ENCRYPTED" -eq 1 ] && ! command -v age >/dev/null 2>&1; then
    log "installing age (apt install age)"
    sudo apt-get update -y
    sudo apt-get install -y age
fi

# ---- stream (age) → tar -xz INTO / -----------------------------------------
# The tarball was created with absolute paths (e.g. /home/droid/...),
# so extracting at / is the correct restore target. tar -P preserves
# the absolute paths instead of stripping leading slashes.
log "restoring into /"
if [ "$ENCRYPTED" -eq 1 ]; then
    log "passphrase prompt incoming"
    age -d "$BACKUP_FILE" | sudo tar -xzpf - -C / -P
else
    sudo tar -xzpf "$BACKUP_FILE" -C / -P
fi

# ---- replay apt package list -----------------------------------------------
PKG_LIST="${HOME}/.terminal-backup-packages.txt"
if [ "$SKIP_PACKAGES" -eq 1 ]; then
    log "skipping package replay (--skip-packages)"
elif [ ! -f "$PKG_LIST" ]; then
    warn "no package list at $PKG_LIST — skipping package replay"
    warn "(was the backup made by a newer backup.sh?)"
else
    log "replaying apt package list from $PKG_LIST"
    log "(this may take a while; tmux is your friend)"
    sudo dpkg --set-selections < "$PKG_LIST"
    sudo apt-get update -y
    sudo apt-get -y dselect-upgrade
fi

log "done."
log "log out and back in (or 'exec \$SHELL') to pick up any new dotfile changes."
