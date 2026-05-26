#!/usr/bin/env bash
# Install + auth Tailscale inside the pubuntu LXC. Workflow (g) from
# pixel/README.md.
#
# Runs pixel/lxc/helper/install-tailscale.sh as the user. Will print a
# Tailscale auth URL — open it on any device and approve.
#
# Note: `tailscale up` reshuffles the LXC's networking. The active SSH
# session this script runs over WILL likely drop right after auth — that's
# expected. You'll re-connect over the new Tailscale-routed IP afterward.
#
# Run from your CLIENT machine. Detects the username from
# /etc/podroid-last-user inside the LXC, or prompts if absent.
#
# Flags:
#   --as <user>   override the auto-detected username

set -euo pipefail

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helper"
. "$_LIB_DIR/_lib.sh"

USERNAME=""
while [ $# -gt 0 ]; do
    case "$1" in
        --as)      USERNAME="$2"; shift 2 ;;
        -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done

if [ -z "$USERNAME" ]; then
    USERNAME=$(lxc_last_user "$LXC_NAME")
fi
if [ -z "$USERNAME" ]; then
    read -r -p "Username to install Tailscale for: " USERNAME
    [ -z "$USERNAME" ] && { err "no username"; exit 1; }
fi

log "Tailscale install + up inside LXC as user '$USERNAME'"
log "(connection will likely drop after 'tailscale up' — that's normal)"
bash "$LSDIR/pixel/client/helper/lxc-run.sh" --as "$USERNAME" \
    "$LSDIR/pixel/lxc/helper/install-tailscale.sh"
