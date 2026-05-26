#!/data/data/com.termux/files/usr/bin/bash
# One-shot initial Termux setup. Six steps:
#
# Shebang note: this is Termux-only — it runs `pkg install`, calls
# termux-setup-storage, etc. Using Termux's bash absolute path means
# `./init.sh` works directly (Termux has no /usr/bin/env so the more
# common `#!/usr/bin/env bash` shebang fails to resolve here).
#   1. install every package the rest of this dir's scripts depend on
#   2. shared-storage access (~/storage → /sdcard symlinks)
#   3. generate this Termux's outbound SSH key (id_ed25519)
#   4. clone the linux-setups repo
#   5. authorize linux-setups/pubkeys/*.pub for incoming SSH (so your
#      other devices on the tailnet/LAN can ssh into this Termux)
#   6. start sshd on port 8022
#
# Run this once on a fresh Termux install:
#   curl -fsSL https://raw.githubusercontent.com/rynobey/linux-setups/master/pixel/termux/init.sh | bash
# (or — if you've already pulled the repo manually — just execute it.)
#
# Idempotent. Re-running is fine; already-installed packages are no-ops,
# ssh-keygen skips if a key already exists, the clone skips if the repo
# is on disk, authorize-pubkeys dedups, sshd is left alone if already
# running.

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
#   termux-tools     termux-setup-storage (still useful; we no longer rely
#                    on termux-backup since it only bundles $PREFIX)
#   termux-api       optional clipboard / notification / share integration
#   curl, wget       download APKs from GH Actions, fetch bootstrap scripts
#   tar, xz-utils    backup compression (xz still useful for incoming
#                    third-party archives, even though our bundles are
#                    plain tar streamed through age)
#   age              passphrase-encrypt the recovery bundle (gather-bundle.sh
#                    + the LXC backup scripts)
#   nano             on-device editor for quick config tweaks
#   coreutils        sha256sum, mktemp, etc. (usually present, ensure it)
#
log "[1/6] updating package index + installing core tools"
pkg update -y
pkg install -y \
    git openssh android-tools termux-tools termux-api \
    curl wget tar xz-utils age nano coreutils

# ---- 2. shared-storage access ----------------------------------------------
# Creates ~/storage/ with symlinks to /sdcard/Download, /sdcard/Pictures,
# etc. Requires the user to tap "Allow" on the runtime permission prompt.
# Idempotent — re-running just refreshes the symlinks.
if [ ! -d "$HOME/storage" ]; then
    log "[2/6] requesting shared storage access (tap Allow on the prompt)"
    termux-setup-storage
    # Give the user a moment to interact with the popup; the command
    # returns immediately but the symlinks materialise after they tap.
    sleep 2
    if [ ! -d "$HOME/storage" ]; then
        warn "~/storage still missing — did you tap Allow?"
        warn "you can re-run 'termux-setup-storage' manually later."
    fi
else
    log "[2/6] shared storage already set up at ~/storage"
fi

# ---- 3. SSH key for this Termux instance -----------------------------------
KEY="$HOME/.ssh/id_ed25519"
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
if [ ! -f "$KEY" ]; then
    log "[3/6] generating SSH key at $KEY"
    ssh-keygen -t ed25519 -N "" -C "termux@$(getprop ro.product.model 2>/dev/null || echo pixel)" -f "$KEY"
else
    log "[3/6] SSH key already at $KEY (reusing)"
fi

# ---- 4. clone or update linux-setups ---------------------------------------
if [ -d "$LSDIR/.git" ]; then
    log "[4/6] $LSDIR exists — git pull"
    git -C "$LSDIR" pull --quiet --ff-only \
        || warn "git pull failed (offline?); using local copy"
else
    log "[4/6] cloning ${REPO_OWNER}/${REPO_NAME} into $LSDIR"
    git clone --quiet "https://github.com/${REPO_OWNER}/${REPO_NAME}.git" "$LSDIR"
