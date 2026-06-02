#!/usr/bin/env bash
# Back up the ENTIRE Podroid VM (disk image + app settings) to a single
# file on this client. Complements 03-backup-lxc.sh: that one snapshots
# the LXC from inside a RUNNING VM; this one snapshots the whole VM from
# OUTSIDE — Alpine system layer, all containers, podman/docker state,
# port-forward rules — and needs the VM to be STOPPED.
#
# How it works:
#   Everything the guest ever writes lives in ONE file in Podroid's
#   private dir: files/storage.img — a sparse 64 GiB ext4 image used as
#   the overlayfs upper (the squashfs lower ships with the APK and needs
#   no backup). App settings + port-forward rules live in files/datastore/.
#   We reach both via `adb ... run-as` (debug builds only — run-as is
#   refused for non-debuggable apps) and tar them SPARSE-AWARE (tar -S
#   transfers the ~11 GB of real data, not the 64 GiB apparent size),
#   compressing client-side with zstd (multithreaded; toybox gzip on the
#   device would bottleneck).
#
# Run from your CLIENT machine (Termux on the Pixel — fastest, loopback —
# or a Linux laptop with ADB paired+connected).
#
# Prereqs:
#   - ADB connected (`adb devices` shows "device"). From Termux:
#     `adb connect localhost:5555` after `adb tcpip 5555` from a paired
#     client, or the wireless-debugging pair+connect dance.
#   - Podroid VM STOPPED (stop it in the app; the script verifies).
#   - zstd on this client (pkg/apt install zstd); falls back to gzip.
#
# Flags:
#   --plain          unencrypted backup (default encrypts with age -p)
#   --local <dir>    output dir (default: ~/recovery-bundle on Termux,
#                                          ~/podroid-backups elsewhere)
#   --pkg <pkg>      app package (default: com.excp.podroid.debug)
#   --list           show existing VM backups in the local dir
#
# Encrypted backups prompt for an age passphrase. Save it to your
# password manager IMMEDIATELY — without it the backup is unrecoverable.
#
# Restore with: 10-restore-podroid-vm.sh

set -euo pipefail

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helper"
. "$_LIB_DIR/_lib.sh"

PKG="${PODROID_PKG:-com.excp.podroid.debug}"
if [ -n "${PREFIX:-}" ] && [ -x "${PREFIX}/bin/pkg" ]; then
    LOCAL_DIR_DEFAULT="$HOME/recovery-bundle"
else
    LOCAL_DIR_DEFAULT="$HOME/podroid-backups"
fi
LOCAL_DIR="${LOCAL_DIR_DEFAULT}"
ENCRYPT=1
MODE=backup

while [ $# -gt 0 ]; do
    case "$1" in
        --plain)   ENCRYPT=0; shift ;;
        --local)   LOCAL_DIR="$2"; shift 2 ;;
        --pkg)     PKG="$2"; shift 2 ;;
        --list|-l) MODE=list; shift ;;
        -h|--help) sed -n '2,41p' "$0"; exit 0 ;;
        *) err "unknown arg: $1"; exit 1 ;;
    esac
done

# ---- list mode --------------------------------------------------------------
if [ "$MODE" = list ]; then
    log "VM backups in $LOCAL_DIR:"
    found=0
    for f in "$LOCAL_DIR"/podroid-vm-*.tar.*; do
        [ -e "$f" ] || continue
        found=1
        printf '  %-50s  %6s  %s\n' "$(basename "$f")" \
            "$(du -h "$f" | awk '{print $1}')" \
            "$(stat -c '%y' "$f" | cut -d. -f1)"
    done
    [ "$found" -eq 0 ] && log "(none)"
    exit 0
fi

# ---- ADB preflight ----------------------------------------------------------
if ! command -v adb >/dev/null 2>&1; then
    err "adb not found. pkg install -y android-tools (Termux) or apt install adb (Ubuntu)"
    exit 1
fi
if ! adb devices | awk 'NR>1 && $2 == "device" {f=1} END{exit !f}'; then
    err "no authorized ADB device. Connect first (adb connect localhost:5555 from Termux)."
    exit 1
fi

# run-as only works on debuggable builds — fail early with a clear message.
if ! adb shell run-as "$PKG" ls files >/dev/null 2>&1; then
    err "run-as $PKG failed. Either the package isn't installed, or it's a"
    err "non-debuggable (release) build — this backup method needs the debug APK."
    exit 1
fi

# ---- VM must be stopped -----------------------------------------------------
# PodroidService is a foreground service that exists exactly while the VM
# runs (both QEMU and AVF backends). A live ServiceRecord ⇒ live ext4 ⇒
# a torn, unusable image — refuse to continue.
if adb shell dumpsys activity services "$PKG" 2>/dev/null | grep -q ServiceRecord; then
    err "Podroid VM appears to be RUNNING. Stop it in the app first"
    err "(Home → Stop), wait for it to fully stop, then re-run."
    exit 1
fi

# ---- encryption / compression tooling ---------------------------------------
if [ "$ENCRYPT" -eq 1 ] && ! command -v age >/dev/null 2>&1; then
    if [ -n "${PREFIX:-}" ] && [ -x "${PREFIX}/bin/pkg" ]; then
        log "installing age (pkg install age)"
        pkg install -y age
    else
        err "age not found (apt install age), or re-run with --plain"
        exit 1
    fi
fi
if command -v zstd >/dev/null 2>&1; then
    COMPRESS=(zstd -T0 -3 -q)
    EXT="tar.zst"
else
    warn "zstd not found — falling back to single-threaded gzip (slower)."
    warn "  pkg/apt install zstd for multi-core compression."
    COMPRESS=(gzip -c)
    EXT="tar.gz"
fi

# ---- backup -----------------------------------------------------------------
mkdir -p "$LOCAL_DIR"
real_size=$(adb shell run-as "$PKG" du -h files/storage.img | awk '{print $1}')
stamp="$(date +%F-%H%M)"
out="$LOCAL_DIR/podroid-vm-${stamp}.${EXT}"
[ "$ENCRYPT" -eq 1 ] && out="${out}.age"

log "streaming storage.img (${real_size} real data) + datastore from $PKG"
log "→ $out"
if [ "$ENCRYPT" -eq 1 ]; then
    log "you'll be prompted for a passphrase — remember it; restore needs the same one"
    adb exec-out run-as "$PKG" tar -cS -C files storage.img datastore \
        | "${COMPRESS[@]}" | age -p -o "$out"
    chmod 600 "$out"

    # Test-decrypt so a typo'd passphrase surfaces NOW, not at restore time.
    log ""
    log "verifying $out decrypts — enter the SAME passphrase ONCE MORE"
    if age -d "$out" > /dev/null; then
        log "✓ passphrase verified — backup is recoverable"
    else
        err "✗ DECRYPT TEST FAILED — passphrase doesn't match this file."
        err "  Recreate the backup."
        exit 1
    fi
else
    log "(UNENCRYPTED — contains everything inside your VM)"
    adb exec-out run-as "$PKG" tar -cS -C files storage.img datastore \
        | "${COMPRESS[@]}" > "$out"
fi

log "done — $(du -h "$out" | awk '{print $1}')"
log ""
log "restore with:  bash $CLIENT_DIR/10-restore-podroid-vm.sh $out"
