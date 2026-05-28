#!/usr/bin/env bash
# install-desktop-gpu.sh
# ---------------------------------------------------------------------------
# Set up a lightweight, (eventually) GPU-accelerated Linux desktop inside the
# pubuntu (Ubuntu / glibc) LXC, targeting the gfxstream virtio-gpu device that
# Podroid exposes when started with `podroid.gpu=1`.
#
# RUN THIS INSIDE pubuntu (Ubuntu, glibc) — NOT the Alpine host-guest. The
# gfxstream userspace driver is glibc-oriented, so musl/Alpine is the wrong
# home for it; pubuntu is correct and is where you run apps anyway.
#
# Prereqs (host side, do these first — see notes at the bottom):
#   1. Podroid VM started with `podroid.gpu=1` in the kernel-extra-cmdline so
#      /dev/dri/card0 + renderD128 exist in the Alpine guest.
#   2. The LXC config bind-mounts /dev/dri into pubuntu AND allows the cgroup
#      device (char 226:* ) AND pubuntu's user is in the render/video group.
#   3. Working outbound network (apt). If `curl` hangs, fix that first.
#
# Scope: this installs the *definite* pieces (DE, X11, Mesa, validation tools)
# and then DETECTS whether a gfxstream Vulkan ICD is available. It does NOT
# blindly build Mesa — that's a heavy, environment-specific step flagged below.
# ---------------------------------------------------------------------------
set -euo pipefail

log()  { printf '\033[1;32m[desktop-gpu]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[err]\033[0m %s\n' "$*" >&2; }

DE="${DE:-xfce}"          # xfce (default) | lxqt
INSTALL_BROWSER="${INSTALL_BROWSER:-1}"

# ---- 0. preconditions ------------------------------------------------------
if [ -f /etc/alpine-release ]; then
    err "This is Alpine. Run this INSIDE the pubuntu (Ubuntu) LXC, not the host VM."
    exit 1
fi
. /etc/os-release 2>/dev/null || true
log "distro: ${PRETTY_NAME:-unknown}"

log "[0/4] checking the GPU device is visible in this container"
if [ -e /dev/dri/renderD128 ]; then
    log "  /dev/dri present:"; ls -l /dev/dri/ | sed 's/^/    /'
else
    warn "  /dev/dri/renderD128 NOT found in this container."
    warn "  GPU accel will be impossible until the LXC bind-mounts /dev/dri."
    warn "  (Software rendering will still work for a basic desktop.)"
fi

log "[0/4] checking outbound network (apt needs it)"
if ! curl -fsS --max-time 8 -o /dev/null http://archive.ubuntu.com/ 2>/dev/null; then
    warn "  outbound HTTP looks broken — apt will likely hang. Fix networking first."
fi

# ---- 1. base desktop + X11 -------------------------------------------------
log "[1/4] apt update + desktop environment ($DE) + X11"
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -y

# Xorg with the modesetting driver drives /dev/dri/card0 and uses glamor for
# GL-accelerated 2D; this is the path that can actually use the GPU. The
# existing Xvnc bridge can still serve as a software-display fallback.
COMMON_X="xserver-xorg-core xserver-xorg-video-modesetting xinit x11-xserver-utils xauth dbus-x11"

case "$DE" in
    xfce)  DE_PKGS="xfce4 xfce4-terminal xfce4-goodies" ;;
    lxqt)  DE_PKGS="lxqt-core openbox" ;;
    *) err "unknown DE='$DE' (use xfce or lxqt)"; exit 1 ;;
esac

sudo apt-get install -y $COMMON_X $DE_PKGS

# ---- 2. Mesa (GL + Vulkan) + validation tools ------------------------------
log "[2/4] Mesa userspace + Vulkan/GL diagnostic tools"
sudo apt-get install -y \
    libgl1-mesa-dri libglx-mesa0 mesa-utils \
    mesa-vulkan-drivers libvulkan1 vulkan-tools \
    libegl-mesa0 mesa-utils-extra

