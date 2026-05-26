#!/data/data/com.termux/files/usr/bin/bash
# Create a full offline-recoverable snapshot of this Termux + the Pixel
# Linux setup, and write it to /sdcard/Download. On a fresh phone, the
# snapshot lets you fully restore in two commands (see Restore below).
#
# Artifacts written to ~/storage/shared/Download/ (== /sdcard/Download/):
#
#   termux-prefix-<date>.tar.xz     — $PREFIX backup via termux-backup.
#                                     Restores all installed Termux packages
#                                     (including age, openssh, etc.) in
#                                     one shot. NOT encrypted — it's just
#                                     public package state, no secrets.
#
#   pixel-home-<date>.tar.age       — Full $HOME tarball, age-encrypted
#                                     with a passphrase you provide. Excludes
#                                     $HOME/storage (the SAF symlinks —
#                                     they'd be broken on restore, and
#                                     termux-setup-storage recreates them).
#                                     This is where your SSH keys, LXC
#                                     backups, APKs, and the linux-setups
#                                     repo live, hence the encryption.
#
#   03-restore-snapshot.sh                  — Self-contained recovery script (copy
#                                     of pixel/termux/03-restore-snapshot.sh from
#                                     the repo). Placed on /sdcard so it
#                                     survives Termux uninstall.
#
# Restore on a freshly-wiped phone:
#   1. Install Termux (sideload from F-Droid)
#   2. termux-setup-storage                                   (tap Allow)
#   3. bash ~/storage/shared/Download/03-restore-snapshot.sh
#
# the snapshot restore script restores $PREFIX first (which brings in age + tar +
# openssh), then decrypts and extracts $HOME. After that, $HOME contains
# the linux-setups repo so you can run pixel/client/04-restore-lxc.sh
# to push the LXC backup back and restore the VM.
#
# Why this is split into THREE files rather than one mega-tarball: the
# offline-recovery script needs age to decrypt the HOME tar, but age
# isn't in a fresh Termux. termux-restore of $PREFIX is the bootstrap
# layer that brings age into the system before HOME extraction.
#
# Why we DON'T put $HOME inside the termux-backup tarball: termux-backup
# is hardcoded to back up ONLY $PREFIX (see its own header) — that's a
# deliberate design choice in termux-tools. We tar $HOME manually.
#
# Why we DON'T xz-compress the HOME tar: the bulk content (LXC backup +
# APK) is already compressed/encrypted, so xz burns CPU for no size
# reduction. Plain tar streamed through age is the minimum-overhead path.
#
# Prereqs (one-time on this Termux):
#   - termux-setup-storage     (gives ~/storage/shared → /sdcard)
#   - pkg install openssh git tar age termux-tools
#   - SSH keys set up to reach the Podroid LXC (or use --skip-sync)
#
# Env / flags:
#   --skip-sync                 skip the LXC backup + sync stage entirely
#                               (use existing files in ~/recovery-bundle/)
#   --skip-fresh-backup         don't trigger a NEW Podroid LXC backup —
#                               just pull whatever's already on Alpine.
#                               (Faster, but only useful if you JUST made
#                               a backup. Default is to create a fresh one.)
#   --skip-apk                  don't fail if the custom Podroid APK is missing
#   --include-stock-terminal    also sync Stock Terminal VM backups
#                               (off by default since you may not have it set up)
#   --skip-prefix               skip the termux-backup of $PREFIX
#                               (smaller snapshot but no offline package restore)
#   --skip-home                 skip the $HOME tarball (PREFIX only)
#   --dest-dir <path>           output directory on /sdcard (default:
#                               ~/storage/shared/Download)
#
# Env overrides:
#   PODROID_APK       path to the custom Podroid APK to include
#                     (default: $HOME/apks/podroid-debug.apk)
#   PODROID_HOST      hostname for sync-backups.sh --pull
#                     (default: localhost on Termux, pixel elsewhere)
#   PODROID_PORT      port (default: 9922)
#   PODROID_USER      user (default: root)
#   TERMINAL_HOST     hostname for stock-terminal sync (default: stock-terminal)
#   TERMINAL_PORT     port (default: 22)
#   TERMINAL_USER     user (default: droid)

set -euo pipefail

PODROID_APK="${PODROID_APK:-$HOME/apks/podroid-debug.apk}"

