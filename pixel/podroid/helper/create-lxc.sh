#!/usr/bin/env bash
# Create the privileged Ubuntu LXC ('pubuntu') inside Podroid's Alpine
# host VM.
#
# This script runs ON THE ALPINE HOST, normally streamed via
# pixel/client/helper/alpine-run.sh from the client. It handles
# host-side concerns only: installing lxc tooling if needed, writing a
# config tuned for Docker + Tailscale inside a privileged LXC,
# downloading the Ubuntu Noble arm64 rootfs, and starting the container.
#
# After this completes (or as the next stage of
# pixel/client/05-setup-lxc-fresh.sh), the in-LXC steps are:
#   - pixel/lxc/helper/create-user.sh        (user creation)
#   - pixel/lxc/helper/bootstrap-ssh.sh      (sshd + key + authorize-pubkeys)
#   - pixel/lxc/helper/bootstrap-deps.sh     (Docker, toolchains, sesh, Node)
#   - pixel/lxc/helper/install-tailscale.sh  (Tailscale up)
#
# Env overrides:
#   LXC_NAME      default: pubuntu
#   LXC_DIST      default: ubuntu
#   LXC_RELEASE   default: noble
#   LXC_ARCH      default: arm64
#   SHARED_HOST   default: /mnt/downloads (Alpine path that's the AVF
#                                          virtio-9p share from /sdcard/Download/
#                                          — Android-backed, survives Podroid wipe)
#   SHARED_GUEST  default: mnt/shared     (path inside LXC; relative for lxc.mount.entry)
#
# Idempotent: skips create/config/start if the container already exists.

set -euo pipefail

LXC_NAME="${LXC_NAME:-pubuntu}"
LXC_DIST="${LXC_DIST:-ubuntu}"
LXC_RELEASE="${LXC_RELEASE:-noble}"
LXC_ARCH="${LXC_ARCH:-arm64}"
SHARED_HOST="${SHARED_HOST:-/mnt/downloads}"
SHARED_GUEST="${SHARED_GUEST:-mnt/shared}"