if [ "$INSTALL_BROWSER" = "1" ]; then
    # chromium via apt (snap-based firefox is painful in an LXC). Best-effort.
    sudo apt-get install -y chromium-browser 2>/dev/null \
        || sudo apt-get install -y chromium 2>/dev/null \
        || warn "no apt chromium; install a browser manually later"
fi

# ---- 3. gfxstream Vulkan ICD — the key (and uncertain) dependency ----------
# Distro Mesa does NOT normally ship the gfxstream guest Vulkan driver. Without
# it, Vulkan falls back to software (lavapipe) and GL to llvmpipe. We detect it
# here; building/obtaining it is flagged, not auto-run.
log "[3/4] checking for a gfxstream Vulkan ICD"
GFX_ICD="$(grep -rl -i gfxstream /usr/share/vulkan/icd.d/ 2>/dev/null | head -1 || true)"
if [ -n "$GFX_ICD" ]; then
    log "  found gfxstream ICD: $GFX_ICD — accel path available."
else
    warn "  no gfxstream Vulkan ICD installed. Vulkan will be SOFTWARE (lavapipe)."
    cat <<'EOF'
  To get hardware accel via gfxstream, pick ONE (in rough order of effort):
    (a) EXTRACT from Google's Stock Terminal Debian rootfs — it ships the
        gfxstream guest driver and is glibc/Debian-compatible with pubuntu.
        Copy its libvulkan_gfxstream.so + /usr/share/vulkan/icd.d/*gfxstream*
        and the GLES/EGL gfxstream libs, then set VK_ICD_FILENAMES.
    (b) BUILD Mesa with the gfxstream driver:
          meson setup build -Dvulkan-drivers=gfxstream -Dgles2=enabled \
                            -Dgallium-drivers= -Dplatforms=x11
          (pulls aemu/gfxstream protocol deps; heavy, ~30+ min)
    (c) Try a newer Mesa from a PPA/oibaf and re-check icd.d for gfxstream.
EOF
fi

# ---- 4. validation ---------------------------------------------------------
log "[4/4] validating what userspace actually sees on the device"
echo "=== glxinfo (GL renderer — 'llvmpipe' = software, anything else = accel) ==="
glxinfo -B 2>/dev/null | grep -iE "OpenGL renderer|OpenGL version|Device:|Vendor:" || echo "  (glxinfo needs a running X server / DISPLAY)"
echo "=== eglinfo (surfaceless EGL — works headless) ==="
eglinfo 2>/dev/null | grep -iE "EGL_VENDOR|Renderer|OpenGL ES" | head -6 || echo "  (eglinfo unavailable)"
echo "=== vulkaninfo (look for 'PowerVR'/'gfxstream' deviceName vs 'llvmpipe') ==="
vulkaninfo --summary 2>/dev/null | grep -iE "deviceName|driverName|apiVersion|deviceType" | head -12 || echo "  (vulkaninfo failed — no ICD?)"

cat <<'EOF'

------------------------------------------------------------------------------
DONE (base). Status summary:
  * Desktop ($DE) + X11 + Mesa + diagnostic tools: installed.
  * GPU accel: available ONLY if a gfxstream ICD was found above AND /dev/dri
    is in the container. Otherwise the desktop runs software-rendered — still
    usable on the Tensor CPU, just not slick.

NEXT — getting the desktop ON SCREEN (pick per your setup):
  * Quick/works-today: keep the existing Xvnc + Podroid X11 bridge and run the
    DE session over it (software-composited display, but functional):
        startxfce4    # inside the VNC X session
    Note: plain Xvnc has no GLX accel, so GL apps stay software even if the
    Vulkan device is real. Good enough for a 2D desktop + Vulkan compute.
  * Accelerated display: run Xorg on /dev/dri/card0 (modesetting+glamor) so the
    desktop composites on the GPU, and have Podroid surface the virtio-gpu
    scanout to an Android view (mirrors how the Stock Terminal shows its
    desktop). That surface wiring is the remaining app-side piece.

VERIFY ACCEL once the gfxstream ICD is in place:
    vkcube              # spinning cube via Vulkan -> should hit the GPU
    glmark2 / glmark2-es2
------------------------------------------------------------------------------
EOF
log "install-desktop-gpu.sh complete."
