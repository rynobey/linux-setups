#!/data/data/com.termux/files/usr/bin/bash
# Set up the pubuntu LXC end-to-end, remotely from Termux via SSH.
# Three stages:
#
#   [1/3] alpine-run.sh streams pixel/podroid/01-create-lxc.sh to Alpine,
#         which creates the LXC, applies the privileged + Docker + Tailscale
#         config, and starts it. Runs AS ROOT on Alpine.
#
#   [2/3] lxc-run.sh streams pixel/podroid/create-user.sh into the running
#         LXC. Interactive prompts for username / sudo / shell / password.
#         Runs AS ROOT inside the LXC (it has to be, to call useradd).
#         At the end create-user.sh writes the chosen username to
#         /etc/podroid-last-user so this script can read it back.
#
#   [3/3] lxc-run.sh streams pixel/podroid/02-bootstrap-lxc.sh into the
#         LXC AS THE USER from stage 2 (not root). The full bootstrap
#         (apt, sshd, pubkeys, Docker, toolchains, sesh, Node) happens
#         under that user's home dir and identity. `sudo` calls inside
#         the bootstrap will prompt for the user's password (cached for
#         ~15 min after first entry).
#
# Why bootstrap-as-user matters: running as root would mean ~/.ssh,
# ~/.nvm, ~/.docker/etc all end up in /root/. After Tailscale is set
# up and you ssh in as the regular user, none of that is there. Doing
# the bootstrap as the eventual interactive user is the only way for
# the artifacts to land in their home dir.
#
# Usage:
#   bash setup-pubuntu-lxc.sh                   # all three stages
#   bash setup-pubuntu-lxc.sh --skip-user       # skip stage 2 (user already exists)
#   bash setup-pubuntu-lxc.sh --skip-bootstrap  # skip stage 3 (manual bootstrap later)
#   LXC_NAME=foo bash setup-pubuntu-lxc.sh
#
# Prerequisites:
#   - Podroid VM running, Alpine sshd reachable on localhost:9922
#   - Termux's ~/.ssh/id_ed25519.pub authorized as root@alpine
#
# Env overrides forwarded to podroid/01-create-lxc.sh:
#   LXC_NAME, LXC_DIST, LXC_RELEASE, LXC_ARCH, SHARED_HOST, SHARED_GUEST

set -euo pipefail

LSDIR="${LINUX_SETUPS_DIR:-$HOME/linux-setups}"
LXC_NAME="${LXC_NAME:-pubuntu}"
ALPINE_HOST="${ALPINE_HOST:-localhost}"
ALPINE_PORT="${ALPINE_PORT:-9922}"
ALPINE_USER="${ALPINE_USER:-root}"

SKIP_USER=0
SKIP_BOOTSTRAP=0
PASSTHROUGH_ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --skip-user)      SKIP_USER=1; shift ;;
        --skip-bootstrap) SKIP_BOOTSTRAP=1; shift ;;
        -h|--help)        sed -n '2,40p' "$0"; exit 0 ;;
        *)                PASSTHROUGH_ARGS+=("$1"); shift ;;
    esac
done

log()  { printf '\033[1;34m[setup-pubuntu-lxc]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; }

# ---- [1/3] create / refresh the LXC on Alpine -----------------------------
log "[1/3] creating LXC on Alpine (root)"
bash "$LSDIR/pixel/termux/alpine-run.sh" \
    "$LSDIR/pixel/podroid/01-create-lxc.sh" "${PASSTHROUGH_ARGS[@]}"

# ---- [2/3] create the user inside the LXC ---------------------------------
if [ "$SKIP_USER" -eq 1 ]; then
    log "[2/3] skipped user creation (--skip-user)"
else
    log "[2/3] creating user inside the LXC (root)"
    log "      interactive — username / sudo / shell / password prompts ahead"
    bash "$LSDIR/pixel/termux/lxc-run.sh" \
        "$LSDIR/pixel/podroid/create-user.sh"
fi

# ---- [3/3] bootstrap the LXC AS THAT USER ---------------------------------
if [ "$SKIP_BOOTSTRAP" -eq 1 ]; then
    log "[3/3] skipped bootstrap (--skip-bootstrap)"
    log ""
    log "To finish manually, find the username and run:"
    log "  ssh root@${ALPINE_HOST} -p ${ALPINE_PORT} 'cat /var/lib/lxc/${LXC_NAME}/rootfs/etc/podroid-last-user'"
    log "  LXC_USER=<that-username> bash $LSDIR/pixel/termux/lxc-run.sh \\"
    log "    $LSDIR/pixel/podroid/02-bootstrap-lxc.sh"
    exit 0
fi

# Read the freshly-created username from inside the LXC's rootfs (visible
# from Alpine without needing lxc-attach — just a regular file at a known
# path). Falls back to prompting if the file is missing.
LXC_ROOTFS_USER_FILE="/var/lib/lxc/${LXC_NAME}/rootfs/etc/podroid-last-user"
USERNAME=$(ssh -p "$ALPINE_PORT" "${ALPINE_USER}@${ALPINE_HOST}" \
    "cat $LXC_ROOTFS_USER_FILE 2>/dev/null" || true)

if [ -z "$USERNAME" ]; then
    warn "couldn't read $LXC_ROOTFS_USER_FILE — create-user.sh may have been skipped"
    read -r -p "Username to run bootstrap as: " USERNAME
    if [ -z "$USERNAME" ]; then
        err "no username provided; can't run bootstrap"
        exit 1
    fi
fi

log "[3/3] running 02-bootstrap-lxc.sh inside LXC as user '$USERNAME'"
log "      sudo prompts ahead — enter $USERNAME's password when asked"
bash "$LSDIR/pixel/termux/lxc-run.sh" --as "$USERNAME" \
    "$LSDIR/pixel/podroid/02-bootstrap-lxc.sh"

log ""
log "Done. LXC '${LXC_NAME}' is up, user '$USERNAME' is bootstrapped."
log ""
log "Next manual step: Tailscale (split out from bootstrap because"
log "'tailscale up' reshuffles networking and drops the active SSH session):"
log "  bash $LSDIR/pixel/termux/lxc-run.sh --as $USERNAME \\"
log "    $LSDIR/pixel/podroid/03-install-tailscale.sh"
