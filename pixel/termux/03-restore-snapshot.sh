#!/data/data/com.termux/files/usr/bin/bash
# Self-contained offline recovery for a fresh Termux on the Pixel.
#
# Run on a freshly-installed Termux:
#   termux-setup-storage                                        (tap Allow)
#   bash ~/storage/shared/Download/03-restore-snapshot.sh
#
# What this does:
#   1. Restore $PREFIX (Termux packages, including age, ssh, etc.) from
#      ~/storage/shared/Download/termux-prefix-<date>.tar.xz via
#      termux-restore.   (skippable — see --skip-prefix below)
#   2. Decrypt + extract $HOME from
#      ~/storage/shared/Download/pixel-home-<date>.tar.age via age +
#      tar. Prompts for the bundle passphrase.
#   3. Restore the proot Ubuntu container from
#      ~/storage/shared/Download/proot-ubuntu-<date>.tar.gz.age if one
#      exists. Independent of the $PREFIX restore, so safe to use even
#      when $PREFIX restore is skipped (cross-install scenarios).
#
# Why this order: a fresh Termux doesn't ship with age. Restoring $PREFIX
# first brings age into $PREFIX/bin so we can decrypt the encrypted
# bundles in steps 2 + 3. Without this ordering you'd need network
# access to `pkg install age` first, which defeats the offline-recovery
# goal — unless you pass --skip-prefix, in which case you should
# `pkg install age openssh proot-distro tar` first.
#
# Flags:
#   --skip-prefix   Don't run termux-restore. Use this if you suspect
#                   cross-install contamination (Play Store → F-Droid, or
#                   anything that's left residual SELinux categories);
#                   the prefix backup will then break proot. You'll need
#                   network + `pkg install age openssh proot-distro tar`
#                   manually before running.
#   --skip-home     Don't decrypt + extract $HOME (PREFIX only).
#   --skip-proot    Don't restore the proot Ubuntu container.
#
# Idempotent caveat: termux-restore uses `tar --recursive-unlink` to
# erase the target dirs before extracting. So running this twice IS
# safe ($PREFIX gets re-restored, $HOME gets re-extracted), but it
# clobbers any in-place changes you made between runs. Don't re-run
# carelessly.

set -euo pipefail

SKIP_PREFIX=0
SKIP_HOME=0
SKIP_PROOT=0
while [ $# -gt 0 ]; do
    case "$1" in
        --skip-prefix) SKIP_PREFIX=1; shift ;;
        --skip-home)   SKIP_HOME=1;   shift ;;
        --skip-proot)  SKIP_PROOT=1;  shift ;;
        -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done

# Use a hardcoded /sdcard path because $HOME/storage/shared may not be
# set up yet on a brand-new Termux (termux-setup-storage creates that
# symlink lazily — it might be there from a prior run but might not).
# /sdcard is the Android-wide path that's stable across Termux installs.
DL_PRIMARY="$HOME/storage/shared/Download"
DL_FALLBACK="/sdcard/Download"

log()  { printf '\033[1;34m[restore-snapshot]\033[0m %s\n' "$*"; }
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
PROOT_TAR=$(ls -t "$DL"/proot-*.tar.gz.age 2>/dev/null | head -1 || true)

if [ "$SKIP_PREFIX" -eq 0 ] && [ -z "$PREFIX_TAR" ]; then
    err "no termux-prefix-*.tar.xz in $DL"
    err "  expected something like: termux-prefix-2026-05-26.tar.xz"
    err "  (pass --skip-prefix to bypass — but then 'pkg install age openssh proot-distro tar' first)"
    exit 1
fi
if [ "$SKIP_HOME" -eq 0 ] && [ -z "$HOME_TAR" ]; then
    err "no pixel-home-*.tar.age in $DL"
    err "  expected something like: pixel-home-2026-05-26.tar.age"
    exit 1
fi

log "found artifacts:"
[ -n "$PREFIX_TAR" ] && log "    PREFIX: $PREFIX_TAR ($(du -h "$PREFIX_TAR" | awk '{print $1}'))"
[ -n "$HOME_TAR"   ] && log "    HOME:   $HOME_TAR ($(du -h "$HOME_TAR" | awk '{print $1}'))"
[ -n "$PROOT_TAR"  ] && log "    PROOT:  $PROOT_TAR ($(du -h "$PROOT_TAR" | awk '{print $1}'))"
echo

