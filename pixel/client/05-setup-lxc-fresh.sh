#!/usr/bin/env bash
# Full fresh LXC setup, no restore. Workflow (d) from pixel/README.md.
#
# Five sequential stages:
#   [1/5] Create LXC on Alpine via pixel/podroid/helper/create-lxc.sh
#         (root on Alpine; lxc-create + config patch + start)
#   [2/5] Create user inside LXC via pixel/lxc/helper/create-user.sh
#         (root in LXC; interactive prompts for name/sudo/shell/password)
#   [3/5] SSH bootstrap inside LXC as the new user
#         (key gen + sshd + authorize-pubkeys)
#   [4/5] Deps bootstrap inside LXC as the user
#         (Docker, toolchains, sesh, Node)
#   [5/5] Tailscale install + up
#
# Stages 3-5 each run AS THE USER (not root) so $HOME/.* artifacts land
# under their account, not /root/.
#
# Run from your CLIENT machine.
#
# Prereqs:
#   - Podroid VM running, Alpine sshd reachable
#   - This client's pubkey authorized as root on Alpine
#
# Flags:
#   --skip-user        don't create user (user must already exist;
#                      will be read from /etc/podroid-last-user inside LXC)
#   --skip-ssh         skip SSH bootstrap
#   --skip-deps        skip deps bootstrap
#   --skip-tailscale   skip Tailscale
#   --skip-bootstrap   shortcut for --skip-ssh --skip-deps --skip-tailscale
#                      (useful when called from 04-restore-lxc.sh — the
#                      restored LXC already has all this state)

set -euo pipefail

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helper"
. "$_LIB_DIR/_lib.sh"

SKIP_USER=0
SKIP_SSH=0
SKIP_DEPS=0
SKIP_TAILSCALE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --skip-user)      SKIP_USER=1; shift ;;
        --skip-ssh)       SKIP_SSH=1; shift ;;
        --skip-deps)      SKIP_DEPS=1; shift ;;
        --skip-tailscale) SKIP_TAILSCALE=1; shift ;;
        --skip-bootstrap) SKIP_SSH=1; SKIP_DEPS=1; SKIP_TAILSCALE=1; shift ;;
        -h|--help)        sed -n '2,33p' "$0"; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done

# ---- [1/5] create LXC on Alpine -------------------------------------------
log "[1/5] creating LXC on Alpine (root)"
bash "$LSDIR/pixel/client/helper/alpine-run.sh" \
    "$LSDIR/pixel/podroid/helper/create-lxc.sh"

# ---- [2/5] create user inside LXC -----------------------------------------
if [ "$SKIP_USER" -eq 1 ]; then
    log "[2/5] skipped user creation (--skip-user)"
else
    log "[2/5] creating user inside the LXC (root); interactive prompts ahead"
    bash "$LSDIR/pixel/client/helper/lxc-run.sh" \
        "$LSDIR/pixel/lxc/helper/create-user.sh"
fi

# ---- discover the username for stages 3-5 ---------------------------------
# create-user.sh wrote /etc/podroid-last-user; read it from outside.
USERNAME=$(lxc_last_user "$LXC_NAME")
if [ -z "$USERNAME" ] && { [ "$SKIP_SSH" -eq 0 ] || [ "$SKIP_DEPS" -eq 0 ] || [ "$SKIP_TAILSCALE" -eq 0 ]; }; then
    warn "/etc/podroid-last-user not found inside the LXC."
    read -r -p "Username to run remaining stages as: " USERNAME
    if [ -z "$USERNAME" ]; then
        err "no username; can't run stages 3-5 as a non-root user"
        exit 1
    fi
fi

# ---- [3/5] SSH bootstrap inside LXC, as the user --------------------------
if [ "$SKIP_SSH" -eq 1 ]; then
    log "[3/5] skipped SSH bootstrap (--skip-ssh)"
else
    log "[3/5] SSH bootstrap inside LXC as user '$USERNAME'"
    log "      first sudo will prompt for $USERNAME's password (cached afterward)"
    bash "$LSDIR/pixel/client/helper/lxc-run.sh" --as "$USERNAME" \
        "$LSDIR/pixel/lxc/helper/bootstrap-ssh.sh"
fi

# ---- [4/5] deps bootstrap inside LXC, as the user -------------------------
if [ "$SKIP_DEPS" -eq 1 ]; then
    log "[4/5] skipped deps bootstrap (--skip-deps)"
else
    log "[4/5] deps bootstrap inside LXC as user '$USERNAME'"
    bash "$LSDIR/pixel/client/helper/lxc-run.sh" --as "$USERNAME" \
        "$LSDIR/pixel/lxc/helper/bootstrap-deps.sh"
fi

# ---- [5/5] Tailscale ------------------------------------------------------
if [ "$SKIP_TAILSCALE" -eq 1 ]; then
    log "[5/5] skipped Tailscale (--skip-tailscale)"
else
    log "[5/5] Tailscale install inside LXC as user '$USERNAME'"
    log "      'tailscale up' will reshuffle networking — this SSH session may drop"
    bash "$LSDIR/pixel/client/helper/lxc-run.sh" --as "$USERNAME" \
        "$LSDIR/pixel/lxc/helper/install-tailscale.sh"
fi

log ""
log "Done. LXC '$LXC_NAME' is ready; user '${USERNAME:-?}' bootstrapped."
log "From here you can ssh into the LXC via Tailscale: ssh $USERNAME@$LXC_NAME"
