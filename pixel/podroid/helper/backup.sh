#!/usr/bin/env bash
# Snapshot the 'pubuntu' LXC to an encrypted tarball on the shared
# Android storage. Runs ON THE ALPINE HOST inside Podroid, NOT inside
# the LXC.
#
# Backups land under BACKUP_DIR (default /var/lib/podroid-backups/),
# a regular directory on Alpine's persistent disk. The disk itself
# lives inside Podroid's app sandbox, so backups survive Alpine
# reboots, Podroid restarts, and VM rebuilds — but NOT a Podroid
# app-data wipe or uninstall. To get backups onto truly durable
# storage, run sync-backups.sh from your laptop after each backup
# (or on a schedule) to scp them off Alpine.
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
#   BACKUP_DIR     default: /var/lib/podroid-backups
#   BACKUP_PREFIX  default: ${LXC_NAME}

set -euo pipefail

LXC_NAME="${LXC_NAME:-pubuntu}"
# Backups land in a regular dir on Alpine's persistent disk. We do NOT
# write to /mnt/downloads (the AVF virtio-9p share from Android's
# /sdcard/Download/) because that share is silently dropped on some
# Android 16 / Pixel 10 firmware builds — backups would land nowhere.
# To get backups OFF Alpine onto durable storage, run sync-backups.sh
# from your laptop (Tailscale or adb-forward + scp). See README.
BACKUP_DIR="${BACKUP_DIR:-/var/lib/podroid-backups}"
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
# BACKUP_DIR is created on demand below; no sanity-check needed.

[ "$ENCRYPT" -eq 1 ] && ensure_age
sudo mkdir -p "$BACKUP_DIR"

# ---- stop the container so the rootfs is consistent during tar ------------
was_running=0
if sudo lxc-info -n "$LXC_NAME" -s 2>/dev/null | grep -q RUNNING; then
    was_running=1
    log "stopping LXC '${LXC_NAME}' for a consistent snapshot"
    sudo lxc-stop -n "$LXC_NAME"
    # Defensive: ALWAYS restart the LXC on script exit, regardless of
    # success/failure of the subsequent steps. Without this, an error
    # in tar/age/test-decrypt would leave pubuntu stopped — the user's
    # SSH access vanishes until they manually `lxc-start`.
    # shellcheck disable=SC2064  # we want $LXC_NAME expanded NOW
    trap "log 'auto-restarting LXC ${LXC_NAME} (script exit)'; sudo lxc-start -n ${LXC_NAME} 2>/dev/null || true" EXIT
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

    # ---- test-decrypt verification --------------------------------------
    # age -p's confirm-by-retyping catches single-keystroke typos but not
    # consistent ones — the only proof the backup is recoverable is an
    # actual decrypt attempt. Prompt for the SAME passphrase a third
    # time and decrypt the WHOLE file to /dev/null. Slow-ish for large
    # backups but bulletproof:
    #   - No pipeline, so pipefail / SIGPIPE can't fire mid-decrypt.
    #   - age's stderr is NOT redirected, so the user sees the
    #     "Enter passphrase:" prompt.
    #   - On failure we WARN + exit but DON'T auto-delete, because
    #     non-zero exit could also mean a /dev/tty issue rather than
    #     a real passphrase mismatch. Let the user re-verify manually.
    # ChaCha20-Poly1305 is hardware-accelerated on modern ARM; 1 GB
    # takes ~5 sec to decrypt.
    log ""
    log "verifying $out decrypts — enter the SAME passphrase ONCE MORE"
    if age -d "$out" > /dev/null; then
        log "✓ passphrase verified — backup is recoverable"
    else
        err "✗ DECRYPT TEST FAILED."
        err "  The backup at $out may or may not be recoverable."
        err "  Re-verify manually:"
        err "    age -d $out > /dev/null"
        err "  If THAT succeeds, the test had a glitch. If it fails too,"
        err "  the passphrase doesn't match this file — recreate the backup."
        exit 1
    fi
else
    out="${BACKUP_DIR}/${BACKUP_PREFIX}-${stamp}.tar.gz"
    log "writing $out (UNENCRYPTED)"
    sudo tar -czpf "$out" -C /var/lib/lxc/ "$LXC_NAME"
    sudo chmod 644 "$out"
fi

size=$(du -h "$out" | awk '{print $1}')
log "done — $size"

# LXC restart is handled by the EXIT trap set above (so it runs even
# if the test-decrypt step or some other intermediate step fails).

log "list all backups with:  $0 --list"
