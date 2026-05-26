#!/usr/bin/env bash
# In-LXC SSH bootstrap. Runs INSIDE the LXC (called from the client side
# via pixel/client/helper/lxc-run.sh + pixel/client/06-bootstrap-ssh-lxc.sh).
#
# Three things, all idempotent:
#   1. Install openssh-server if missing; start + enable sshd.
#   2. Generate this LXC's own ed25519 key if ~/.ssh/id_ed25519 is absent
#      — needed if you plan to push from inside the LXC to GitHub or
#      pull from private repos.
#   3. Authorize every pubkey from the repo's pubkeys/ dir into
#      ~/.ssh/authorized_keys.
#
# Counterpart of the curlable <repo>/bootstrap-ssh.sh — that one fetches
# pubkeys over the network; this one reads from the local copy of the
# repo that lxc-run.sh streamed into /tmp/lxc-run.XXX/. No internet
# required during the in-LXC step (apt-get install does need network,
# obviously).
#
# Must be run as the user that will own the keys — NOT as root. The
# client-side wrapper handles that (lxc-run.sh --as <username>).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log()  { printf '\033[1;34m[bootstrap-ssh]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; }

if [ "$(id -u)" -eq 0 ]; then
    warn "running as root — keys will land in /root/.ssh/. If you meant to"
    warn "authorize a regular user, re-run via lxc-run.sh --as <username>."
fi

# ---- 1. install + start sshd ----------------------------------------------
log "[1/3] ensuring openssh-server is installed + running"

need_install=()
command -v sshd >/dev/null 2>&1 || need_install+=(openssh-server)
if [ "${#need_install[@]}" -gt 0 ]; then
    sudo apt-get update -y
    sudo apt-get install -y "${need_install[@]}"
fi

# systemd path on Ubuntu noble; service fallback for non-systemd LXCs
if command -v systemctl >/dev/null 2>&1 && systemctl --no-pager status >/dev/null 2>&1; then
    sudo systemctl enable --now ssh 2>/dev/null \
        || sudo systemctl enable --now sshd 2>/dev/null \
        || warn "  couldn't enable+start ssh via systemctl"
else
    sudo service ssh start 2>/dev/null \
        || sudo service sshd start 2>/dev/null \
        || warn "  couldn't start ssh via service"
fi

# ---- 2. generate this LXC's own ed25519 key if absent ---------------------
log "[2/3] ed25519 key check"

KEY_PATH="$HOME/.ssh/id_ed25519"
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"

if [ ! -f "$KEY_PATH" ]; then
    host_tag=$(hostname 2>/dev/null || echo "lxc")
    log "  generating ed25519 key at $KEY_PATH (no passphrase)"
    ssh-keygen -t ed25519 -N "" -C "${USER}@${host_tag}" -f "$KEY_PATH"
    log "  to push from this LXC to GitHub, add this pubkey to"
    log "  https://github.com/settings/keys :"
    echo
    cat "${KEY_PATH}.pub"
    echo
else
    log "  ssh key already at $KEY_PATH — reusing"
fi

# ---- 3. authorize repo pubkeys --------------------------------------------
log "[3/3] authorizing repo pubkeys"

# authorize-pubkeys.sh lives next to this script. Walks ../../../pubkeys/
# to find the repo's keys (the same path layout works both in the
# checked-out repo and in the lxc-run.sh tar-streamed copy).
"$SCRIPT_DIR/authorize-pubkeys.sh"

log ""
log "SSH bootstrap complete. Test from another device on the tailnet:"
log "  ssh ${USER}@<this-lxc-name>"
