#!/usr/bin/env bash
# Snapshot the Stock Linux Terminal VM's configuration + package set to
# an encrypted tarball on the shared Android storage.
#
# Important design difference vs pixel/podroid/backup.sh:
#   - Podroid's backup tars the WHOLE LXC rootfs from the Alpine host.
#     The Stock Terminal VM's disk image lives in the app's private dir
#     (/data/user/0/com.android.virtualization.terminal/files/), which is
#     unreachable without root.
#   - So this script runs INSIDE the Stock Terminal Debian VM and tars
#     SELECTED paths: $HOME, /root, /etc/sway, /etc/cloud, /etc/foot
#     (configurable via BACKUP_PATHS) plus a dpkg package list. Restore
#     untars + re-installs the package set.
#
# What this means for what survives:
#   ✔ user homedirs (dotfiles, sway/foot/firefox config, project code)
#   ✔ apt package set (the LIST; restore re-installs them, doesn't
#     restore their state)
#   ✔ explicit system config we name in BACKUP_PATHS
#   ✘ the rest of the rootfs (system tweaks outside the named paths,
#     /var data, anything you forgot to add to BACKUP_PATHS)
#
# Backups land under BACKUP_DIR (default /var/lib/terminal-backups/),
# a regular directory on the Stock Terminal Debian's persistent disk.
# Survives VM reboots and Stock Terminal app restarts but NOT a Stock
# Terminal data wipe or app uninstall. For real durability, pull the
# backups out to your laptop / iPad / Termux via sync-backups.sh.
#
# Usage:
#   ./backup.sh                  # encrypted snapshot (default)
#   ./backup.sh --plain          # unencrypted .tar.gz
#   ./backup.sh --list           # show existing backups
#
# Env overrides:
#   BACKUP_PATHS    space-separated list of paths to tar
#                   default: "$HOME /root /etc/sway /etc/foot /etc/cloud /usr/local/bin"
#   BACKUP_DIR      default: /var/lib/stock-terminal-backups
#   BACKUP_PREFIX   default: stock-terminal

set -euo pipefail

DEFAULT_PATHS="$HOME /root /etc/sway /etc/foot /etc/cloud /usr/local/bin"
BACKUP_PATHS="${BACKUP_PATHS:-$DEFAULT_PATHS}"
# Backups land in a regular dir on the Stock Terminal Debian's
# persistent disk. We do NOT write to /mnt/shared (the AVF SharedPath
# from Android) because that share is silently dropped on the current
# Pixel 10 / Android 16 firmware. To get backups OFF the VM onto
# durable storage, run sync-backups.sh from any host with ssh+scp
# (laptop, Termux, iPad). See README.
BACKUP_DIR="${BACKUP_DIR:-/var/lib/stock-terminal-backups}"
# Prefix tagged with origin so files from different VMs landing in the
# same dir on a laptop don't collide (Podroid backups carry the LXC
# name e.g. `pubuntu-...`; Stock Terminal backups are `stock-terminal-...`).
BACKUP_PREFIX="${BACKUP_PREFIX:-stock-terminal}"

log()  { printf '\033[1;34m[backup]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; }

# Long backup ops are less LMK-prone here than on Podroid (the Stock
# Terminal is a privileged system app, not user-space) but if you SSH
# in and your laptop's connection drops, you still want the work to
# survive. Same warning + bypass as the Podroid scripts.
warn_not_in_tmux() {
    [ -n "${TMUX:-}" ] && return
    [ "${SKIP_TMUX_CHECK:-0}" = 1 ] && return
    cat <<'EOF' >&2

⚠  Not running inside tmux.

If you're SSH'd into the Stock Terminal VM from your laptop, a
connection drop during backup will abandon the tar partway through.
Wrap in tmux to make the session resilient:

  sudo apt install -y tmux  # if not already installed
  tmux new -s backup './backup.sh'

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
MODE=backup
ENCRYPT=1
while [ $# -gt 0 ]; do
    case "$1" in
        --plain)   ENCRYPT=0; shift ;;
        --list|-l) MODE=list; shift ;;
        -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
        *) err "unknown arg: $1"; exit 1 ;;
    esac
done

# ---- ensure age available when encrypting ---------------------------------
ensure_age() {
    if command -v age >/dev/null 2>&1; then return; fi
    log "installing age (apt install age)"
    sudo apt-get update -y
    sudo apt-get install -y age
}

# ---- list mode -------------------------------------------------------------
if [ "$MODE" = list ]; then
    if [ ! -d "$BACKUP_DIR" ]; then
        log "no backups yet (dir $BACKUP_DIR doesn't exist)"
        exit 0
    fi
    files=$(find "$BACKUP_DIR" -maxdepth 1 -type f \
        \( -name '*.tar.gz' -o -name '*.tar.gz.age' \) 2>/dev/null | sort -r)
    log "backups in $BACKUP_DIR:"
    if [ -z "$files" ]; then
        log "(none)"
    else
        while IFS= read -r f; do
            size=$(du -h "$f" 2>/dev/null | awk '{print $1}')
            ts=$(stat -c '%y' "$f" 2>/dev/null | cut -d. -f1)
            printf '  %-40s  %6s  %s\n' "$(basename "$f")" "$size" "$ts"
        done <<< "$files"
    fi
    exit 0
fi

# ---- backup mode -----------------------------------------------------------
warn_not_in_tmux

[ "$ENCRYPT" -eq 1 ] && ensure_age
sudo mkdir -p "$BACKUP_DIR"

# Build the list of paths that actually exist (silently skip missing ones).
existing_paths=()
for p in $BACKUP_PATHS; do
    if [ -e "$p" ]; then
        existing_paths+=("$p")
    else
        warn "skipping missing path: $p"
    fi
done
if [ "${#existing_paths[@]}" -eq 0 ]; then
    err "none of BACKUP_PATHS exist; nothing to back up"
    exit 1
fi
log "paths included: ${existing_paths[*]}"

# Capture the dpkg package list to a staging file inside one of the
# included dirs (under $HOME so it always rides along).
PKG_LIST="${HOME}/.terminal-backup-packages.txt"
log "writing package list → ${PKG_LIST}"
dpkg --get-selections > "$PKG_LIST"

stamp="$(date +%F-%H%M)"
if [ "$ENCRYPT" -eq 1 ]; then
    out="${BACKUP_DIR}/${BACKUP_PREFIX}-${stamp}.tar.gz.age"
    log "writing $out"
    log "you'll be prompted for a passphrase — remember it; restore needs the same one"
    sudo tar -czpf - "${existing_paths[@]}" 2>/dev/null | age -p -o "$out"
    sudo chmod 600 "$out"
else
    out="${BACKUP_DIR}/${BACKUP_PREFIX}-${stamp}.tar.gz"
    log "writing $out (UNENCRYPTED)"
    sudo tar -czpf "$out" "${existing_paths[@]}" 2>/dev/null
    sudo chmod 644 "$out"
fi

size=$(du -h "$out" | awk '{print $1}')
log "done — $size"

log "list all backups with:  $0 --list"
