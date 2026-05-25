#!/usr/bin/env bash
# After `termux-restore`-ing the bundle made by gather-bundle.sh,
# this script walks you through finishing the recovery: verifies the
# bundle contents are where they're expected, prints the next-step
# commands tailored to what's actually present.
#
# Doesn't automate the sideload/restore steps themselves on purpose —
# those touch other apps (Podroid, Stock Terminal) and the right
# sequence depends on what's still installed vs. what needs sideloading.
# Walking you through it explicitly is safer than guessing.
#
# Run AFTER:
#   1. Fresh Termux install (sideload from F-Droid)
#   2. termux-restore /sdcard/Download/termux-recovery-<date>.tar.xz
#
# Then:
#   ~/linux-setups/pixel/termux/restore-bundle.sh

set -euo pipefail

LSDIR="$HOME/linux-setups"
APK_DIR="$HOME/apks"
BUNDLE_BACKUPS="$HOME/recovery-bundle"

log()   { printf '\033[1;34m[restore-bundle]\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
err()   { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; }
ok()    { printf '\033[1;32m✓\033[0m %s\n' "$*"; }
miss()  { printf '\033[1;31m✗\033[0m %s\n' "$*"; }

# ---- inventory what we have ------------------------------------------------
log "Bundle contents check:"

if [ -d "$LSDIR/.git" ]; then
    ok "linux-setups repo at $LSDIR"
    HAVE_REPO=1
else
    miss "no linux-setups repo at $LSDIR"
    HAVE_REPO=0
fi

shopt -s nullglob
apks=("$APK_DIR"/*.apk)
shopt -u nullglob
if [ "${#apks[@]}" -gt 0 ]; then
    ok "APK(s) at $APK_DIR (${#apks[@]} file(s))"
    for a in "${apks[@]}"; do
        printf '    %s (%s)\n' "$(basename "$a")" "$(du -h "$a" | awk '{print $1}')"
    done
    HAVE_APK=1
else
    miss "no APKs at $APK_DIR"
    HAVE_APK=0
fi

shopt -s nullglob
podroid_backups=("$BUNDLE_BACKUPS"/pubuntu-*.tar.gz "$BUNDLE_BACKUPS"/pubuntu-*.tar.gz.age)
terminal_backups=("$BUNDLE_BACKUPS"/stock-terminal-*.tar.gz "$BUNDLE_BACKUPS"/stock-terminal-*.tar.gz.age)
shopt -u nullglob

if [ "${#podroid_backups[@]}" -gt 0 ]; then
    ok "Podroid LXC backup(s) (${#podroid_backups[@]}):"
    for b in "${podroid_backups[@]}"; do
        printf '    %s\n' "$(basename "$b")"
    done
    HAVE_PODROID_BACKUP=1
else
    miss "no Podroid LXC backups (looked for $BUNDLE_BACKUPS/pubuntu-*)"
    HAVE_PODROID_BACKUP=0
fi

if [ "${#terminal_backups[@]}" -gt 0 ]; then
    ok "Stock Terminal backup(s) (${#terminal_backups[@]}):"
    for b in "${terminal_backups[@]}"; do
        printf '    %s\n' "$(basename "$b")"
    done
    HAVE_TERMINAL_BACKUP=1
else
    miss "no Stock Terminal backups (looked for $BUNDLE_BACKUPS/stock-terminal-*)"
    HAVE_TERMINAL_BACKUP=0
fi

if [ -d "$HOME/.ssh" ] && [ -n "$(ls -A "$HOME/.ssh" 2>/dev/null)" ]; then
    ok "SSH keys at ~/.ssh ($(ls -1 "$HOME/.ssh" | wc -l) entries)"
else
    miss "no SSH keys at ~/.ssh"
fi

echo
log "Next-step recovery commands:"
echo

# ---- next-step playbook ----------------------------------------------------
if [ "$HAVE_APK" -eq 1 ]; then
    echo "  # 1. Sideload Podroid (custom 8GB-capable build):"
    for a in "${apks[@]}"; do
        printf '       termux-open --send %s\n' "$a"
        printf '         (or: pm install -i com.android.shell --user 0 %s — needs ADB-set-up perms)\n' "$a"
    done
    echo
    echo "  # 2. Run the device-side ADB config — needs ADB paired from this Termux:"
    echo "       pkg install -y android-tools"
    echo "       adb pair <pixel-ip>:<pair-port>   (after enabling Wireless debugging)"
    echo "       $LSDIR/pixel/podroid/adb-setup.sh"
    echo "       $LSDIR/pixel/stock-terminal/adb-setup.sh"
    echo
fi

if [ "$HAVE_PODROID_BACKUP" -eq 1 ]; then
    latest_podroid=$(ls -t "${podroid_backups[@]}" | head -1)
    echo "  # 3. Open the new Podroid, set Backend=AVF, RAM=8GB, start VM, then:"
    echo "       LOCAL_DIR=$BUNDLE_BACKUPS \\"
    echo "         $LSDIR/pixel/podroid/sync-backups.sh --push --host pubuntu --port 9922 --user root"
    echo
    echo "  # 4. SSH to Alpine and restore:"
    echo "       ssh root@pubuntu -p 9922 'cd /root/projects/linux-setups && \\"
    echo "         ./pixel/podroid/01-create-lxc.sh && \\"
    echo "         ./pixel/podroid/restore.sh --latest'"
    echo
fi

if [ "$HAVE_TERMINAL_BACKUP" -eq 1 ]; then
    echo "  # 5. Enable Stock Terminal hardware accel (if you haven't):"
    echo "       $LSDIR/pixel/stock-terminal/adb-setup.sh"
    echo
    echo "  # 6. SSH into Stock Terminal Debian (after installing openssh-server"
    echo "       and putting it on Tailscale or otherwise reachable), then push + restore:"
    echo "       LOCAL_DIR=$BUNDLE_BACKUPS \\"
    echo "         $LSDIR/pixel/stock-terminal/sync-backups.sh --push --host stock-terminal --user droid"
    echo "       ssh droid@stock-terminal 'cd ~/linux-setups && \\"
    echo "         ./pixel/stock-terminal/install-gui.sh && \\"
    echo "         ./pixel/stock-terminal/restore.sh --latest'"
    echo
fi

if [ "$HAVE_REPO" -eq 1 ] && [ "$HAVE_APK" -eq 0 ] \
   && [ "$HAVE_PODROID_BACKUP" -eq 0 ] && [ "$HAVE_TERMINAL_BACKUP" -eq 0 ]; then
    warn "bundle looks empty — only the repo survived. Likely you ran"
    warn "gather-bundle.sh with --skip-sync and --skip-apk, or the syncs"
    warn "failed. You can still use the repo to bootstrap fresh."
fi

log "All steps above are idempotent; re-run safely."