log()  { printf '\033[1;34m[create-lxc]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; }

# ---- sanity: must be on the Alpine host, not inside an existing LXC -------
if [ ! -d /var/lib/lxc ] && ! command -v lxc-create >/dev/null 2>&1; then
    log "installing lxc tooling on the Alpine host"
    sudo apk add --no-cache lxc lxc-templates lxc-download bridge ca-certificates curl
fi

# tmux on the Alpine host — backup.sh and restore.sh recommend running
# inside it (long-running ops get killed by Android's LMK when Podroid
# is backgrounded, taking the whole VM with them).
if ! command -v tmux >/dev/null 2>&1; then
    log "installing tmux on the Alpine host (for safe backup/restore sessions)"
    sudo apk add --no-cache tmux
fi

# ---- if container already exists, just print state and exit ---------------
if [ -d "/var/lib/lxc/${LXC_NAME}" ]; then
    log "LXC '${LXC_NAME}' already exists at /var/lib/lxc/${LXC_NAME}"
    state=$(sudo lxc-info -n "$LXC_NAME" -s 2>/dev/null | awk '{print $2}' || echo "unknown")
    log "current state: $state"
    if [ "$state" != "RUNNING" ]; then
        log "starting it"
        sudo lxc-start -n "$LXC_NAME"
    fi
    log "attach with: sudo lxc-attach -n ${LXC_NAME}"
    exit 0
fi

# ---- create the container from the download template ----------------------
log "creating LXC '${LXC_NAME}' (${LXC_DIST} ${LXC_RELEASE} ${LXC_ARCH})"
sudo lxc-create -t download -n "$LXC_NAME" -- \
    -d "$LXC_DIST" -r "$LXC_RELEASE" -a "$LXC_ARCH"

# ---- patch config for privileged + Docker + Tailscale + shared mount ------
config="/var/lib/lxc/${LXC_NAME}/config"
log "patching $config for Docker + Tailscale (privileged)"

# Sanity check the shared dir exists on the host. It's normally mounted
# by /etc/init.d/podroid-bootstrap (the virtio-9p 'downloads' tag from
# AVF → /sdcard/Download/ on Android). If it's missing, the user
# probably hasn't enabled Storage access in Podroid or hasn't granted
# MANAGE_EXTERNAL_STORAGE — warn but don't fail; the LXC can still run,
# just without persistent /mnt/shared.
if [ ! -d "$SHARED_HOST" ]; then
    warn "$SHARED_HOST doesn't exist on this Alpine host."
    warn "this is normally the AVF virtio-9p share from /sdcard/Download/."
    warn "to enable it: open Podroid → Settings → Storage access → ON,"
    warn "and grant MANAGE_EXTERNAL_STORAGE to the Podroid app."
    warn "without it, files written to /mnt/shared inside the LXC are"
    warn "ALPINE-INTERNAL and lost on Podroid uninstall/data-wipe."
    warn "creating $SHARED_HOST as a regular dir for now — backups won't survive."
    sudo mkdir -p "$SHARED_HOST"
fi

sudo tee -a "$config" >/dev/null <<EOF

# --- added by create-lxc.sh ---

# Privileged: AppArmor off, drop no capabilities, allow all devices.
# This is what lets Docker (overlay2, iptables) and Tailscale
# (/dev/net/tun) work without per-feature workarounds.
lxc.apparmor.profile = unconfined
lxc.cap.drop =
lxc.cgroup.devices.allow = a
lxc.cgroup2.devices.allow = a
lxc.mount.auto = proc:rw sys:rw cgroup:rw

# /dev/net/tun for Tailscale (and any other VPN/TUN tool inside).
lxc.cgroup.devices.allow = c 10:200 rwm
lxc.cgroup2.devices.allow = c 10:200 rwm
lxc.mount.entry = /dev/net dev/net none bind,create=dir 0 0

# GPU: pass the Alpine guest's virtio-gpu render nodes (/dev/dri — present only
# when the VM runs with podroid.gpu=1) into the LXC, so gfxstream-accelerated
# Vulkan/GL works in pubuntu (see build-gfxstream-mesa.sh). 'optional' so the
# container still starts when the GPU is off and there's no /dev/dri on the
# host. Device access is already permitted by the all-devices cgroup rule above.
lxc.mount.entry = /dev/dri dev/dri none bind,create=dir,optional 0 0

# Persistence: bind Podroid's Android-backed share (Alpine's
# ${SHARED_HOST}, which is /sdcard/Download/ on Android via the AVF
# virtio-9p 'downloads' tag) into the LXC at /mnt/shared. Files saved
# there land on Android public storage — survive LXC destruction,
# Podroid app wipes, and even Podroid uninstall.
lxc.mount.entry = ${SHARED_HOST} ${SHARED_GUEST} none bind,create=dir 0 0

# Make the in-container hostname (what shows up in shell prompts as
# user@host, what \`hostname\` returns inside the LXC) match the LXC
# name. The Ubuntu download template already writes /etc/hostname from
# -n at create time; this is just belt-and-braces for the UTS namespace.
lxc.uts.name = ${LXC_NAME}

# Auto-start when Alpine host (Podroid's VM) boots. Podroid restarts
# the VM frequently — letting LXC come back up unattended saves a
# manual 'lxc-start -n ${LXC_NAME}' every time.
lxc.start.auto = 1
lxc.start.delay = 0
EOF

# Make sure Alpine's lxc service is in the default runlevel so the
# auto-start config above actually fires on boot. Both checks below
# are idempotent — 'rc-update add' silently no-ops if already added.
if command -v rc-update >/dev/null 2>&1; then
    log "enabling lxc service at boot (rc-update add lxc default)"
    sudo rc-update add lxc default >/dev/null 2>&1 || true
else
    warn "no rc-update found — Alpine host doesn't look like OpenRC."
    warn "you'll need to enable the lxc service manually for auto-start."
fi

# ---- start ----------------------------------------------------------------
log "starting LXC '${LXC_NAME}'"
sudo lxc-start -n "$LXC_NAME"
sudo lxc-wait  -n "$LXC_NAME" -s RUNNING -t 30
log "LXC running"

cat <<EOF

==============================================================
LXC '${LXC_NAME}' is up.

This script is normally called via pixel/client/05-setup-lxc-fresh.sh
which continues with user creation + SSH + deps + Tailscale. If you
ran this helper directly, the next phases from your client side are:

  pixel/client/06-bootstrap-ssh-lxc.sh   # create user + SSH bootstrap
  pixel/client/07-bootstrap-deps-lxc.sh  # Docker + sesh + Node + ...
  pixel/client/08-install-tailscale-lxc.sh

Or attach directly (debug / manual):
  sudo lxc-attach -n ${LXC_NAME}
==============================================================
EOF
