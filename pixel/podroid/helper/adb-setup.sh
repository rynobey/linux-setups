#!/usr/bin/env bash
# Apply all device-side ADB configurations Podroid needs:
#
#   1. Disable Android's Phantom Process Killer (system-wide, persists)
#      → keeps Android from reaping Podroid's QEMU child processes
#        under memory pressure. The set_sync_disabled_for_tests line
#        is crucial: without it Google's Phenotype service re-syncs
#        the original PPK settings from the server within hours, and
#        you start losing the VM again with no obvious cause.
#
#   2. Grant Podroid the AVF permissions
#      → MANAGE_VIRTUAL_MACHINE + USE_CUSTOM_VIRTUAL_MACHINE are
#        signature|preinstalled|development perms; the in-app UI
#        can't grant them. Without them Podroid silently falls back
#        to slow software emulation.
#
#   3. Grant Podroid storage permissions (both UID-mode and per-package)
#      → so AVF SharedPath against /sdcard/ has all the permissions it
#        wants to check. (Even with these granted, SharedPath may still
#        not work on the current Pixel 10 / Android 16 firmware — that's
#        a separate AVF service-side limitation.)
#
# Both com.excp.podroid (release) and com.excp.podroid.debug (custom
# build) are handled; packages that aren't installed are silently
# skipped.
#
# For the Stock Terminal's hardware-acceleration ADB step (separate
# concern, single-line), see pixel/stock-terminal/adb-setup.sh.
#
# Run from any host with ADB connected to the Pixel:
#   - Laptop with USB or wireless ADB
#   - Termux on the Pixel itself (pkg install android-tools, then
#     adb pair / adb connect via Wireless debugging — see README)
#
# This script does NOT handle ADB pairing (that requires reading a
# 6-digit code off the phone screen). Pair manually per the README,
# then run this script.
#
# Idempotent: re-running is harmless. Already-applied settings are
# silently re-applied; non-installed packages are skipped.

set -euo pipefail

log()  { printf '\033[1;34m[adb-setup]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; }

# ---- prereqs ---------------------------------------------------------------
if ! command -v adb >/dev/null 2>&1; then
    err "adb not found. Install android-tools / adb first:"
    err "  laptop (Ubuntu): sudo apt install adb"
    err "  Termux:          pkg install android-tools"
    exit 1
fi

# Confirm a device is connected and authorized. Lines look like:
#   192.168.1.50:38421  device
#   abc123              unauthorized
# We want at least one "device" (not "unauthorized" / "offline").
if ! adb devices | awk 'NR>1 && $2 == "device" {found=1} END {exit !found}'; then
    err "no authorized ADB device. Pair first per README:"
    err "  1. Phone: Settings → Developer options → Wireless debugging → Pair device with pairing code"
    err "  2. On this host: adb pair <ip>:<pair-port>  (enter the 6-digit code)"
    err "  3. On this host: adb connect <ip>:<main-port>"
    err "Or use USB cable + 'USB debugging' (allow the RSA prompt on the phone)."
    exit 1
fi
log "ADB device confirmed: $(adb devices | awk 'NR>1 && $2 == "device" {print $1; exit}')"

# ---- 1. Phantom Process Killer ---------------------------------------------
log "[1/3] disabling Phantom Process Killer (system-wide, persists)"
adb shell device_config set_sync_disabled_for_tests persistent
adb shell device_config put activity_manager max_phantom_processes 2147483647
adb shell settings put global settings_enable_monitor_phantom_procs false
log "       done"

# ---- 2 + 3. Per-Podroid-package config -------------------------------------
pkg_exists() {
    adb shell "pm list packages 2>/dev/null | grep -q '^package:${1}$'"
}

pkg_uid() {
    adb shell "dumpsys package $1 2>/dev/null | grep -oE 'userId=[0-9]+' | head -1 | cut -d= -f2"
}

configure_podroid() {
    local pkg="$1"
    log "[2+3/3] configuring $pkg"

    # AVF gate permissions — these are what flip the backend from
    # QEMU/TCG software-emulation to AVF/KVM hardware-accelerated.
    adb shell pm grant "$pkg" android.permission.MANAGE_VIRTUAL_MACHINE
    adb shell pm grant "$pkg" android.permission.USE_CUSTOM_VIRTUAL_MACHINE
    log "       AVF perms granted"

    # Per-package appops: storage access. The /mnt/downloads SharedPath
    # may still silently fail on this Android build even with all of
    # these granted (separate AVF limit), but we grant them anyway so
    # we've eliminated permission as a variable.
    adb shell appops set "$pkg" MANAGE_EXTERNAL_STORAGE allow
    adb shell appops set "$pkg" READ_EXTERNAL_STORAGE allow
    for op in READ_MEDIA_IMAGES READ_MEDIA_VIDEO READ_MEDIA_AUDIO \
              READ_MEDIA_VISUAL_USER_SELECTED; do
        adb shell appops set "$pkg" "$op" allow 2>/dev/null || true
    done
    log "       package-level appops set"

    # UID-level appops: on Android 13+, the legacy READ_EXTERNAL_STORAGE
    # and READ_MEDIA_* UID-mode is defaulted to 'ignore' (because the
    # permission was split per-media-type). Some system components check
    # UID-mode rather than package-mode and silently refuse. Align them.
    local uid
    uid=$(pkg_uid "$pkg" | tr -d '[:space:]')
    if [ -n "$uid" ]; then
        adb shell appops set --uid "$uid" READ_EXTERNAL_STORAGE allow 2>/dev/null || true
        for op in READ_MEDIA_IMAGES READ_MEDIA_VIDEO READ_MEDIA_AUDIO \
                  READ_MEDIA_VISUAL_USER_SELECTED; do
            adb shell appops set --uid "$uid" "$op" allow 2>/dev/null || true
        done
        log "       UID-level appops aligned (uid=$uid)"
    else
        warn "       couldn't determine UID for $pkg; skipping UID-level appops"
    fi
}

for pkg in com.excp.podroid com.excp.podroid.debug; do
    if pkg_exists "$pkg"; then
        configure_podroid "$pkg"
    else
        log "[2+3/3] skip $pkg (not installed)"
    fi
done

# ---- 4. deviceidle whitelist (Doze-kill prevention overnight) -------------
# Without this, Android's Doze evicts the cached Podroid app while the phone
# sits idle overnight — taking the VM with it. The whitelist tells Doze to
# leave the app alone even under battery saver. Same mechanism VPN apps,
# alarm clocks, etc. use to survive idle periods.
#
# Idempotent: `dumpsys deviceidle whitelist +PKG` is a no-op if already
# listed. Does NOT survive `pm clear`, factory reset, or some Android
# upgrades — those are typically what put us back in the original failure
# mode.
log "[4/4] adding Podroid packages to deviceidle whitelist"
for pkg in com.excp.podroid com.excp.podroid.debug; do
    if pkg_exists "$pkg"; then
        adb shell "dumpsys deviceidle whitelist +$pkg" >/dev/null 2>&1
        log "       + $pkg"
    fi
done

# ---- done ------------------------------------------------------------------
log ""
log "all done. To apply: restart the VM in Podroid (Settings/Stop,"
log "then Start). Verify with:"
log "  adb shell appops get com.excp.podroid.debug MANAGE_EXTERNAL_STORAGE"
log "  adb shell settings get global settings_enable_monitor_phantom_procs"
log "  adb shell dumpsys deviceidle whitelist | grep podroid"
