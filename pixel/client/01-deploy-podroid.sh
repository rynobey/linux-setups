#!/usr/bin/env bash
# Install or replace Podroid + apply post-install ADB config.
#
# Run from your CLIENT machine (Termux on Pixel, or a Linux laptop with
# ADB paired+connected to the Pixel). Workflow (c) from pixel/README.md.
#
# Prereqs:
#   - ADB paired and connected (Settings → Wireless debugging on the Pixel,
#     then `adb pair localhost:<pair-port>` and `adb connect localhost:<connect-port>`
#     from this client). Verify: `adb devices` shows "device".
#   - Custom Podroid APK at ~/apks/podroid-debug.apk (download from GH Actions)
#
# What this does:
#   1. Verify ADB is connected
#   2. Preflight: warn if AiCore is still enabled
#   3. Uninstall any existing Podroid package (signing-key change → required)
#   4. adb install the new APK
#   5. Apply Podroid ADB config (PPK disable, AVF perms, storage perms)
#      via pixel/podroid/helper/adb-setup.sh
#
# Flags:
#   --skip-uninstall   in-place upgrade (signing key must match)
#   --skip-install     don't install (e.g. APK already on-device)
#   --apk <path>       Podroid APK path (default: ~/apks/podroid-debug.apk)

set -euo pipefail

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helper"
. "$_LIB_DIR/_lib.sh"

APK="${PODROID_APK:-$HOME/apks/podroid-debug.apk}"
SKIP_UNINSTALL=0
SKIP_INSTALL=0

while [ $# -gt 0 ]; do
    case "$1" in
        --apk)             APK="$2"; shift 2 ;;
        --skip-uninstall)  SKIP_UNINSTALL=1; shift ;;
        --skip-install)    SKIP_INSTALL=1; shift ;;
        -h|--help)         sed -n '2,25p' "$0"; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done

# ---- ADB preflight --------------------------------------------------------
if ! command -v adb >/dev/null 2>&1; then
    err "adb not found. pkg install -y android-tools (Termux) or apt install adb (Ubuntu)"
    exit 1
fi
if ! adb devices | awk 'NR>1 && $2 == "device" {f=1} END{exit !f}'; then
    err "no authorized ADB device. Pair + connect first:"
    err "  adb pair localhost:<pair-port>"
    err "  adb connect localhost:<connect-port>"
    exit 1
fi
DEVICE=$(adb devices | awk 'NR>1 && $2 == "device" {print $1; exit}')
log "ADB device: $DEVICE"

# ---- AiCore preflight (memory headroom) -----------------------------------
if adb shell pm list packages -e 2>/dev/null | grep -q '^package:com\.google\.android\.aicore$'; then
    warn "AiCore is enabled — holds ~3.8 GB DMA-BUF when active, #1 cause"
    warn "of LMK killing the Podroid VM. Disable separately with:"
    warn "  bash $LSDIR/pixel/android-pkg-state.sh disable"
    warn "(Continuing — this is informational only.)"
    echo
fi

# ---- uninstall existing Podroid -------------------------------------------
EXISTING_PKGS=$(adb shell pm list packages 2>/dev/null \
    | grep -oE 'com\.excp\.podroid(\.debug)?' | sort -u || true)
if [ "$SKIP_UNINSTALL" -eq 1 ]; then
    log "skipping uninstall (--skip-uninstall)"
elif [ -z "$EXISTING_PKGS" ]; then
    log "no existing Podroid — fresh install"
else
    for pkg in $EXISTING_PKGS; do
        log "uninstalling $pkg (Alpine inside the app sandbox will be wiped)"
        adb uninstall "$pkg" || warn "  uninstall of $pkg returned non-zero"
    done
fi

# ---- install ---------------------------------------------------------------
if [ "$SKIP_INSTALL" -eq 1 ]; then
    log "skipping install (--skip-install)"
else
    if [ ! -f "$APK" ]; then
        err "APK not found at $APK"
        err "  download from GH Actions into ~/apks/, or pass --apk <path>"
        exit 1
    fi
    log "installing $APK ($(du -h "$APK" | awk '{print $1}'))"
    adb install "$APK"
fi

# ---- apply ADB config ------------------------------------------------------
log "applying Podroid ADB config (PPK + AVF perms + storage perms)"
bash "$LSDIR/pixel/podroid/helper/adb-setup.sh"

log ""
log "Done. Open Podroid → Settings → Backend: AVF, RAM: 4-6 GB, port forward 9922 → 22."
log "Then: pixel/client/05-setup-lxc-fresh.sh   (or 04-restore-lxc.sh if restoring)"
