#!/usr/bin/env bash
# Restore a whole-VM Podroid backup made by 09-backup-podroid-vm.sh:
# streams the tarball back into the app's private dir via `adb run-as`,
# recreating files/storage.img (sparse) and files/datastore/.
#
# Works onto a fresh install too: install the debug APK first
# (01-deploy-podroid.sh), open the app once so files/ exists, stop the
# VM if it auto-started, then run this. First boot after restore comes
# up exactly where the backup left off.
#
# Two safety properties worth knowing:
#   - tar -xS re-punches the sparse holes, so the restored image has the
#     exact 64 GiB apparent size the app expects. Podroid WIPES and
#     recreates storage.img on any size mismatch (ensureStorageImage),
#     so the VM storage-size setting must match the backed-up image —
#     the script checks and warns.
#   - The app is force-stopped before writing so DataStore can't
#     overwrite the restored settings from its in-memory cache.
#
# Run from your CLIENT machine (Termux on the Pixel, or a Linux laptop
# with ADB paired+connected). VM must be STOPPED (verified).
#
# Usage:
#   10-restore-podroid-vm.sh [backup-file]
#     (default: newest podroid-vm-* in ~/recovery-bundle on Termux,
#                                      ~/podroid-backups elsewhere)
#
# Flags:
#   --pkg <pkg>   app package (default: com.excp.podroid.debug)

set -euo pipefail

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helper"
. "$_LIB_DIR/_lib.sh"

PKG="${PODROID_PKG:-com.excp.podroid.debug}"
if [ -n "${PREFIX:-}" ] && [ -x "${PREFIX}/bin/pkg" ]; then
    LOCAL_DIR_DEFAULT="$HOME/recovery-bundle"
else
    LOCAL_DIR_DEFAULT="$HOME/podroid-backups"
fi

BACKUP=""
while [ $# -gt 0 ]; do
    case "$1" in
        --pkg)     PKG="$2"; shift 2 ;;
        -h|--help) sed -n '2,29p' "$0"; exit 0 ;;
        -*) err "unknown arg: $1"; exit 1 ;;
        *)  BACKUP="$1"; shift ;;
    esac
done

# ---- pick the backup file ---------------------------------------------------
if [ -z "$BACKUP" ]; then
    BACKUP=$(ls -1t "$LOCAL_DIR_DEFAULT"/podroid-vm-*.tar.* 2>/dev/null | head -1 || true)
    if [ -z "$BACKUP" ]; then
        err "no podroid-vm-* backup found in $LOCAL_DIR_DEFAULT — pass a path explicitly"
        exit 1
    fi
fi
if [ ! -f "$BACKUP" ]; then
    err "backup not found: $BACKUP"
    exit 1
fi
log "restoring from $BACKUP ($(du -h "$BACKUP" | awk '{print $1}'))"

# Decrypt/decompress pipeline from the file extension.
case "$BACKUP" in
    *.tar.zst.age|*.tar.zst) DECOMPRESS=(zstd -dc) ;;
    *.tar.gz.age|*.tar.gz)   DECOMPRESS=(gzip -dc) ;;
    *) err "unrecognized extension (expected .tar.zst[.age] or .tar.gz[.age])"; exit 1 ;;
esac
ENCRYPTED=0
case "$BACKUP" in *.age) ENCRYPTED=1 ;; esac
if [ "${DECOMPRESS[0]}" = zstd ] && ! command -v zstd >/dev/null 2>&1; then
    err "zstd not found (pkg/apt install zstd)"; exit 1
fi
if [ "$ENCRYPTED" -eq 1 ] && ! command -v age >/dev/null 2>&1; then
    err "age not found (pkg/apt install age)"; exit 1
fi

# ---- ADB + package preflight ------------------------------------------------
if ! command -v adb >/dev/null 2>&1; then
    err "adb not found. pkg install -y android-tools (Termux) or apt install adb (Ubuntu)"
    exit 1
fi
if ! adb devices | awk 'NR>1 && $2 == "device" {f=1} END{exit !f}'; then
    err "no authorized ADB device. Connect first (adb connect localhost:5555 from Termux)."
    exit 1
fi
if ! adb shell run-as "$PKG" ls files >/dev/null 2>&1; then
    err "run-as $PKG failed. Install + open the debug APK once before restoring"
    err "(01-deploy-podroid.sh), or check --pkg."
    exit 1
fi

# ---- VM must be stopped, app fully dead -------------------------------------
if adb shell dumpsys activity services "$PKG" 2>/dev/null | grep -q ServiceRecord; then
    err "Podroid VM appears to be RUNNING. Stop it in the app first, then re-run."
    exit 1
fi
log "force-stopping $PKG (so DataStore can't clobber the restored settings)"
adb shell am force-stop "$PKG"

# ---- stream the restore -----------------------------------------------------
# exec-in forwards stdin raw (no pty mangling); tar -xS re-punches holes.
log "streaming restore (this is the slow part — ~real-data size over ADB)"
if [ "$ENCRYPTED" -eq 1 ]; then
    log "enter the backup's age passphrase"
    age -d "$BACKUP" | "${DECOMPRESS[@]}" \
        | adb exec-in run-as "$PKG" tar -xSf - -C files
else
    "${DECOMPRESS[@]}" "$BACKUP" \
        | adb exec-in run-as "$PKG" tar -xSf - -C files
fi

# ---- verify -----------------------------------------------------------------
# Apparent size must be GiB-aligned and match the in-app storage-size
# setting, or Podroid's ensureStorageImage wipes the image on next start.
bytes=$(adb shell run-as "$PKG" stat -c %s files/storage.img | tr -d '\r')
if [ -z "$bytes" ] || [ "$bytes" -lt $((1024*1024*1024)) ]; then
    err "restored storage.img looks wrong (size: ${bytes:-unknown} bytes)"
    exit 1
fi
gib=$(( bytes / 1024 / 1024 / 1024 ))
real=$(adb shell run-as "$PKG" du -h files/storage.img | awk '{print $1}')
log "restored storage.img: ${gib} GiB apparent, ${real} real + datastore/"
log ""
log "Done. Before starting the VM, confirm Settings → VM storage size is ${gib} GB —"
log "any mismatch makes the app silently recreate (WIPE) the image on next start."
