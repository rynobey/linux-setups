#!/data/data/com.termux/files/usr/bin/bash
# All-in-one ADB orchestrator for the Pixel Linux setup. Runs everything
# that needs ADB AFTER you've paired + connected the Wireless debugging
# session.
#
# Pairing has to happen manually first — it requires reading a 6-digit
# code off the Pixel's screen:
#
#   Pixel:  Settings → System → Developer options → Wireless debugging
#           → toggle ON → "Pair device with pairing code"
#   Termux: pkg install -y android-tools
#           adb pair localhost:<pair-port>           (enter the 6-digit code)
#           adb connect localhost:<connect-port>     (the OTHER port — they differ)
#           adb devices                              (verify shows "device")
#
# Then run this script.
#
# What this does (in order):
#   1. Verify ADB is connected and authorized.
#   2. Uninstall any existing Podroid package
#      (prevents INSTALL_FAILED_UPDATE_INCOMPATIBLE when the signing key changes).
#   3. Install the new Podroid APK from ~/apks/podroid-debug.apk.
#   4. Run pixel/podroid/adb-setup.sh: disable Phantom Process Killer, grant
#      AVF perms, grant storage perms.
#   5. (Optional) Run pixel/stock-terminal/adb-setup.sh to enable hardware
#      acceleration for the stock Linux Terminal.
#
# What this does NOT do:
#   - Disable AiCore / TTS. That's a separate concern (system-wide Android
#     memory tuning, useful for any heavy workload — not Podroid-specific).
#     Handle it with: bash pixel/android-pkg-state.sh disable. This script
#     warns if it detects AiCore enabled, since that's the #1 cause of LMK
#     killing the Podroid VM, but it won't change Android package state
#     for you.
#
# Flags:
#   --skip-uninstall          don't uninstall existing Podroid (in-place upgrade)
#   --skip-install            don't install the APK (e.g. already installed)
#   --include-stock-terminal  also run stock-terminal/adb-setup.sh (off by default)
#   --apk <path>              Podroid APK path (default: ~/apks/podroid-debug.apk)
#
# Env overrides:
#   LINUX_SETUPS_DIR          default: ~/linux-setups

set -euo pipefail

LSDIR="${LINUX_SETUPS_DIR:-$HOME/linux-setups}"
APK="${PODROID_APK:-$HOME/apks/podroid-debug.apk}"
SKIP_UNINSTALL=0
SKIP_INSTALL=0
INCLUDE_STOCK_TERMINAL=0

while [ $# -gt 0 ]; do
    case "$1" in
        --apk)                    APK="$2"; shift 2 ;;
        --skip-uninstall)         SKIP_UNINSTALL=1; shift ;;
        --skip-install)           SKIP_INSTALL=1; shift ;;
        --include-stock-terminal) INCLUDE_STOCK_TERMINAL=1; shift ;;
        -h|--help)                sed -n '2,35p' "$0"; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done