fi

# ---- 5. authorize pubkeys from the repo (incoming-SSH access) --------------
# Append every linux-setups/pubkeys/*.pub to ~/.ssh/authorized_keys, so
# any device whose pubkey is in the repo can SSH into this Termux (after
# step 6 starts sshd). Same logic bootstrap-ssh.sh uses on a Linux host,
# but reading from the now-cloned repo instead of curling a tarball.
PUBKEYS_DIR="${PUBKEYS_DIR:-$LSDIR/pubkeys}"
AUTH_FILE="$HOME/.ssh/authorized_keys"
touch "$AUTH_FILE"
chmod 600 "$AUTH_FILE"
added=0
if [ -d "$PUBKEYS_DIR" ]; then
    shopt -s nullglob
    pubs=("$PUBKEYS_DIR"/*.pub)
    shopt -u nullglob
    for pub in "${pubs[@]}"; do
        key_core=$(awk '{print $1" "$2}' "$pub")
        if grep -qF "$key_core" "$AUTH_FILE"; then
            : # already authorized
        else
            cat "$pub" >> "$AUTH_FILE"
            added=$((added + 1))
        fi
    done
    log "[5/6] authorized $added new pubkey(s) from $PUBKEYS_DIR/ in $AUTH_FILE"
else
    warn "[5/6] no pubkeys dir at $PUBKEYS_DIR; skipped authorize step"
fi

# ---- 6. start Termux sshd --------------------------------------------------
# Termux's sshd listens on port 8022 by default. Starting it here makes
# this Termux reachable from other devices on the tailnet (or LAN).
# Termux has no systemd — sshd is just a foreground daemon. Restart it
# manually after Termux is killed/relaunched, or use Termux:Boot
# (separate F-Droid app) for auto-start on phone boot.
if pgrep -x sshd >/dev/null 2>&1; then
    log "[6/6] sshd already running on port 8022"
else
    log "[6/6] starting sshd (port 8022)"
    sshd
    if pgrep -x sshd >/dev/null 2>&1; then
        log "       sshd up. Connect from another device: ssh -p 8022 \$USER@<this-pixel>"
    else
        warn "       sshd didn't start. Try manually: sshd -d  (foreground+verbose)"
    fi
fi

# ---- done ------------------------------------------------------------------
log ""
log "Termux init complete."
log ""
log "Your SSH public key (add to GitHub for git push):"
echo
cat "$KEY.pub"
echo
log "Incoming SSH ready on port 8022 (any pubkey from $PUBKEYS_DIR/ is authorized)."
log "Test from another device on the tailnet:"
log "  ssh -p 8022 \$USER@<pixel-tailscale-name>"
log ""
log "Notes on persistence:"
log "  - sshd dies if Termux is force-stopped or the device reboots."
log "  - For auto-start on boot: install Termux:Boot (F-Droid), drop a"
log "    boot script that runs 'sshd'."
log "  - To restart manually later: just type 'sshd' in any Termux session."
log ""
log "Next:"
log "  - Make a recovery snapshot:  $LSDIR/pixel/termux/gather-bundle.sh"
log "  - After a fresh Termux restore: $LSDIR/pixel/termux/restore-bundle.sh"
log ""
log "  - Tune Android for VM workloads (frees ~3.5 GB by disabling"
log "    AiCore + TTS — separate from Podroid, persists across OTAs):"
log "      adb pair localhost:<pair-port>      (enter 6-digit code first)"
log "      adb connect localhost:<connect-port>"
log "      $LSDIR/pixel/android-pkg-state.sh disable"
log ""
log "  - Install / replace Podroid + apply ADB config:"
log "      $LSDIR/pixel/termux/deploy-podroid.sh"
log "    (uninstalls old Podroid, installs new APK, applies PPK + AVF"
log "     + storage perms — assumes ADB is paired + connected already)"
