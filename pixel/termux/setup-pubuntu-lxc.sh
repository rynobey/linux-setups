#!/data/data/com.termux/files/usr/bin/bash
# Create the pubuntu LXC inside Alpine + create your user inside the LXC,
# remotely from Termux via SSH. Two stages:
#
#   1. alpine-run.sh streams pixel/podroid/01-create-lxc.sh to Alpine,
#      which creates the LXC, applies the privileged + Docker + Tailscale
#      config, and starts it.
#
#   2. lxc-run.sh streams pixel/podroid/create-user.sh into the running
#      LXC via lxc-attach, which interactively prompts for username /
#      sudo / shell / password (the prompts come through ssh -t).
#
# Skip the user-create stage with --skip-user (e.g. when re-running just
# to refresh the LXC config and you've already created your user).
#
# Usage:
#   bash setup-pubuntu-lxc.sh
#   bash setup-pubuntu-lxc.sh --skip-user
#   LXC_NAME=foo bash setup-pubuntu-lxc.sh   # override default LXC name
#
# Prerequisites:
#   - Podroid VM running, Alpine sshd reachable on localhost:9922
#   - Termux's ~/.ssh/id_ed25519.pub authorized as root@alpine
#
# Env overrides forwarded to podroid/01-create-lxc.sh:
#   LXC_NAME, LXC_DIST, LXC_RELEASE, LXC_ARCH, SHARED_HOST, SHARED_GUEST

set -euo pipefail

LSDIR="${LINUX_SETUPS_DIR:-$HOME/linux-setups}"

SKIP_USER=0
PASSTHROUGH_ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --skip-user) SKIP_USER=1; shift ;;
        -h|--help)   sed -n '2,28p' "$0"; exit 0 ;;
        *)           PASSTHROUGH_ARGS+=("$1"); shift ;;
    esac
done

log()  { printf '\033[1;34m[setup-pubuntu-lxc]\033[0m %s\n' "$*"; }

# ---- 1. create / refresh the LXC on Alpine --------------------------------
log "[1/2] creating LXC via alpine-run.sh + 01-create-lxc.sh"
bash "$LSDIR/pixel/termux/alpine-run.sh" \
    "$LSDIR/pixel/podroid/01-create-lxc.sh" "${PASSTHROUGH_ARGS[@]}"

# ---- 2. create the user inside the LXC ------------------------------------
if [ "$SKIP_USER" -eq 1 ]; then
    log "[2/2] skipping create-user.sh (--skip-user)"
else
    log "[2/2] creating user inside the LXC via lxc-run.sh + create-user.sh"
    log "       (interactive — username/sudo/shell/password prompts ahead)"
    bash "$LSDIR/pixel/termux/lxc-run.sh" \
        "$LSDIR/pixel/podroid/create-user.sh"
fi

log ""
log "Done. The LXC is up and your user is created."
log ""
log "To continue bootstrapping (Docker, Tailscale, sesh, nvm) inside the LXC:"
log "  bash $LSDIR/pixel/termux/lxc-run.sh \\"
log "    $LSDIR/pixel/podroid/02-bootstrap-lxc.sh"
