#!/usr/bin/env bash
# Bootstrap git on a fresh device for read-only / public-repo workflows.
# Installs git, clones the linux-setups repo over HTTPS — no SSH key,
# no GitHub account setup needed.
#
# Use this if you don't need to push from this device (e.g. you're
# bootstrapping a throwaway VM or a recovery shell). For full
# read-write access with this device's own GitHub identity, use
# bootstrap-git.sh instead.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/rynobey/linux-setups/master/bootstrap-git-public.sh | bash
#
# Env overrides:
#   LINUX_SETUPS_DIR  default: ~/projects/linux-setups
#   REPO_OWNER        default: rynobey
#   REPO_NAME         default: linux-setups
#
# Idempotent: skips the clone if the target dir already has a .git/.

set -euo pipefail

REPO_OWNER="${REPO_OWNER:-rynobey}"
REPO_NAME="${REPO_NAME:-linux-setups}"
CLONE_DIR="${LINUX_SETUPS_DIR:-$HOME/projects/linux-setups}"

log()  { printf '\033[1;34m[bootstrap-git-public]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; }

# ---- package manager detection ---------------------------------------------
# Termux branch: no sudo, `pkg` wrapper instead of raw apt/apk.
if [ -n "${PREFIX:-}" ] && [ -x "${PREFIX}/bin/pkg" ]; then
    PKG_FAMILY=termux
elif command -v apt-get >/dev/null 2>&1; then
    PKG_FAMILY=apt
elif command -v apk >/dev/null 2>&1; then
    PKG_FAMILY=apk
else
    err "no supported package manager (apt-get, apk, or Termux pkg)."
    exit 1
fi

pkg_install() {
    case "$PKG_FAMILY" in
        apt)    sudo apt-get update -y && sudo apt-get install -y "$@" ;;
        apk)    sudo apk add --no-cache "$@" ;;
        termux) pkg install -y "$@" ;;
    esac
}

# ---- git -------------------------------------------------------------------
need_install=()
command -v git >/dev/null 2>&1 || need_install+=(git)
# ca-certificates so HTTPS clones don't blow up on minimal images
[ -d /etc/ssl/certs ] || need_install+=(ca-certificates)
if [ "${#need_install[@]}" -gt 0 ]; then
    log "installing: ${need_install[*]}"
    pkg_install "${need_install[@]}"
fi

# ---- clone over HTTPS ------------------------------------------------------
if [ -d "$CLONE_DIR/.git" ]; then
    log "$CLONE_DIR already cloned — leaving it alone"
else
    log "cloning https://github.com/${REPO_OWNER}/${REPO_NAME}.git into $CLONE_DIR"
    mkdir -p "$(dirname "$CLONE_DIR")"
    git clone "https://github.com/${REPO_OWNER}/${REPO_NAME}.git" "$CLONE_DIR"
fi

log "done — repo at $CLONE_DIR"
log "note: HTTPS clone is pull-only without a credential helper. If you"
log "      later want to push from this device, run bootstrap-git.sh to"
log "      add this device's SSH key to your GitHub account, then:"
log "        cd $CLONE_DIR && git remote set-url origin git@github.com:${REPO_OWNER}/${REPO_NAME}.git"