# When running this script in Termux on the same Pixel that hosts Podroid,
# localhost reaches Alpine via Podroid's port forward (9922). When running
# elsewhere (laptop on the tailnet), 'pixel' is the Pixel's Tailscale name.
# Tailscale hairpin to one's own node is unreliable, so localhost is the
# safe default on Termux.
#
# Don't default to 'pubuntu' — that's the LXC's Tailscale name, not
# Alpine's. The backups live on Alpine's /var/lib/podroid-backups/, not
# inside the LXC.
if [ -n "${PREFIX:-}" ] && [ -x "${PREFIX}/bin/pkg" ]; then
    PODROID_HOST_DEFAULT="localhost"
else
    PODROID_HOST_DEFAULT="pixel"
fi
PODROID_HOST="${PODROID_HOST:-$PODROID_HOST_DEFAULT}"
PODROID_PORT="${PODROID_PORT:-9922}"
PODROID_USER="${PODROID_USER:-root}"
TERMINAL_HOST="${TERMINAL_HOST:-stock-terminal}"
TERMINAL_PORT="${TERMINAL_PORT:-22}"
TERMINAL_USER="${TERMINAL_USER:-droid}"

SKIP_SYNC=0
SKIP_APK=0
SKIP_PREFIX=0
SKIP_HOME=0
SKIP_FRESH_BACKUP=0
INCLUDE_STOCK_TERMINAL=0
DEST_DIR=""

while [ $# -gt 0 ]; do
    case "$1" in
        --skip-sync)              SKIP_SYNC=1; shift ;;
        --skip-apk)               SKIP_APK=1; shift ;;
        --skip-prefix)            SKIP_PREFIX=1; shift ;;
        --skip-home)              SKIP_HOME=1; shift ;;
        --skip-fresh-backup)      SKIP_FRESH_BACKUP=1; shift ;;
        --include-stock-terminal) INCLUDE_STOCK_TERMINAL=1; shift ;;
        --dest-dir)               DEST_DIR="$2"; shift 2 ;;
        -h|--help)                sed -n '2,78p' "$0"; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done

if [ -z "$DEST_DIR" ]; then
    DEST_DIR="$HOME/storage/shared/Download"
fi

# YYYY-MM-DD-HHMM so consecutive same-day runs produce distinct files.
# termux-backup refuses to overwrite without --force, so a same-name
# collision aborts the snapshot mid-flight — using minute-resolution
# in the filename sidesteps that entirely.
DATE_TAG=$(date +%F-%H%M)
PREFIX_DEST="$DEST_DIR/termux-prefix-$DATE_TAG.tar.xz"
HOME_DEST="$DEST_DIR/pixel-home-$DATE_TAG.tar.age"
RESTORE_SCRIPT_DEST="$DEST_DIR/03-restore-snapshot.sh"

