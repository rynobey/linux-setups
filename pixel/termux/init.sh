#!/usr/bin/env bash
# One-shot initial Termux setup: install every package the rest of
# this dir's scripts depend on, set up shared-storage access, generate
# an SSH key if missing, clone the linux-setups repo.
#
# Run this once on a fresh Termux install:
#   curl -fsSL https://raw.githubusercontent.com/rynobey/linux-setups/master/pixel/termux/init.sh | bash
# (or — if you've already pulled the repo manually — just execute it.)
#
# Idempotent. Re-running is fine; already-installed packages are no-ops,
# the ssh-keygen step skips if a key already exists, the clone step
# skips if the repo's already on disk.

set -euo pipefail

LSDIR="${LSDIR:-$HOME/linux-setups}"
REPO_OWNER="${REPO_OWNER:-rynobey}"
REPO_NAME="${REPO_NAME:-linux-setups}"

log()  { printf '\033[1;34m[init]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; }

# ---- sanity ----------------------------------------------------------------
if ! command -v pkg >/dev/null 2>&1; then
    err "this script must run inside Termux (pkg command not found)."
    exit 1
fi

# ---- 1. update + install packages ------------------------------------------
# Everything we need across all the helper scripts in this dir:
#
#   git              clone/pull linux-setups
#   openssh          ssh, scp, ssh-keygen, sshd  (sync-backups.sh, bootstrap-git.sh)
#   android-tools    adb  (adb-setup.sh — pair/connect to the Pixel ADB)
#   termux-tools     termux-backup / termux-restore / termux-setup-storage
#   termux-api       optional clipboard / notification / share integration
#   curl, wget       download APKs from GH Actions, fetch bootstrap scripts
#   tar, xz-utils    backup compression
#   nano             on-device editor for quick config tweaks
#   coreutils        sha256sum, mktemp, etc. (usually present, ensure it)
#
log "[1/4] updating package index + installing core tools"
pkg update -y
pkg install -y \
    git openssh android-tools termux-tools termux-api \
    curl wget tar xz-utils nano coreutils

# ---- 2. shared-storage access ----------------------------------------------
# Creates ~/storage/ with symlinks to /sdcard/Download, /sdcard/Pictures,
# etc. Requires the user to tap "Allow" on the runtime permission prompt.
# Idempotent — re-running just refreshes the symlinks.
if [ ! -d "$HOME/storage" ]; then
    log "[2/4] requesting shared storage access (tap Allow on the prompt)"
    termux-setup-storage
    # Give the user a moment to interact with the popup; the command
    # returns immediately but the symlinks materialise after they tap.
    sleep 2
    if [ ! -d "$HOME/storage" ]; then
        warn "~/storage still missing — did you tap Allow?"
        warn "you can re-run 'termux-setup-storage' manually later."
    fi
else
    log "[2/4] shared storage already set up at ~/storage"
fi

# ---- 3. SSH key for this Termux instance -----------------------------------
KEY="$HOME/.ssh/id_ed25519"
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
if [ ! -f "$KEY" ]; then
    log "[3/4] generating SSH key at $KEY"
    ssh-keygen -t ed25519 -N "" -C "termux@$(getprop ro.product.model 2>/dev/null || echo pixel)" -f "$KEY"
else
    log "[3/4] SSH key already at $KEY (reusing)"
fi

# ---- 4. clone or update linux-setups ---------------------------------------
if [ -d "$LSDIR/.git" ]; then
    log "[4/4] $LSDIR exists — git pull"
    git -C "$LSDIR" pull --quiet --ff-only \
        || warn "git pull failed (offline?); using local copy"
else
    log "[4/4] cloning ${REPO_OWNER}/${REPO_NAME} into $LSDIR"
    git clone --quiet "https://github.com/${REPO_OWNER}/${REPO_NAME}.git" "$LSDIR"
fi

# ---- done ------------------------------------------------------------------
log ""
log "Termux init complete. Your SSH public key (add to GitHub /"
log "VM authorized_keys as needed):"
echo
cat "$KEY.pub"
echo
log "Next:"
log "  - Make a recovery bundle:  $LSDIR/pixel/termux/gather-bundle.sh"
log "  - After a fresh Termux restore: $LSDIR/pixel/termux/restore-bundle.sh"
log "  - Run device-side ADB config:"
log "      $LSDIR/pixel/podroid/adb-setup.sh"
log "      $LSDIR/pixel/stock-terminal/adb-setup.sh"
log "    (pair ADB first with: adb pair <ip>:<port>)"
