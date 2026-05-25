#!/usr/bin/env bash
# Snapshot the 'pubuntu' LXC to an encrypted tarball on the shared
# Android storage. Runs ON THE ALPINE HOST inside Podroid, NOT inside
# the LXC.
#
# Backups land under SHARED_HOST/podroid-backups/ (default /mnt/shared/
# podroid-backups/), which Podroid maps to /sdcard/Download/Podroid/
# podroid-backups/ on Android — safely outside the app sandbox, so the
# backups survive a Podroid app data wipe or full uninstall.
#
# Filenames carry a timestamp so multiple snapshots accumulate. Use
# --list to see what you have and restore.sh to roll back to any of
# them.
#
# Encryption: backups are encrypted by default with `age -p` (passphrase
# mode — scrypt KDF + ChaCha20-Poly1305). Reading them back later via
# restore.sh will prompt for the same passphrase. Pass --plain to skip
# encryption (the tarball is then just .tar.gz, no extension change).
#
# Usage:
#   ./backup.sh                  # snapshot 'pubuntu' LXC, prompt for passphrase
#   ./backup.sh --plain          # unencrypted .tar.gz (no passphrase)
#   ./backup.sh --list           # list existing backups
#   LXC_NAME=foo ./backup.sh     # snapshot a different LXC
#
# Env overrides:
#   LXC_NAME       default: pubuntu
#   SHARED_HOST    default: /mnt/shared
#   BACKUP_DIR     default: ${SHARED_HOST}/podroid-backups
#   BACKUP_PREFIX  default: ${LXC_NAME}

set -euo pipefail

LXC_NAME="${LXC_NAME:-pubuntu}"
SHARED_HOST="${SHARED_HOST:-/mnt/shared}"
BACKUP_DIR="${BACKUP_DIR:-${SHARED_HOST}/podroid-backups}"
BACKUP_PREFIX="${BACKUP_PREFIX:-${LXC_NAME}}"

log()  { printf '\033[1;34m[backup]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; }

# Backups of a multi-GB rootfs take long enough for Android's Low-Memory
# Killer to reap Podroid while it's backgrounded — which kills the
# whole Alpine VM, the tmux session, and any SSH connection running
# in it. Running inside tmux protects against the SSH disconnect; the
# other items (screen on, charge, unrestricted battery, run from
# Podroid's own terminal) are what protect against Podroid itself
# being killed. See pixel/podroid/README.md for the full checklist.
warn_not_in_tmux() {
    [ -n "${TMUX:-}" ] && return  # already in tmux, all good
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
  5. Wrap this command in tmux:  apk add tmux && tmux new -s backup './backup.sh ...'

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
        -h|--help)
            sed -n '2,30p' "$0"
            exit 0
            ;;
        *) err "unknown arg: $1"; exit 1 ;;
    esac
done

# ---- ensure age is available when encrypting -------------------------------
ensure_age() {
    if command -v age >/dev/null 2>&1; then return; fi
    log "installing age (apk add age)"
    if command -v apk >/dev/null 2>&1; then
        sudo apk add --no-cache age
    elif command -v apt-get >/dev/null 2>&1; then
        sudo apt-get update -y && sudo apt-get install -y age
    else
        err "no apk/apt-get to install age; install manually or use --plain"
        exit 1
    fi
}

# ---- list mode -------------------------------------------------------------
if [ "$MODE" = list ]; then
    if [ ! -d "$BACKUP_DIR" ]; then
        log "no backups yet (dir $BACKUP_DIR doesn't exist)"
        exit 0
    fi
    # Capture into a string first instead of using `< <(...)`, which
    # needs /dev/fd/<N> to be valid — not the case in minimal Alpine
    # environments like Podroid's host VM.
    files=$(find "$BACKUP_DIR" -maxdepth 1 -type f \
        \( -name '*.tar.gz' -o -name '*.tar.gz.age' \) 2>/dev/null | sort -r)
    log "backups in $BACKUP_DIR:"
    if [ -z "$files" ]; then
        log "(none)"
    else
        # Sort newest-first, show size + age. Both encrypted (.age) and
        # plain (.tar.gz) shown.
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

if [ ! -d "/var/lib/lxc/${LXC_NAME}" ]; then
    err "LXC '${LXC_NAME}' not found at /var/lib/lxc/${LXC_NAME}"
    exit 1
fi
if [ ! -d "$SHARED_HOST" ]; then
    err "shared dir $SHARED_HOST missing — is Podroid's persistence mount active?"
    exit 1
fi

[ "$ENCRYPT" -eq 1 ] && ensure_age
sudo mkdir -p "$BACKUP_DIR"

# ---- stop the container so the rootfs is consistent during tar ------------
was_running=0
if sudo lxc-info -n "$LXC_NAME" -s 2>/dev/null | grep -q RUNNING; then
    was_running=1
    log "stopping LXC '${LXC_NAME}' for a consistent snapshot"
    sudo lxc-stop -n "$LXC_NAME"
fi

# ---- stream tar → (age) → output -------------------------------------------
stamp="$(date +%F-%H%M)"
if [ "$ENCRYPT" -eq 1 ]; then
    out="${BACKUP_DIR}/${BACKUP_PREFIX}-${stamp}.tar.gz.age"
    log "writing $out"
    log "you'll be prompted for a passphrase — remember it; restore needs the same one"
    # tar to stdout, gzip in tar's -z, age encrypts streamed input.
    # `sudo` only on tar (which needs root for the rootfs); age runs
    # as the user so the passphrase prompt comes from this terminal.
    sudo tar -czpf - -C /var/lib/lxc/ "$LXC_NAME" | age -p -o "$out"
    sudo chmod 600 "$out"
else
    out="${BACKUP_DIR}/${BACKUP_PREFIX}-${stamp}.tar.gz"
    log "writing $out (UNENCRYPTED)"
    sudo tar -czpf "$out" -C /var/lib/lxc/ "$LXC_NAME"
    sudo chmod 644 "$out"
fi

size=$(du -h "$out" | awk '{print $1}')
log "done — $size"

# ---- restart if we stopped it ---------------------------------------------
if [ "$was_running" -eq 1 ]; then
    log "restarting LXC"
    sudo lxc-start -n "$LXC_NAME"
fi

log "list all backups with:  $0 --list"
