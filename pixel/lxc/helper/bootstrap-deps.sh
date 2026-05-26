#!/usr/bin/env bash
# In-LXC deps bootstrap. Runs INSIDE the LXC (called from the client side
# via pixel/client/helper/lxc-run.sh + pixel/client/07-bootstrap-deps-lxc.sh).
#
# Installs the development toolchain. SSH bootstrap is a SEPARATE step
# (pixel/client/06-bootstrap-ssh-lxc.sh) — call that first if it hasn't
# been done. Tailscale is also separate (pixel/client/08-install-tailscale-lxc.sh)
# because `tailscale up` reshuffles networking and drops the SSH/
# lxc-attach session this script runs from.
#
# Order of operations (each idempotent, skippable via env var):
#   1. apt update + base packages
#   2. install-docker.sh        (skip with SKIP_DOCKER=1)
#   3. install-toolchains.sh    (skip with SKIP_TOOLCHAINS=1)
#   4. install-sesh.sh          (skip with SKIP_SESH=1)
#   5. install-node.sh          (skip with SKIP_NODE=1)
#
# Must be run as the user that will own ~/.docker/, ~/.nvm/, etc. —
# NOT as root. The client wrapper handles that (lxc-run.sh --as <username>).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log()  { printf '\033[1;32m[bootstrap-deps]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }

# ---- sanity: we should be inside an Ubuntu LXC, not the Alpine host -------
if [ -f /etc/alpine-release ]; then
    warn "this looks like Alpine — bootstrap-deps.sh is meant to run INSIDE"
    warn "the Ubuntu LXC. From the client side, use the lxc-run.sh helper."
    exit 1
fi

# ---- 1. base apt setup -----------------------------------------------------
log "[1/5] updating apt + installing base tools"
sudo apt-get update -y
sudo apt-get install -y curl ca-certificates gnupg sudo

# ---- 2. docker -------------------------------------------------------------
if [ -z "${SKIP_DOCKER:-}" ]; then
    log "[2/5] installing docker"
    "$SCRIPT_DIR/install-docker.sh"
else
    log "[2/5] skipped (SKIP_DOCKER=1)"
fi

# ---- 3. build toolchains ---------------------------------------------------
if [ -z "${SKIP_TOOLCHAINS:-}" ]; then
    log "[3/5] installing build toolchains (build-essential, golang-go, pkg-config)"
    "$SCRIPT_DIR/install-toolchains.sh"
else
    log "[3/5] skipped (SKIP_TOOLCHAINS=1)"
fi

# ---- 4. sesh ---------------------------------------------------------------
if [ -z "${SKIP_SESH:-}" ]; then
    log "[4/5] installing sesh + scroll + nvim"
    "$SCRIPT_DIR/install-sesh.sh"
else
    log "[4/5] skipped (SKIP_SESH=1)"
fi

# ---- 5. node ---------------------------------------------------------------
if [ -z "${SKIP_NODE=}" ]; then
    log "[5/5] installing nvm + Node.js"
    "$SCRIPT_DIR/install-node.sh"
else
    log "[5/5] skipped (SKIP_NODE=1)"
fi

log ""
log "Deps bootstrap complete. Tailscale is the only remaining piece:"
log "  pixel/client/08-install-tailscale-lxc.sh   (from your client)"
