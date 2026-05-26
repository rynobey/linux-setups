#!/usr/bin/env bash
# SSH bootstrap inside the pubuntu LXC. Workflow (e) from pixel/README.md.
#
# Runs pixel/lxc/helper/bootstrap-ssh.sh as the user inside the LXC:
#   - Ensures openssh-server is installed + sshd is running
#   - Generates ed25519 key if absent (so the LXC can ssh OUT to GitHub etc.)
#   - Authorizes pubkeys from this repo's pubkeys/ dir
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
        -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done

if [ -z "$USERNAME" ]; then
    USERNAME=$(lxc_last_user "$LXC_NAME")
fi
if [ -z "$USERNAME" ]; then
    read -r -p "Username to bootstrap SSH for: " USERNAME
    [ -z "$USERNAME" ] && { err "no username"; exit 1; }
fi

log "SSH bootstrap inside LXC as user '$USERNAME'"
bash "$LSDIR/pixel/client/helper/lxc-run.sh" --as "$USERNAME" \
    "$LSDIR/pixel/lxc/helper/bootstrap-ssh.sh"
