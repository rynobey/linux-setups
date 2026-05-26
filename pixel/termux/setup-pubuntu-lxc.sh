#!/data/data/com.termux/files/usr/bin/bash
# Create the pubuntu LXC inside Alpine, remotely from Termux via SSH.
# Thin wrapper around alpine-run.sh + pixel/podroid/01-create-lxc.sh.
#
# Usage:
#   bash setup-pubuntu-lxc.sh
#   LXC_NAME=foo bash setup-pubuntu-lxc.sh   # override the LXC name
#
# Prerequisites:
#   - Podroid VM running, sshd inside Alpine reachable on localhost:9922
#   - Termux's ~/.ssh/id_ed25519.pub is in Alpine's /root/.ssh/authorized_keys
#
# Env overrides forwarded to podroid/01-create-lxc.sh:
#   LXC_NAME, LXC_DIST, LXC_RELEASE, LXC_ARCH, SHARED_HOST, SHARED_GUEST

set -euo pipefail

LSDIR="${LINUX_SETUPS_DIR:-$HOME/linux-setups}"
exec bash "$LSDIR/pixel/termux/alpine-run.sh" \
    "$LSDIR/pixel/podroid/01-create-lxc.sh" "$@"