log()  { printf '\033[1;34m[deploy-podroid]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; }

# ---- 1. verify ADB connection ----------------------------------------------
if ! command -v adb >/dev/null 2>&1; then
    err "adb not found. Run: pkg install -y android-tools"
    exit 1
fi
if ! adb devices | awk 'NR>1 && $2 == "device" {found=1} END {exit !found}'; then
    err "no authorized ADB device. Pair + connect first:"
    err "  Pixel: Settings → Developer options → Wireless debugging → Pair device with pairing code"
    err "  Termux: adb pair localhost:<pair-port>     (enter the 6-digit code)"
    err "          adb connect localhost:<connect-port>"
    exit 1
fi
DEVICE=$(adb devices | awk 'NR>1 && $2 == "device" {print $1; exit}')
log "[1/4] ADB device: $DEVICE"

# ---- preflight: warn if AiCore is enabled ----------------------------------
# AiCore holds a ~3.8 GB DMA-BUF on Tensor when active and is the #1 cause
# of LMK killing the Podroid VM under memory pressure. We don't change
# Android package state here (separation of concerns), but we surface a
# loud warning so the user knows to handle it.
if adb shell pm list packages -e 2>/dev/null | grep -q '^package:com\.google\.android\.aicore$'; then
    warn "AiCore (com.google.android.aicore) is currently ENABLED."
    warn "It holds ~3.8 GB on Tensor when active and is the main cause of"
    warn "LMK killing the Podroid VM. Disable it before serious VM workloads:"
    warn "  bash $LSDIR/pixel/android-pkg-state.sh disable"
    warn "Continuing with deploy — this is informational, not blocking."
    echo
fi

# ---- 2. uninstall existing Podroid -----------------------------------------
# Both com.excp.podroid (release) and com.excp.podroid.debug (custom
# build) — uninstall whichever is present. Different signing keys
# between old + new APKs require this; same-key in-place upgrades
# don't, hence --skip-uninstall.
EXISTING_PKGS=$(adb shell pm list packages 2>/dev/null \
    | grep -oE 'com\.excp\.podroid(\.debug)?' \
    | sort -u || true)

if [ "$SKIP_UNINSTALL" -eq 1 ]; then
    log "[2/4] skipping uninstall (--skip-uninstall)"
    if [ -n "$EXISTING_PKGS" ]; then
        warn "      note: existing install detected ($EXISTING_PKGS) — adb install"
        warn "      may fail if signing keys differ between old + new APKs."
    fi
elif [ -z "$EXISTING_PKGS" ]; then
    log "[2/4] no existing Podroid to uninstall (skip)"
else
    for pkg in $EXISTING_PKGS; do
        log "[2/4] uninstalling $pkg"
        log "      (this wipes Alpine inside the app sandbox — your LXC backup"
        log "       should already be in ~/recovery-bundle/ or on /sdcard)"
        adb uninstall "$pkg" || warn "      uninstall of $pkg returned non-zero"
    done
fi

# ---- 3. install new APK ----------------------------------------------------
if [ "$SKIP_INSTALL" -eq 1 ]; then
    log "[3/4] skipping install (--skip-install)"
else
    if [ ! -f "$APK" ]; then
        err "[3/4] APK not found at $APK"
        err "      download from your GH Actions build into ~/apks/, or"
        err "      pass --apk <path>, or --skip-install if it's already on-device."
        exit 1
    fi
    APK_SIZE=$(du -h "$APK" | awk '{print $1}')
    log "[3/4] installing $APK ($APK_SIZE)"
    # `adb install` reads the APK via the ADB protocol; works directly from
    # Termux's $HOME without the public-storage workaround termux-open needs.
    adb install "$APK"
fi

# ---- 4. apply Podroid ADB config -------------------------------------------
# Phantom Process Killer disable + AVF perms + storage perms. Idempotent;
# re-running is safe. Required after every (re)install since perms get
# revoked on uninstall.
if [ -x "$LSDIR/pixel/podroid/adb-setup.sh" ]; then
    log "[4/4] applying Podroid ADB config (PPK + AVF perms + storage perms)"
    bash "$LSDIR/pixel/podroid/adb-setup.sh"
else
    err "[4/4] $LSDIR/pixel/podroid/adb-setup.sh not found"
    err "      did the linux-setups clone complete? Check ls $LSDIR/pixel/podroid/"
    exit 1
fi

# ---- optional Stock Terminal config ----------------------------------------
if [ "$INCLUDE_STOCK_TERMINAL" -eq 1 ]; then
    if [ -x "$LSDIR/pixel/stock-terminal/adb-setup.sh" ]; then
        log "[+] applying Stock Terminal ADB config"
        bash "$LSDIR/pixel/stock-terminal/adb-setup.sh"
    else
        warn "[+] $LSDIR/pixel/stock-terminal/adb-setup.sh not found; skipping"
    fi
fi

# ---- next-steps playbook ---------------------------------------------------
log ""
log "Done. Next steps:"
log "  1. Open the new Podroid app"
log "  2. Settings → Backend: AVF"
log "  3. Settings → VM RAM: 6 GB  (ballooning patch makes this safer now)"
log "  4. Settings → Port forward: 9922 → 22  (verify enabled)"
log "  5. Start VM, wait ~30s for Alpine to boot"
log "  6. Verify reachable from Termux:"
log "       ssh root@localhost -p 9922 'cat /etc/alpine-release'"
log "  7. Push the LXC backup back into Alpine:"
log "       LOCAL_DIR=\$HOME/recovery-bundle \\"
log "         bash $LSDIR/pixel/podroid/sync-backups.sh --push"
log "  8. Restore the LXC inside Alpine:"
log "       ssh root@localhost -p 9922 'cd /root/projects/linux-setups && \\"
log "         ./pixel/podroid/01-create-lxc.sh && \\"
log "         ./pixel/podroid/restore.sh --latest'"
log "  9. Verify ballooning engaged:"
log "       adb logcat -d | grep -iE 'balloon|AvfReflect'"
log "       (expect: 'memory balloon: enabled')"
