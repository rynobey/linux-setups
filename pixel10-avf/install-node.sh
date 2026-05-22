#!/usr/bin/env bash
# Install nvm and the latest Node.js LTS (with bundled npm) on the AVF VM.
#
# Usage:
#   ./install-node.sh
#
# Env overrides:
#   NVM_VERSION   default: v0.40.1  (nvm release tag to install)
#   NVM_DIR       default: ~/.nvm
#
# Idempotent: skips the nvm install if ${NVM_DIR}/nvm.sh already exists,
# and `nvm install --lts` is itself a no-op when the latest LTS is
# already current.

# Note: deliberately no `-u`. nvm's shell code references unset
# variables internally (e.g. nvm.sh:3885 PROVIDED_VERSION), so sourcing
# it or calling `nvm use` under nounset aborts the script.
set -eo pipefail

NVM_VERSION="${NVM_VERSION:-v0.40.1}"
NVM_DIR="${NVM_DIR:-$HOME/.nvm}"

log()  { printf '\033[1;34m[install-node]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }

# ---- curl (needed for the nvm installer) -------------------------------------
if ! command -v curl >/dev/null 2>&1; then
    log "Installing curl"
    sudo apt-get update -y
    sudo apt-get install -y curl
fi

# ---- nvm ---------------------------------------------------------------------
if [ -s "${NVM_DIR}/nvm.sh" ]; then
    log "nvm already installed at ${NVM_DIR}"
else
    log "Installing nvm ${NVM_VERSION}"
    curl -fsSL "https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh" | bash
fi

# Load nvm into this shell. The installer also appends these lines to
# ~/.bashrc (and ~/.zshrc if present) for future shells.
export NVM_DIR
# shellcheck source=/dev/null
. "${NVM_DIR}/nvm.sh"

# ---- Node LTS ----------------------------------------------------------------
log "Installing latest Node LTS via nvm"
nvm install --lts
nvm alias default 'lts/*'
nvm use --lts

log "node $(node --version) / npm $(npm --version)"
log "Open a new shell (or 'source ~/.bashrc') to pick up nvm on PATH."