# ---- 1. restore $PREFIX ----------------------------------------------------
if [ "$SKIP_PREFIX" -eq 1 ]; then
    log "[1/3] skipping \$PREFIX restore (--skip-prefix)"
    # Make sure we have age, tar, proot-distro from somewhere else.
    for cmd in age tar proot-distro; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            err "      $cmd not available — \`pkg install $cmd\` before continuing"
            exit 1
        fi
    done
else
    # termux-restore will erase $PREFIX and replace it. Bash, currently running
    # from $PREFIX/bin/bash, keeps using the mmap'd copy of the old binary
    # until the script exits — so the script continues to run uninterrupted
    # while the on-disk $PREFIX is replaced. Forked-and-exec'd child processes
    # (tar, age, etc.) pick up the new binaries, which is what we want.
    log "[1/3] restoring \$PREFIX from $(basename "$PREFIX_TAR") ..."
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
fi
echo

# ---- 2. restore $HOME ------------------------------------------------------
if [ "$SKIP_HOME" -eq 1 ]; then
    log "[2/3] skipping \$HOME restore (--skip-home)"
else
    log "[2/3] decrypting + extracting \$HOME from $(basename "$HOME_TAR") ..."
    log "      you'll be prompted for the bundle passphrase."

    # Pipe age's plaintext stdout into tar. Strip ownership info on extract
    # (--no-same-owner) because Termux runs as a non-root app UID — the UID
    # embedded in the tar likely doesn't match this Termux's UID.
    age -d "$HOME_TAR" | tar xf - -C "$HOME" --no-same-owner
fi
echo

# ---- 3. restore proot Ubuntu container ------------------------------------
if [ "$SKIP_PROOT" -eq 1 ]; then
    log "[3/3] skipping proot restore (--skip-proot)"
elif [ -z "$PROOT_TAR" ]; then
    log "[3/3] no proot-*.tar.gz.age artifact in $DL — skipping (this is fine if you didn't install proot Ubuntu yet)"
else
    # Restore helper might be:
    #   - in $HOME after the $HOME restore (if it shipped linux-setups)
    #   - in $DL/restore-helpers/ (placed there by 02-snapshot.sh step 7)
    HELPER=""
    for candidate in \
        "$HOME/linux-setups/pixel/termux/helper/restore-proot.sh" \
        "$DL/restore-helpers/restore-proot.sh"; do
        if [ -x "$candidate" ] || [ -f "$candidate" ]; then
            HELPER="$candidate"
            break
        fi
    done
    if [ -z "$HELPER" ]; then
        warn "[3/3] no restore-proot.sh helper found — skipping proot restore."
        warn "      Manual fallback (works as long as proot-distro is installed):"
        warn "        age -d '$PROOT_TAR' \\"
        warn "          | tar -C \$PREFIX/var/lib/proot-distro/containers -xf -"
        warn "        proot-distro login ubuntu -- /bin/true   # verify"
    else
        log "[3/3] restoring proot from $(basename "$PROOT_TAR") via $HELPER"
        # FORCE=1 so it overwrites a stale container without an interactive prompt
        # (this is the restore script — the user clearly intends to overwrite).
        FORCE=1 bash "$HELPER" "$PROOT_TAR"
    fi
fi
echo

log "Done. Restored:"
[ "$SKIP_PREFIX" -eq 0 ] && log "    \$PREFIX from $PREFIX_TAR"
[ "$SKIP_HOME"   -eq 0 ] && log "    \$HOME   from $HOME_TAR"
[ "$SKIP_PROOT"  -eq 0 ] && [ -n "$PROOT_TAR" ] && log "    proot   from $PROOT_TAR"
log ""
log "Next steps:"
log "  - If sshd / pubkey-authorize aren't running, re-run init's later"
log "    steps to re-authorize and start sshd:"
log "      bash ~/linux-setups/pixel/termux/01-init-termux.sh"
log "  - For the full Podroid + LXC restore (sideload APK + push backup"
log "    + restore inside Alpine), use the client/ entry scripts:"
log "      bash ~/linux-setups/pixel/client/01-deploy-podroid.sh"
log "      bash ~/linux-setups/pixel/client/04-restore-lxc.sh --latest"
log "  - To bring up the proot Ubuntu desktop (i3 on Termux:X11):"
log "      bash ~/linux-setups/pixel/termux/06-deploy-runtime-scripts.sh"
log "      bash ~/start-x11.sh"
