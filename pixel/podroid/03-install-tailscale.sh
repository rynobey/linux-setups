#!/usr/bin/env bash
# Install Tailscale inside the Ubuntu LXC and join the tailnet.
#
# Run this AFTER 02-bootstrap-lxc.sh has finished. Split from 02 because
# `tailscale up` reshuffles routing and drops the SSH/lxc-attach session
# you're running from — making it the final step ensures nothing else
# is queued behind the disconnect.
#
# After the SSH drop, reconnect via Tailscale MagicDNS:
#   ssh $USER@<TS_HOSTNAME>   (default: pixel-dev)
#
# Prereq: privileged LXC with /dev/net/tun bind-mounted in (see
# 01-create-lxc.sh) — without these, tailscaled fails to bring up
# its userspace TUN interface.
#
# Idempotent: re-running upgrades tailscale to the current stable.
# 'tailscale up' is interactive (opens an auth URL) and only fires if
# the node isn't already logged in.
#
# Env overrides:
#   TS_HOSTNAME   default: pixel-dev  (advertised name on tailnet)
#   TS_AUTHKEY    optional pre-generated auth key (non-interactive 'up')

set -euo pipefail

TS_HOSTNAME="${TS_HOSTNAME:-pixel-dev}"

log()  { printf '\033[1;34m[install-tailscale]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; }

# ---- /dev/net/tun sanity ---------------------------------------------------
if [ ! -e /dev/net/tun ]; then
    err "/dev/net/tun missing — the LXC config probably didn't bind it in."
    err "fix: add to /var/lib/lxc/<name>/config on the Alpine host:"
    err "  lxc.cgroup.devices.allow = c 10:200 rwm"
    err "  lxc.cgroup2.devices.allow = c 10:200 rwm"
    err "  lxc.mount.entry = /dev/net dev/net none bind,create=dir 0 0"
    err "then 'lxc-stop -n <name> && lxc-start -n <name>'."
    exit 1
fi

# ---- install ---------------------------------------------------------------
if command -v tailscale >/dev/null 2>&1; then
    log "tailscale already installed ($(tailscale version | head -1))"
else
    log "running official tailscale install script"
    curl -fsSL https://tailscale.com/install.sh | sh
fi

# ---- enable + start --------------------------------------------------------
if command -v systemctl >/dev/null 2>&1; then
    sudo systemctl enable --now tailscaled
else
    sudo service tailscaled start || true
fi

# ---- bring up --------------------------------------------------------------
status=$(sudo tailscale status --json 2>/dev/null | grep -o '"BackendState":"[^"]*"' | cut -d'"' -f4 || echo "Stopped")
if [ "$status" = "Running" ]; then
    log "tailscale already up — backend state Running"
    sudo tailscale status | head -5
else
    log "running 'tailscale up' (hostname=$TS_HOSTNAME)"
    if [ -n "${TS_AUTHKEY:-}" ]; then
        sudo tailscale up --hostname="$TS_HOSTNAME" --authkey="$TS_AUTHKEY"
    else
        warn "no TS_AUTHKEY env var — you'll need to open the auth URL printed below."
        warn "pre-generate one at https://login.tailscale.com/admin/settings/keys"
        warn "and re-run with: TS_AUTHKEY=tskey-... ./install-tailscale.sh"
        sudo tailscale up --hostname="$TS_HOSTNAME"
    fi
fi

# ---- print IPs -------------------------------------------------------------
log "tailscale IPs:"
sudo tailscale ip || true
log "done. Test from your laptop: ssh \$USER@${TS_HOSTNAME}"