log()  { printf '\033[1;34m[snapshot]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; }

# ---- prereq sanity ---------------------------------------------------------
if [ ! -d "$HOME/storage" ]; then
    err "~/storage doesn't exist. Run 'termux-setup-storage' first."
    exit 1
fi
if [ "$SKIP_HOME" -eq 0 ]; then
    if ! command -v age >/dev/null 2>&1; then
        log "age not found — installing (one-time)"
        pkg install -y age
    fi
    if ! command -v age >/dev/null 2>&1; then
        err "age still not available after install. Try: pkg install -y age"
        exit 1
    fi
fi
if [ "$SKIP_PREFIX" -eq 0 ]; then
    if ! command -v termux-backup >/dev/null 2>&1; then
        err "termux-backup not found. Run: pkg install -y termux-tools"
        exit 1
    fi
fi

mkdir -p "$DEST_DIR"

# ---- 1. refresh linux-setups repo ------------------------------------------
LSDIR="$HOME/linux-setups"
if [ -d "$LSDIR/.git" ]; then
    log "[1/6] git pull on $LSDIR"
    git -C "$LSDIR" pull --quiet --ff-only \
        || warn "git pull failed (offline?), using local copy"
else
    log "[1/6] cloning linux-setups into $LSDIR"
    git clone --quiet https://github.com/rynobey/linux-setups.git "$LSDIR"
fi

# ---- 2. APK check ----------------------------------------------------------
mkdir -p "$HOME/apks"
if [ -f "$PODROID_APK" ]; then
    apk_size=$(du -h "$PODROID_APK" | awk '{print $1}')
    log "[2/6] custom Podroid APK present: $PODROID_APK ($apk_size)"
else
    if [ "$SKIP_APK" -eq 1 ]; then
        warn "[2/6] no APK at $PODROID_APK — bundling without (--skip-apk)"
    else
        err "[2/6] no APK at $PODROID_APK"
        err "      download from your GH Actions build and place it there, or"
        err "      pass --skip-apk to bundle without it."
        exit 1
    fi
fi

# ---- 3. pull latest VM backups ---------------------------------------------
BUNDLE_BACKUPS="$HOME/recovery-bundle"
mkdir -p "$BUNDLE_BACKUPS"

if [ "$SKIP_SYNC" -eq 1 ]; then
    log "[3/6] skipping VM backup + sync (--skip-sync); using existing files in $BUNDLE_BACKUPS"
elif [ "$SKIP_FRESH_BACKUP" -eq 1 ]; then
    log "[3/6] --skip-fresh-backup: pulling EXISTING Podroid LXC backups → $BUNDLE_BACKUPS"
    # Sync only, don't trigger a new backup on Alpine.
    LOCAL_DIR="$BUNDLE_BACKUPS" \
        DEV_HOST="$PODROID_HOST" DEV_PORT="$PODROID_PORT" DEV_USER="$PODROID_USER" \
        bash "$LSDIR/pixel/podroid/helper/sync-backups.sh" --pull \
        || warn "podroid sync failed; using existing files in $BUNDLE_BACKUPS"
else
    log "[3/6] creating FRESH Podroid LXC backup + syncing → $BUNDLE_BACKUPS"
    log "       (passphrase prompt incoming — pick something you'll remember)"
    # Delegate to client/03-backup-lxc.sh which does the full
    # backup-on-Alpine + sync-to-client flow. ALPINE_* env vars are how
    # the client/ scripts know which Alpine to talk to; we forward our
    # PODROID_* defaults so 02-snapshot.sh's existing env overrides
    # still work.
    ALPINE_HOST="$PODROID_HOST" ALPINE_PORT="$PODROID_PORT" ALPINE_USER="$PODROID_USER" \
        bash "$LSDIR/pixel/client/03-backup-lxc.sh" \
            --local "$BUNDLE_BACKUPS" \
        || warn "podroid backup+sync failed; falling back to existing files in $BUNDLE_BACKUPS"
fi

# Stock Terminal — separate from the Podroid flow above. Always sync-only
# (no fresh backup wrapper for the Stock Terminal yet); enable via flag.
if [ "$SKIP_SYNC" -eq 0 ] && [ "$INCLUDE_STOCK_TERMINAL" -eq 1 ]; then
    log "[3/6] pulling Stock Terminal backups → $BUNDLE_BACKUPS"
    LOCAL_DIR="$BUNDLE_BACKUPS" \
        DEV_HOST="$TERMINAL_HOST" DEV_PORT="$TERMINAL_PORT" DEV_USER="$TERMINAL_USER" \
        bash "$LSDIR/pixel/stock-terminal/sync-backups.sh" --pull \
        || warn "stock-terminal sync failed; using existing files in $BUNDLE_BACKUPS"
elif [ "$SKIP_SYNC" -eq 0 ] && [ "$INCLUDE_STOCK_TERMINAL" -eq 0 ]; then
    log "[3/6]       skipping Stock Terminal (pass --include-stock-terminal to enable)"
fi

backup_count=$(find "$BUNDLE_BACKUPS" -maxdepth 1 -type f \
    \( -name '*.tar.gz' -o -name '*.tar.gz.age' \) | wc -l)
log "      $backup_count backup file(s) in $BUNDLE_BACKUPS"

# ---- 4. $PREFIX backup via termux-backup -----------------------------------
if [ "$SKIP_PREFIX" -eq 1 ]; then
    log "[4/6] skipping \$PREFIX backup (--skip-prefix)"
else
    log "[4/6] writing \$PREFIX backup → $PREFIX_DEST"
    log "      (this is what the snapshot restore script restores first, to bring age + ssh"
    log "       + other tools into a fresh Termux before \$HOME decryption)"
    termux-backup "$PREFIX_DEST"
    prefix_size=$(du -h "$PREFIX_DEST" | awk '{print $1}')
    log "      \$PREFIX backup: $prefix_size at $PREFIX_DEST"
fi

# ---- 5. full $HOME → age-encrypted tarball on /sdcard ----------------------
if [ "$SKIP_HOME" -eq 1 ]; then
    log "[5/6] skipping \$HOME backup (--skip-home)"
else
    log "[5/6] writing encrypted \$HOME backup → $HOME_DEST"
    log "      excluding: storage/ (broken SAF symlinks; recreated by termux-setup-storage)"
    log "      age will prompt for a passphrase — pick something you'll remember;"
    log "      you'll need it again to decrypt on the recovery side."

    # Full $HOME with two structural excludes:
    #   storage/                — SAF symlink dir, recreated on restore
    #   storage/shared/Download/pixel-home-*.tar.age — paranoia; would already
    #                              be excluded by the storage/ rule, but listed
    #                              explicitly in case someone re-routes $DEST_DIR
    # Plain tar (no compression) → age -p (passphrase encrypt). Streamed,
    # so memory footprint is small even for multi-GB inputs.
    if ! tar cf - -C "$HOME" \
            --exclude='./storage' \
            --exclude='./storage/*' \
            . \
        | age -p -o "$HOME_DEST"; then
        err "HOME bundle creation failed — partial file at $HOME_DEST removed"
        rm -f "$HOME_DEST"
        exit 1
    fi
    home_size=$(du -h "$HOME_DEST" | awk '{print $1}')
    log "      \$HOME bundle: $home_size at $HOME_DEST"

    # ---- 5b. test-decrypt verification ----------------------------------
    # age -p's "type passphrase twice to confirm" catches single-keystroke
    # typos but NOT consistent ones (typing the same wrong passphrase
    # twice passes the confirm check). The only thing that proves the
    # backup is recoverable is an actual decrypt attempt. Prompts the
    # user a THIRD time for the same passphrase and verifies age can
    # decrypt the first 4 KB. If it can't, deletes the unreadable file
    # so a future restore doesn't waste time on a doomed artifact.
    log ""
    log "      verifying \$HOME bundle decrypts — enter the SAME passphrase ONCE MORE"
    bytes=$(age -d "$HOME_DEST" 2>/dev/null | head -c 4096 | wc -c | tr -d ' ')
    if [ "${bytes:-0}" -gt 0 ]; then
        log "      ✓ passphrase verified ($bytes bytes test-decrypted)"
    else
        err "      ✗ DECRYPT FAILED — your passphrase doesn't match the file."
        err "      Removing unreadable file: $HOME_DEST"
        rm -f "$HOME_DEST"
        exit 1
    fi
fi

# ---- 6. drop the 03-restore-snapshot.sh script next to the artifacts ---------------
RESTORE_SCRIPT_SRC="$LSDIR/pixel/termux/03-restore-snapshot.sh"
if [ -f "$RESTORE_SCRIPT_SRC" ]; then
    log "[6/6] copying 03-restore-snapshot.sh → $RESTORE_SCRIPT_DEST"
    cp "$RESTORE_SCRIPT_SRC" "$RESTORE_SCRIPT_DEST"
else
    warn "[6/6] $RESTORE_SCRIPT_SRC not found — 03-restore-snapshot.sh NOT copied."
    warn "      on the recovery side you'd need to clone linux-setups first."
fi

# ---- summary + verification hints ------------------------------------------
log ""
log "Snapshot complete. Artifacts in $DEST_DIR/:"
[ "$SKIP_PREFIX" -eq 0 ] && log "    $(basename "$PREFIX_DEST")  ($prefix_size)"
[ "$SKIP_HOME"   -eq 0 ] && log "    $(basename "$HOME_DEST")  ($home_size)"
[ -f "$RESTORE_SCRIPT_DEST" ] && log "    $(basename "$RESTORE_SCRIPT_DEST")"
log ""
if [ "$SKIP_HOME" -eq 0 ]; then
    log "Verify decryption now (sanity check; you'll be re-prompted for the passphrase):"
    log "  age -d $HOME_DEST | tar tf - | head"
    log ""
fi
log "Restore on a freshly-wiped phone:"
log "  1. Install Termux (sideload from F-Droid)"
log "  2. termux-setup-storage   (tap Allow on the popup)"
log "  3. bash ~/storage/shared/Download/03-restore-snapshot.sh"
