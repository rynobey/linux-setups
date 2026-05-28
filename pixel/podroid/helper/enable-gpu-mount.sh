#!/usr/bin/env bash
# enable-gpu-mount.sh
# ---------------------------------------------------------------------------
# Pass the Alpine guest's virtio-gpu render nodes (/dev/dri) into an EXISTING
# pubuntu LXC, so gfxstream-accelerated Vulkan/GL works inside pubuntu.
# Mirrors enable-x11-mounts.sh: runs ON ALPINE (root), idempotent (sentinel-
# bounded block), restarts the LXC to apply.
#
# Use this when you're adding GPU support to an already-created container
# (create-lxc.sh only adds the mount at creation time).
#
# PREREQ: the VM must have been started with `podroid.gpu=1` so /dev/dri exists
# on the Alpine host. Without it the mount is harmless (optional) but inert —
# re-run after enabling the GPU, or just reboot the VM with the marker set.
#
# Run it from a client with:
#   bash pixel/client/helper/alpine-run.sh pixel/podroid/helper/enable-gpu-mount.sh
# ...or directly on Alpine (root).
# ---------------------------------------------------------------------------
set -euo pipefail

LXC_NAME="${LXC_NAME:-pubuntu}"
CONFIG="/var/lib/lxc/${LXC_NAME}/config"
SENTINEL_BEGIN='# --- GPU /dev/dri passthrough (enable-gpu-mount.sh) BEGIN ---'
SENTINEL_END='# --- GPU /dev/dri passthrough (enable-gpu-mount.sh) END ---'

log()  { printf '\033[1;34m[enable-gpu-mount]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; }

if [ -f /etc/alpine-release ]; then :; else
    warn "This is meant to run on the Alpine host (where /var/lib/lxc lives)."
fi
[ -f "$CONFIG" ] || { err "LXC config not found at $CONFIG — has create-lxc.sh been run?"; exit 1; }

# ---- 1. is the GPU device present on the Alpine host? ----------------------
log "[1/3] checking for /dev/dri on the Alpine host"
if [ -e /dev/dri/renderD128 ]; then
    log "  present:"; ls -l /dev/dri/ | sed 's/^/    /'
else
    warn "  /dev/dri NOT present on Alpine — the VM wasn't started with podroid.gpu=1."
    warn "  The mount below is 'optional', so this is safe; it activates once the"
    warn "  VM boots with the GPU marker set. Set podroid.gpu=1 + reboot the VM, then re-run."
fi

# ---- 2. add the sentinel-bounded GPU block (idempotent) --------------------
# DRM major is 226. The create-lxc.sh privileged config already allows all
# devices (cgroup `= a`), but we add an explicit 226 rule too so this works
# even on a config that doesn't. 'optional' lets the LXC start with no GPU.
GPU_LINES=(
    "lxc.cgroup.devices.allow = c 226:* rwm"
    "lxc.cgroup2.devices.allow = c 226:* rwm"
    "lxc.mount.entry = /dev/dri dev/dri none bind,create=dir,optional 0 0"
)

if grep -qF "$SENTINEL_BEGIN" "$CONFIG"; then
    log "[2/3] replacing existing GPU block in $CONFIG"
    sudo sed -i "/${SENTINEL_BEGIN//\//\\/}/,/${SENTINEL_END//\//\\/}/d" "$CONFIG"
else
    log "[2/3] adding GPU block to $CONFIG"
fi
{
    echo ""
    echo "$SENTINEL_BEGIN"
    for line in "${GPU_LINES[@]}"; do echo "$line"; done
    echo "$SENTINEL_END"
} | sudo tee -a "$CONFIG" >/dev/null

# ---- 3. restart the LXC + verify -------------------------------------------
log "[3/3] restarting LXC '$LXC_NAME' to apply the mount"
if sudo lxc-info -n "$LXC_NAME" -s 2>/dev/null | grep -q RUNNING; then
    sudo lxc-stop -n "$LXC_NAME"
fi
sudo lxc-start -n "$LXC_NAME"
sudo lxc-wait -n "$LXC_NAME" -s RUNNING -t 30
sleep 1

log "verifying /dev/dri inside the LXC"
if sudo lxc-attach -n "$LXC_NAME" -- test -e /dev/dri/renderD128 2>/dev/null; then
    log "  ✓ /dev/dri present in pubuntu:"
    sudo lxc-attach -n "$LXC_NAME" -- ls -l /dev/dri/ 2>/dev/null | sed 's/^/    /'
    cat <<'EOF'

  Next: build the guest driver inside pubuntu:
    bash pixel/client/helper/lxc-run.sh --as <user> pixel/lxc/helper/build-gfxstream-mesa.sh

  Permission note: /dev/dri/renderD128 is group-owned (the node carries the
  Alpine guest's render GID, which may not match Ubuntu's 'render' group).
  If the pubuntu user can't open it, either run the GPU validation as root,
  add the user to the matching GID, or `chgrp`/`chmod` the node. Confirm with
  the `ls -l` above (note the group), then align inside pubuntu.
EOF
else
    warn "  /dev/dri NOT visible in pubuntu."
    warn "  Expected if the VM is running without podroid.gpu=1 (mount is optional)."
    warn "  Set podroid.gpu=1, reboot the VM, and re-run this script."
fi
log "done."
