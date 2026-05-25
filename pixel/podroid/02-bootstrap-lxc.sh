#!/usr/bin/env bash
# Orchestrator that turns a freshly-created Ubuntu LXC into a working
# dev box. Runs INSIDE the LXC (not on the Alpine host).
#
# Tailscale is *not* set up here — it's split into 03-install-tailscale.sh
# because `tailscale up` reshuffles networking and drops the SSH/lxc-attach
# session you're running from. Finish 02 over SSH, then run 03 once at the
# end as a deliberate final step.
#
# Prereqs:
#   - 01-create-lxc.sh has already created and started the 'dev' LXC
#     on the Alpine host
#   - You are attached into the LXC (sudo lxc-attach -n dev) OR ssh'd
#     into it after bootstrap-ssh.sh authorized your laptop's key
#   - This repo is cloned (run ../../bootstrap-git.sh if not)
#
# Order of operations (each step is idempotent and skippable via env):
#   1. apt update + base build tools
#   2. authorize-pubkeys.sh           (skip with SKIP_PUBKEYS=1)
#   3. install-docker.sh              (skip with SKIP_DOCKER=1)
#   4. install-sesh.sh                (skip with SKIP_SESH=1)
#   5. install-node.sh                (skip with SKIP_NODE=1)
#
# create-user.sh is NOT run here — it should be invoked once, manually,
# before this script (so you're already running this as the right user).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log()  { printf '\033[1;32m[bootstrap-lxc]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }

# ---- sanity: we should be inside an Ubuntu LXC, not the Alpine host -------
if [ -f /etc/alpine-release ]; then
    warn "this looks like Alpine — 02-bootstrap-lxc.sh is meant to run INSIDE"
    warn "the Ubuntu LXC. Did you mean 01-create-lxc.sh instead?"
    exit 1
fi

# ---- 1. base apt setup -----------------------------------------------------
log "[1/5] updating apt + installing base tools"
sudo apt-get update -y
sudo apt-get install -y curl ca-certificates gnupg openssh-server sudo

# ---- 2. authorize pubkeys --------------------------------------------------
if [ -z "${SKIP_PUBKEYS:-}" ]; then
    log "[2/5] authorizing pubkeys"
    "$SCRIPT_DIR/authorize-pubkeys.sh"
else
    log "[2/5] skipped (SKIP_PUBKEYS=1)"
fi

# ---- 3. docker -------------------------------------------------------------
if [ -z "${SKIP_DOCKER:-}" ]; then
    log "[3/5] installing docker"
    "$SCRIPT_DIR/install-docker.sh"
else
    log "[3/5] skipped (SKIP_DOCKER=1)"
fi

# ---- 4. sesh ---------------------------------------------------------------
if [ -z "${SKIP_SESH:-}" ]; then
    log "[4/5] installing sesh + scroll + nvim"
    "$SCRIPT_DIR/install-sesh.sh"
else
    log "[4/5] skipped (SKIP_SESH=1)"
fi

# ---- 5. nvm + node ---------------------------------------------------------
if [ -z "${SKIP_NODE:-}" ]; then
    log "[5/5] installing nvm + Node LTS"
    "$SCRIPT_DIR/install-node.sh"
else
    log "[5/5] skipped (SKIP_NODE=1)"
fi

log "all done."
log "next: run ./03-install-tailscale.sh to join the tailnet."
log "(it'll drop your current SSH session — that's expected; reconnect"
log " afterwards via 'ssh \$USER@<tailscale-hostname>')"
