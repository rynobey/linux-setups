#!/usr/bin/env bash
# Bootstrap git on a fresh device: install git, walk through adding
# this device's existing SSH key to GitHub, then clone the linux-setups
# repo via SSH so this device can also push.
#
# Does NOT generate SSH keys anymore — that responsibility moved to
# bootstrap-ssh.sh (curlable, sister script) and pixel/lxc/helper/
# bootstrap-ssh.sh (in-LXC). Run one of those first if ~/.ssh/id_ed25519
# doesn't exist yet — this script will fail-fast otherwise.
#
# Run interactively (needs a controlling terminal for the GitHub-paste
# pause). The prompt reads from /dev/tty so curl|bash works:
#   curl -fsSL https://raw.githubusercontent.com/rynobey/linux-setups/master/bootstrap-git.sh | bash
# If that prompt is unhappy, download first:
#   curl -fsSL https://raw.githubusercontent.com/rynobey/linux-setups/master/bootstrap-git.sh -o bootstrap-git.sh
#   bash bootstrap-git.sh
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

log()  { printf '\033[1;34m[bootstrap-git]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; }

# read-from-tty wrapper so the script works under `curl | bash`
prompt() {
    local msg="$1"
    if [ -t 0 ]; then
        read -r -p "$msg"
    elif [ -r /dev/tty ]; then
        read -r -p "$msg" < /dev/tty
    else
        err "no terminal available for prompt — download the script first: curl -o bootstrap-git.sh ... && bash bootstrap-git.sh"
        exit 1
    fi
}

# ---- package manager detection ---------------------------------------------
# Termux gets its own branch because it has no sudo, no systemctl, and
# its `apt` is configured for the user (not via sudo). The `pkg` wrapper
# is the canonical way to install packages on Termux.
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

# ---- git + ssh client ------------------------------------------------------
# Termux ships openssh as a single package (no -client suffix); apt/apk
# use openssh-client for the client side.
case "$PKG_FAMILY" in
    termux) ssh_pkg=openssh ;;
    *)      ssh_pkg=openssh-client ;;
esac
need_install=()
command -v git        >/dev/null 2>&1 || need_install+=(git)
command -v ssh-keygen >/dev/null 2>&1 || need_install+=("$ssh_pkg")
if [ "${#need_install[@]}" -gt 0 ]; then
    log "installing: ${need_install[*]}"
    pkg_install "${need_install[@]}"
fi

# ---- verify SSH key exists -------------------------------------------------
# Key generation moved to bootstrap-ssh.sh (curlable) and
# pixel/lxc/helper/bootstrap-ssh.sh (in-LXC). If you're seeing the error
# below, run one of those first.
KEY_PATH="$HOME/.ssh/id_ed25519"
if [ ! -f "$KEY_PATH" ]; then
    err "no SSH key at $KEY_PATH — bootstrap-git.sh no longer generates one."
    err "Run bootstrap-ssh.sh first to create + authorize a key:"
    err "  curl -fsSL https://raw.githubusercontent.com/rynobey/linux-setups/master/bootstrap-ssh.sh | bash"
    err "or inside an LXC, run pixel/client/06-bootstrap-ssh-lxc.sh from the client."
    exit 1
fi
log "ssh key present at $KEY_PATH"

# ---- prompt user to add it to GitHub ---------------------------------------
cat <<EOF

================================================================
Add this PUBLIC key to your GitHub account:

  https://github.com/settings/keys   (account-wide; recommended)

----- BEGIN PUBKEY -----
$(cat "${KEY_PATH}.pub")
----- END PUBKEY -----
================================================================

EOF
prompt "Press <enter> once the key has been added to GitHub..."

# ---- verify ssh-to-github --------------------------------------------------
log "testing ssh -T git@github.com"
ssh_out=$(ssh -T -o StrictHostKeyChecking=accept-new -o BatchMode=yes git@github.com 2>&1 || true)
if ! grep -q "successfully authenticated" <<<"$ssh_out"; then
    err "SSH-to-GitHub failed. Output:"
    echo "$ssh_out" >&2
    err "make sure the pubkey above is added to https://github.com/settings/keys"
    exit 1
fi
log "ssh-to-github confirmed"

# ---- clone the repo --------------------------------------------------------
if [ -d "$CLONE_DIR/.git" ]; then
    log "$CLONE_DIR already cloned — leaving it alone"
else
    log "cloning into $CLONE_DIR"
    mkdir -p "$(dirname "$CLONE_DIR")"
    git clone "git@github.com:${REPO_OWNER}/${REPO_NAME}.git" "$CLONE_DIR"
fi

log "done — repo at $CLONE_DIR"
log "next: cd $CLONE_DIR && open pixel/README.md"
