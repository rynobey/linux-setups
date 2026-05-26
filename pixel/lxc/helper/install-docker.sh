#!/usr/bin/env bash
# Install Docker Engine inside the Ubuntu LXC.
#
# Uses the official get-docker.sh convenience script (which adds Docker's
# apt repo + installs docker-ce + containerd cleanly on Ubuntu). Then
# adds $USER to the docker group so you don't need sudo for everyday
# docker commands.
#
# Idempotent: re-running just re-applies the group membership.
#
# Prereq: privileged LXC (see create-lxc.sh) — overlay2 + cgroups +
# iptables manipulation all need the unconfined apparmor profile and
# the broad device-allow rules in /var/lib/lxc/pubuntu/config.

set -euo pipefail

log()  { printf '\033[1;34m[install-docker]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }

# ---- install ---------------------------------------------------------------
if command -v docker >/dev/null 2>&1; then
    log "docker already installed ($(docker --version))"
else
    log "fetching Docker's official install script"
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    curl -fsSL https://get.docker.com -o "$tmp/get-docker.sh"
    sudo sh "$tmp/get-docker.sh"
fi

# ---- enable + start --------------------------------------------------------
# Ubuntu LXC images don't ship systemd by default in some templates;
# probe before using systemctl.
if command -v systemctl >/dev/null 2>&1; then
    sudo systemctl enable --now docker
elif command -v service >/dev/null 2>&1; then
    sudo service docker start || true
fi

# ---- group membership ------------------------------------------------------
if [ -n "${SUDO_USER:-}" ]; then
    target_user="$SUDO_USER"
else
    target_user="$USER"
fi

if id -nG "$target_user" | grep -qw docker; then
    log "$target_user already in docker group"
else
    log "adding $target_user to docker group (re-login or 'newgrp docker' to apply)"
    sudo usermod -aG docker "$target_user"
fi

# ---- smoke test ------------------------------------------------------------
log "smoke test: docker info"
if sudo docker info >/dev/null 2>&1; then
    log "docker daemon responds — OK"
else
    warn "docker info failed — check 'sudo journalctl -u docker' or LXC config (apparmor/devices)"
fi

log "done. Try: docker run --rm hello-world"
