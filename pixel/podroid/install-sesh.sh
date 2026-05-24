#!/usr/bin/env bash
# Install ryno's `sesh` (tmux session manager + scroll + nvim-columns)
# on the AVF VM. Clones from GitHub over SSH, then runs the project's
# own install.sh (which handles apt deps + binary placement).
#
# Usage:
#   ./install-sesh.sh           # first install (or pull-and-rerun if cloned)
#   ./install-sesh.sh --force   # forwarded to sesh/install.sh
#
# Env overrides:
#   SESH_REPO   default: git@github.com:rynobey/sesh.git
#   SESH_DIR    default: ~/projects/sesh
#   SESH_REF    default: main  (branch/tag to check out after clone/pull)
#
# Prereq: SSH-to-GitHub set up on this VM. If not, the script prints
# clear instructions and exits.

set -euo pipefail

REPO_URL="${SESH_REPO:-git@github.com:rynobey/sesh.git}"
INSTALL_DIR="${SESH_DIR:-$HOME/projects/sesh}"
REF="${SESH_REF:-main}"

log()  { printf '\033[1;34m[install-sesh]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; }

# ---- git ---------------------------------------------------------------------
if ! command -v git >/dev/null 2>&1; then
    log "Installing git"
    sudo apt-get update -y
    sudo apt-get install -y git
fi

# ---- GitHub SSH access check -------------------------------------------------
# Only meaningful for SSH-form URLs. HTTPS URLs we leave to git's own auth.
if [[ "$REPO_URL" == git@github.com:* ]]; then
    log "Verifying SSH access to github.com"
    # GitHub's SSH server replies "Hi <user>! You've successfully authenticated…"
    # then closes (exit 1). We grep stderr for the success message.
    ssh_out=$(ssh -T -o StrictHostKeyChecking=accept-new -o BatchMode=yes git@github.com 2>&1 || true)
    if ! grep -q "successfully authenticated" <<<"$ssh_out"; then
        err "SSH-to-GitHub is not set up for this VM."
        cat <<EOF >&2

To fix (run on this VM, then add the key to your GitHub account):

  ssh-keygen -t ed25519 -C "pixel-avf"
  cat ~/.ssh/id_ed25519.pub

Then paste the output at:

  https://github.com/settings/keys   (account-wide key)
  or, for repo-scoped access:
  https://github.com/rynobey/sesh/settings/keys/new   (deploy key)

Once added, re-run this script.

Alternative: set SESH_REPO to the HTTPS URL and supply credentials:
  SESH_REPO=https://github.com/rynobey/sesh.git ./install-sesh.sh
EOF
        exit 1
    fi
    log "GitHub SSH access confirmed"
fi

# ---- Clone or update ---------------------------------------------------------
if [ -d "$INSTALL_DIR/.git" ]; then
    log "Updating existing clone at $INSTALL_DIR"
    git -C "$INSTALL_DIR" fetch --quiet
    git -C "$INSTALL_DIR" checkout --quiet "$REF"
    git -C "$INSTALL_DIR" pull --rebase --quiet
else
    log "Cloning $REPO_URL into $INSTALL_DIR"
    mkdir -p "$(dirname "$INSTALL_DIR")"
    git clone --quiet "$REPO_URL" "$INSTALL_DIR"
    git -C "$INSTALL_DIR" checkout --quiet "$REF"
fi

# ---- Run sesh's own installer ------------------------------------------------
if [ ! -x "$INSTALL_DIR/install.sh" ]; then
    err "$INSTALL_DIR/install.sh not found or not executable."
    err "Has the repo layout changed? Check the clone manually."
    exit 1
fi

log "Running $INSTALL_DIR/install.sh $*"
cd "$INSTALL_DIR"
./install.sh "$@"

log "sesh install complete."
log "Start a fresh shell (or 'source ~/.bashrc') if PATH/keybindings need refreshing,"
log "then run 'sesh' inside a terminal to enter a session."
