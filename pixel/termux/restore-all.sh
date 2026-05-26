#!/data/data/com.termux/files/usr/bin/bash
# Self-contained offline recovery for a fresh Termux on the Pixel.
#
# Run on a freshly-installed Termux:
#   termux-setup-storage                                        (tap Allow)
#   bash ~/storage/shared/Download/restore-all.sh
#
# What this does:
#   1. Restore $PREFIX (Termux packages, including age, ssh, etc.) from
#      ~/storage/shared/Download/termux-prefix-<date>.tar.xz via
#      termux-restore.
#   2. Decrypt + extract $HOME from
#      ~/storage/shared/Download/pixel-home-<date>.tar.age via age +
#      tar. Prompts for the bundle passphrase.
#
# Why this order: a fresh Termux doesn't ship with age. Restoring $PREFIX
# first brings age into $PREFIX/bin so we can decrypt the HOME archive
# in step 2. Without this ordering you'd need network access to
# `pkg install age` first, which defeats the offline-recovery goal.
#
# Idempotent caveat: termux-restore uses `tar --recursive-unlink` to
# erase the target dirs before extracting. So running this twice IS
# safe ($PREFIX gets re-restored, $HOME gets re-extracted), but it
# clobbers any in-place changes you made between runs. Don't re-run
# carelessly.

set -euo pipefail

# Use a hardcoded /sdcard path because $HOME/storage/shared may not be
# set up yet on a brand-new Termux (termux-setup-storage creates that
# symlink lazily — it might be there from a prior run but might not).
# /sdcard is the Android-wide path that's stable across Termux installs.
DL_PRIMARY="$HOME/storage/shared/Download"
DL_FALLBACK="/sdcard/Download"

log()  { printf '\033[1;34m[restore-all]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; }

# ---- locate artifacts ------------------------------------------------------
for d in "$DL_PRIMARY" "$DL_FALLBACK"; do
    if [ -d "$d" ]; then
        DL="$d"
        break
    fi
done
if [ -z "${DL:-}" ]; then
    err "neither $DL_PRIMARY nor $DL_FALLBACK is accessible."
    err "Run 'termux-setup-storage' (tap Allow) and re-run this script."
    exit 1
fi
log "using artifact dir: $DL"

PREFIX_TAR=$(ls -t "$DL"/termux-prefix-*.tar.xz 2>/dev/null | head -1 || true)
HOME_TAR=$(ls -t "$DL"/pixel-home-*.tar.age 2>/dev/null | head -1 || true)

if [ -z "$PREFIX_TAR" ]; then
    err "no termux-prefix-*.tar.xz in $DL"
    err "  expected something like: termux-prefix-2026-05-26.tar.xz"
    exit 1
fi
if [ -z "$HOME_TAR" ]; then
    err "no pixel-home-*.tar.age in $DL"
    err "  expected something like: pixel-home-2026-05-26.tar.age"
    exit 1
fi

log "found artifacts:"
log "    PREFIX: $PREFIX_TAR ($(du -h "$PREFIX_TAR" | awk '{print $1}'))"
log "    HOME:   $HOME_TAR ($(du -h "$HOME_TAR" | awk '{print $1}'))"
echo

# ---- 1. restore $PREFIX ----------------------------------------------------
# termux-restore will erase $PREFIX and replace it. Bash, currently running
# from $PREFIX/bin/bash, keeps using the mmap'd copy of the old binary
# until the script exits — so the script continues to run uninterrupted
# while the on-disk $PREFIX is replaced. Forked-and-exec'd child processes
# (tar, age, etc.) pick up the new binaries, which is what we want.
log "[1/2] restoring \$PREFIX from $(basename "$PREFIX_TAR") ..."
log "      (this can take a minute — termux-restore wipes \$PREFIX then untars)"
termux-restore "$PREFIX_TAR"

# Verify age landed in the restored $PREFIX. If it didn't, the HOME
# restore can't proceed.
if [ ! -x "$PREFIX/bin/age" ]; then
    err "age not present in restored \$PREFIX. Cannot decrypt HOME tar."
    err "  the PREFIX backup at $PREFIX_TAR was made without age installed."
    err "  manual recovery: 'pkg install -y age' (needs network), then:"
    err "    age -d $HOME_TAR | tar xf - -C \$HOME"
    exit 1
fi
log "      \$PREFIX restored. age is available."
echo

# ---- 2. restore $HOME ------------------------------------------------------
log "[2/2] decrypting + extracting \$HOME from $(basename "$HOME_TAR") ..."
log "      you'll be prompted for the bundle passphrase."

# Pipe age's plaintext stdout into tar. Strip ownership info on extract
# (--no-same-owner) because Termux runs as a non-root app UID — the UID
# embedded in the tar likely doesn't match this Termux's UID.
age -d "$HOME_TAR" | tar xf - -C "$HOME" --no-same-owner

echo
log "Done. Restored:"
log "    \$PREFIX from $PREFIX_TAR"
log "    \$HOME   from $HOME_TAR"
log ""
log "Next steps:"
log "  - If sshd / pubkey-authorize aren't running, run init.sh's later"
log "    steps to re-authorize and start sshd:"
log "      bash ~/linux-setups/pixel/termux/init.sh"
log "  - For Podroid VM restore (sideload APK + push LXC backup + restore"
log "    inside Alpine), follow:"
log "      bash ~/linux-setups/pixel/termux/restore-bundle.sh"
