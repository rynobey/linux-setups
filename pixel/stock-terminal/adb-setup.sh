#!/usr/bin/env bash
# Apply the ADB-side config the Stock Linux Terminal needs:
#
#   - Hardware acceleration: touch /sdcard/linux/virglrenderer
#     The Stock Terminal VM checks for this flag file at boot. With it
#     present, the VM advertises zink/Vulkan to guest OpenGL apps (real
#     hardware acceleration via the Pixel's Tensor GPU). Without it,
#     the VM falls back to llvmpipe software rendering — usable but
#     stuttery for anything graphical.
#
# That's the only ADB-side step for the Stock Terminal — it's a
# privileged system app, so the AVF permissions and storage perms
# Podroid needs are pre-granted by AOSP. If you want the Podroid
# ADB config too, run pixel/podroid/adb-setup.sh separately.
#
# Run from any host with ADB connected to the Pixel (laptop, Termux,
# etc.). Pair ADB manually per the README first.
#
# Idempotent: re-running just re-touches the flag file.

set -euo pipefail

log() { printf '\033[1;34m[adb-setup-stock]\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; }

if ! command -v adb >/dev/null 2>&1; then
    err "adb not found. Install android-tools / adb first:"
    err "  laptop (Ubuntu): sudo apt install adb"
    err "  Termux:          pkg install android-tools"
    exit 1
fi

if ! adb devices | awk 'NR>1 && $2 == "device" {found=1} END {exit !found}'; then
    err "no authorized ADB device. Pair first per README:"
    err "  Settings → Developer options → Wireless debugging → Pair device with pairing code"
    err "  Then: adb pair <ip>:<pair-port>  (enter the 6-digit code)"
    err "        adb connect <ip>:<conn-port>"
    exit 1
fi
log "ADB device confirmed: $(adb devices | awk 'NR>1 && $2 == "device" {print $1; exit}')"

log "enabling hardware acceleration (touch /sdcard/linux/virglrenderer)"
adb shell 'mkdir -p /sdcard/linux && touch /sdcard/linux/virglrenderer'
log "done."
log ""
log "to apply: cold-stop the Terminal app on the phone (Recents → swipe"
log "away, or Settings → Apps → Terminal → Force stop) then reopen it."
log ""
log "verify inside the Terminal's Debian VM:"
log "  sudo apt install -y mesa-utils"
log "  glxinfo | grep 'OpenGL renderer'"
log "  # expected: 'zink Vulkan ...'  (NOT 'llvmpipe')"
