#!/usr/bin/env bash
# Single entry point for installing dev tools on the Pixel AVF VM.
#
# Prereq (do this once, manually — install-sesh.sh will exit with clear
# instructions if it's missing):
#   - SSH-to-GitHub set up:
#       ssh-keygen -t ed25519 -C "pixel-avf"
#       # paste ~/.ssh/id_ed25519.pub into https://github.com/settings/keys
#
# Usage:
#   ./setup.sh           # install everything
#   ./setup.sh --force   # forwarded to sesh's install.sh (overwrites user configs)
#
# Installs (in order):
#   1. git + sesh (clones rynobey/sesh, runs its install.sh)
#   2. nvm + latest Node LTS (+ bundled npm)
#
# Earlier steps in the per-setup flow (Tailscale, user creation, sshd
# hardening) are documented in README.md and are not part of this entry
# script — they're done once during initial bootstrap.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { printf '\033[1;32m[setup]\033[0m %s\n' "$*"; }

log "1/2 — installing git + sesh"
"$SCRIPT_DIR/install-sesh.sh" "$@"

log "2/2 — installing nvm + Node LTS"
"$SCRIPT_DIR/install-node.sh"

log "All done."
