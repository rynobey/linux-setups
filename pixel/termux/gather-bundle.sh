#!/usr/bin/env bash
# Gather an offline-recoverable bundle of everything needed to rebuild
# the Pixel Linux setup from scratch, and write it to Android's public
# storage as a single termux-backup tarball.
#
# Runs INSIDE Termux on the Pixel. After this completes, the file at
# $BUNDLE_DEST is a self-contained recovery snapshot:
#
#   - linux-setups repo (this code)
#   - Custom Podroid APK (the 8GB-capable build from your GH Actions)
#   - Latest Podroid LXC backup (encrypted)
#   - Latest Stock Terminal backup (encrypted)
#   - SSH keys you use to reach those VMs
#   - Termux $HOME / $PREFIX dotfiles
#
# Restore on a freshly-wiped phone via:
#   1. Install Termux (sideload from F-Droid)
#   2. termux-restore <path-to-bundle>
#   3. ./linux-setups/pixel/termux/restore-bundle.sh
#
# Prereqs (one-time on this Termux):
#   - termux-setup-storage (gives access to /sdcard via ~/storage/)
#   - pkg install openssh git tar xz-utils termux-tools
#   - SSH keys set up to reach both VMs (or this script's --skip-sync flag
#     will let you bundle without fresh syncs)
#
# Env / flags:
#   --skip-sync       skip pulling fresh VM backups (use existing ones in ~/recovery-bundle)
#   --skip-apk        don't fail if the custom Podroid APK is missing
#   --dest <path>     output bundle path
#                     (default: ~/storage/shared/termux-recovery-<date>.tar.xz)
#
# Env overrides:
#   PODROID_APK       path to the custom Podroid APK to include
#                     (default: $HOME/apks/podroid-debug.apk)
#   PODROID_HOST      hostname for sync-backups.sh --pull (default: pubuntu)
#   PODROID_PORT      port (default: 9922)
#   PODROID_USER      user (default: root)
#   TERMINAL_HOST     hostname for stock-terminal sync (default: stock-terminal)
#   TERMINAL_PORT     port (default: 22)
#   TERMINAL_USER     user (default: droid)

set -euo pipefail

PODROID_APK="${PODROID_APK:-$HOME/apks/podroid-debug.apk}"
PODROID_HOST="${PODROID_HOST:-pubuntu}"
PODROID_PORT="${PODROID_PORT:-9922}"
PODROID_USER="${PODROID_USER:-root}"
TERMINAL_HOST="${TERMINAL_HOST:-stock-terminal}"
TERMINAL_PORT="${TERMINAL_PORT:-22}"
TERMINAL_USER="${TERMINAL_USER:-droid}"

SKIP_SYNC=0
SKIP_APK=0
BUNDLE_DEST=""

while [ $# -gt 0 ]; do
    case "$1" in
        --skip-sync) SKIP_SYNC=1; shift ;;
        --skip-apk)  SKIP_APK=1; shift ;;
        --dest)      BUNDLE_DEST="$2"; shift 2 ;;
        -h|--help)   sed -n '2,40p' "$0"; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done

if [ -z "$BUNDLE_DEST" ]; then
    BUNDLE_DEST="$HOME/storage/shared/termux-recovery-$(date +%F).tar.xz"
fi

log()  { printf '\033[1;34m[gather-bundle]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; }

# ---- prereq sanity ---------------------------------------------------------
if [ ! -d "$HOME/storage" ]; then
    err "~/storage doesn't exist. Run 'termux-setup-storage' first."
    exit 1
fi
if ! command -v termux-backup >/dev/null 2>&1; then
    err "termux-backup not found. Run: pkg install termux-tools"
    exit 1
fi

# ---- 1. refresh linux-setups repo ------------------------------------------
LSDIR="$HOME/linux-setups"
if [ -d "$LSDIR/.git" ]; then
    log "[1/4] git pull on $LSDIR"
    git -C "$LSDIR" pull --quiet --ff-only || warn "git pull failed (offline?), using local copy"
else
    log "[1/4] cloning linux-setups into $LSDIR"
    git clone --quiet https://github.com/rynobey/linux-setups.git "$LSDIR"
fi

# ---- 2. APK check ----------------------------------------------------------
mkdir -p "$HOME/apks"
if [ -f "$PODROID_APK" ]; then
    apk_size=$(du -h "$PODROID_APK" | awk '{print $1}')
    log "[2/4] custom Podroid APK present: $PODROID_APK ($apk_size)"
else
    if [ "$SKIP_APK" -eq 1 ]; then
        warn "[2/4] no APK at $PODROID_APK — bundling without (--skip-apk)"
    else
        err "[2/4] no APK at $PODROID_APK"
        err "      download from your GH Actions build and place it there, or"
        err "      pass --skip-apk to bundle without it."
        exit 1
    fi
fi

# ---- 3. pull latest VM backups ---------------------------------------------
BUNDLE_BACKUPS="$HOME/recovery-bundle"
mkdir -p "$BUNDLE_BACKUPS"

if [ "$SKIP_SYNC" -eq 1 ]; then
    log "[3/4] skipping VM sync (--skip-sync); using existing files in $BUNDLE_BACKUPS"
else
    log "[3/4] pulling Podroid LXC backups → $BUNDLE_BACKUPS"
    LOCAL_DIR="$BUNDLE_BACKUPS" \
        DEV_HOST="$PODROID_HOST" DEV_PORT="$PODROID_PORT" DEV_USER="$PODROID_USER" \
        "$LSDIR/pixel/podroid/sync-backups.sh" --pull \
        || warn "podroid sync failed; using existing files in $BUNDLE_BACKUPS"

    log "[3/4] pulling Stock Terminal backups → $BUNDLE_BACKUPS"
    LOCAL_DIR="$BUNDLE_BACKUPS" \
        DEV_HOST="$TERMINAL_HOST" DEV_PORT="$TERMINAL_PORT" DEV_USER="$TERMINAL_USER" \
        "$LSDIR/pixel/stock-terminal/sync-backups.sh" --pull \
        || warn "stock-terminal sync failed; using existing files in $BUNDLE_BACKUPS"
fi

backup_count=$(find "$BUNDLE_BACKUPS" -maxdepth 1 -type f \
    \( -name '*.tar.gz' -o -name '*.tar.gz.age' \) | wc -l)
log "      $backup_count backup file(s) in $BUNDLE_BACKUPS"

# ---- 4. termux-backup → bundle on /sdcard ----------------------------------
log "[4/4] writing termux-backup → $BUNDLE_DEST"
log "      (this can take a few minutes — bundle includes \$HOME + \$PREFIX)"
mkdir -p "$(dirname "$BUNDLE_DEST")"
termux-backup "$BUNDLE_DEST"

size=$(du -h "$BUNDLE_DEST" | awk '{print $1}')
log "done — $size at $BUNDLE_DEST"
log ""
log "On a freshly-wiped phone, recover with:"
log "  1. Install Termux (sideload from F-Droid)"
log "  2. termux-restore $BUNDLE_DEST   (path will be /sdcard/Download/termux-recovery-...)"
log "  3. ~/linux-setups/pixel/termux/restore-bundle.sh"
