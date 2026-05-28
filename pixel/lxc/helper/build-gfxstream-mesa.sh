#!/usr/bin/env bash
# build-gfxstream-mesa.sh
# ---------------------------------------------------------------------------
# Build Mesa's gfxstream Vulkan guest driver (+ Zink for GL-on-Vulkan) INSIDE
# pubuntu (Ubuntu / glibc / aarch64) so GPU-accelerated rendering works over
# Podroid's virtio-gpu device (crosvm `--gpu backend=gfxstream
# context-types=gfxstream-vulkan`). This is the same path the AOSP Stock
# Terminal uses on the Pixel 10.
#
# gfxstream's guest Vulkan driver was upstreamed into Mesa 24.3+, so we build
# it from the Mesa tree rather than chasing fragile prebuilts.
#
# PREREQS (do first):
#   - VM started with `podroid.gpu=1` so the guest has /dev/dri/renderD128.
#   - The LXC bind-mounts /dev/dri into pubuntu + user is in render/video group.
#   - Working outbound network (apt + git clone).
#   - Run as a normal user with sudo (NOT root-only); needs ~a few GB + time.
#
# NOTE: only ~47 of the Pixel 10's 142 Vulkan extensions reach the guest via
# gfxstream, and some are buggy — expect a usable-but-limited GPU. Some apps
# may even run worse than the CPU (lavapipe) fallback; A/B test per app.
# ---------------------------------------------------------------------------
set -euo pipefail

log()  { printf '\033[1;32m[gfxstream]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[err]\033[0m %s\n' "$*" >&2; }

# Pin a recent stable Mesa tag. Override with MESA_REF=mesa-XX.Y.Z. Check
# https://gitlab.freedesktop.org/mesa/mesa/-/tags for the latest; newer = more
# complete gfxstream support.
MESA_REF="${MESA_REF:-mesa-25.3.0}"
SRC="${SRC:-$HOME/src/mesa}"
BUILD="$SRC/build-gfxstream"

# ---- 0. preconditions ------------------------------------------------------
[ -f /etc/alpine-release ] && { err "This is Alpine. Run INSIDE pubuntu (glibc)."; exit 1; }
if [ -e /dev/dri/renderD128 ]; then
    log "GPU render node present: $(ls -1 /dev/dri/)"
else
    warn "/dev/dri/renderD128 NOT found — the gfxstream device isn't exposed."
    warn "Build will still succeed, but nothing will accelerate until the LXC"
    warn "bind-mounts /dev/dri AND the VM ran with podroid.gpu=1."
fi
if ls /usr/share/vulkan/icd.d/*gfxstream* >/dev/null 2>&1; then
    warn "A gfxstream ICD already exists ($(ls /usr/share/vulkan/icd.d/*gfxstream*)) —"
    warn "try the VALIDATION block at the bottom before building from source."
fi

# ---- 1. build dependencies -------------------------------------------------
log "[1/5] installing Mesa build dependencies"
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -y
sudo apt-get install -y \
    git build-essential meson ninja-build pkg-config cmake \
    python3-mako python3-yaml python3-pip \
    libdrm-dev libvulkan-dev vulkan-tools glslang-tools \
    libwayland-dev wayland-protocols libwayland-egl-backend-dev \
    libx11-dev libxext-dev libxcb1-dev libxcb-randr0-dev libxrandr-dev \
    libxshmfence-dev libxxf86vm-dev libxcb-shm0-dev libxcb-dri3-dev \
    libxcb-present-dev libxcb-sync-dev libxcb-xfixes0-dev \
    bison flex libexpat1-dev zlib1g-dev libzstd-dev mesa-utils

# ---- 2. fetch Mesa ---------------------------------------------------------
log "[2/5] fetching Mesa ($MESA_REF)"
mkdir -p "$(dirname "$SRC")"
if [ -d "$SRC/.git" ]; then
    git -C "$SRC" fetch --tags origin
else
    git clone https://gitlab.freedesktop.org/mesa/mesa.git "$SRC"
fi
git -C "$SRC" checkout "$MESA_REF"

# ---- 3. configure ----------------------------------------------------------
# gfxstream = the guest Vulkan driver; zink = GL-on-Vulkan so GL apps + the
# desktop run through the same gfxstream path. LLVM not needed for zink.
log "[3/5] meson setup (gfxstream Vulkan + Zink GL)"
cd "$SRC"
rm -rf "$BUILD"
meson setup "$BUILD" \
    -Dvulkan-drivers=gfxstream \
    -Dgallium-drivers=zink \
    -Dplatforms=x11,wayland \
    -Dgles2=enabled \
    -Dglx=dri \
    -Dllvm=disabled \
    -Dvideo-codecs= \
    -Dbuildtype=release
# If meson errors on a missing dep, `apt-get install` it and re-run this step.
# If a flag is rejected by this Mesa version, drop/adjust it and re-run.

# ---- 4. build + install ----------------------------------------------------
log "[4/5] building Mesa (takes a while on the Tensor CPU; grab a coffee)"
ninja -C "$BUILD"
sudo ninja -C "$BUILD" install
sudo ldconfig

# ---- 5. locate ICD + print validation steps -------------------------------
ICD=$(find "$BUILD" /usr/local/share/vulkan/icd.d /usr/share/vulkan/icd.d \
        -iname '*gfxstream*icd*.json' 2>/dev/null | head -1)
log "[5/5] gfxstream Vulkan ICD: ${ICD:-NOT FOUND — check the build output}"

cat <<EOF

------------------------------------------------------------------------------
BUILT. To use the gfxstream GPU path (add to ~/.profile or your session):

  export VK_ICD_FILENAMES=${ICD:-<path-to>/gfxstream_vk_*_icd.aarch64.json}
  export MESA_LOADER_DRIVER_OVERRIDE=zink     # GL apps -> Zink -> Vulkan -> gfxstream

VALIDATE (the moment of truth):
  VK_ICD_FILENAMES=\$VK_ICD_FILENAMES vulkaninfo --summary \\
      | grep -iE "deviceName|driverName|apiVersion|extensionCount"
      -> want a gfxstream / PowerVR device, NOT 'llvmpipe'/'lavapipe'.
      -> note the extensionCount — compare to the Stock Terminal's ~47.
  VK_ICD_FILENAMES=\$VK_ICD_FILENAMES vkcube         # spinning cube on the GPU
  MESA_LOADER_DRIVER_OVERRIDE=zink glxinfo -B | grep -i "OpenGL renderer"
      -> should show zink/gfxstream, not llvmpipe.

If vulkaninfo shows the device but apps glitch/crash, that's the known
gfxstream extension-coverage limit on Pixel 10 — fall back to CPU (unset the
env vars) per-app as needed.
------------------------------------------------------------------------------
EOF
log "build-gfxstream-mesa.sh complete."
