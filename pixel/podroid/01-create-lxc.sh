#!/usr/bin/env bash
# Create the privileged Ubuntu LXC ('pubuntu') inside Podroid's Alpine
# host VM.
#
# This script runs ON THE ALPINE HOST (Podroid's primary terminal), NOT
# inside the LXC. It only handles the host-side concerns: installing
# lxc tooling if needed, writing a config tuned for Docker + Tailscale
# inside a privileged LXC, downloading the Ubuntu Noble arm64 rootfs,
# and starting the container.
#
# After this completes, run 'lxc-attach -n pubuntu' to drop into the
# LXC and continue with 02-bootstrap-lxc.sh (and the bootstrap-ssh.sh /
# bootstrap-git.sh curl-ables — see pixel/README.md).
#
# Env overrides:
#   LXC_NAME      default: pubuntu
#   LXC_DIST      default: ubuntu
#   LXC_RELEASE   default: noble
#   LXC_ARCH      default: arm64
#   SHARED_HOST   default: /mnt/shared    (path on Alpine host to bind-mount)
#   SHARED_GUEST  default: mnt/shared     (path inside LXC; relative for lxc.mount.entry)
#
# Idempotent: skips create/config/start if the container already exists.

set -euo pipefail

LXC_NAME="${LXC_NAME:-pubuntu}"
LXC_DIST="${LXC_DIST:-ubuntu}"
LXC_RELEASE="${LXC_RELEASE:-noble}"
LXC_ARCH="${LXC_ARCH:-arm64}"
SHARED_HOST="${SHARED_HOST:-/mnt/shared}"
SHARED_GUEST="${SHARED_GUEST:-mnt/shared}"

log()  { printf '\033[1;34m[01-create-lxc]\033[0m %s\n' "$*"; }
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

# Make sure the shared dir exists on the host before binding it in.
sudo mkdir -p "$SHARED_HOST"

sudo tee -a "$config" >/dev/null <<EOF

# --- added by 01-create-lxc.sh ---

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

# Persistence: bind Podroid's shared dir (which itself maps to Android's
# /sdcard/Download/Podroid/) into the LXC. Project files saved under
# ${SHARED_HOST}/ on the Alpine host (and equivalently /sdcard/... on
# Android) survive LXC destruction and Podroid app wipes.
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

Next:
  1. Attach to the LXC:
       sudo lxc-attach -n ${LXC_NAME}

  2. (Optionally) create your user:
       /var/lib/lxc/${LXC_NAME}/rootfs/... — or just from inside the LXC:
         curl -fsSL https://raw.githubusercontent.com/rynobey/linux-setups/master/bootstrap-ssh.sh | bash
       (authorizes laptop pubkeys so you can ssh in)

  3. Then from your laptop's ssh session into the LXC:
         curl -fsSL https://raw.githubusercontent.com/rynobey/linux-setups/master/bootstrap-git.sh | bash
       (installs git, sets up the LXC's own GitHub key, clones this repo)

  4. Finally, from the cloned repo inside the LXC:
         ./pixel/podroid/02-bootstrap-lxc.sh
       (Docker + Tailscale + sesh + nvm/Node, all installed)
==============================================================
EOF
