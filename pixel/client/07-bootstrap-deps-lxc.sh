#!/usr/bin/env bash
# Deps bootstrap inside the pubuntu LXC. Workflow (f) from pixel/README.md.
#
# Runs pixel/lxc/helper/bootstrap-deps.sh as the user — installs Docker,
# build toolchains (gcc, Go, pkg-config), sesh + scroll + nvim, nvm + Node.
# Tailscale is intentionally separate (workflow g + 08-install-tailscale-lxc.sh)
# because `tailscale up` reshuffles networking and drops this SSH session.
#
# Run from your CLIENT machine. Detects the username from
# /etc/podroid-last-user inside the LXC, or prompts if absent.
#
# Env vars forwarded to bootstrap-deps.sh:
#   SKIP_DOCKER, SKIP_TOOLCHAINS, SKIP_SESH, SKIP_NODE
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
        -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done

if [ -z "$USERNAME" ]; then
    USERNAME=$(lxc_last_user "$LXC_NAME")
fi
if [ -z "$USERNAME" ]; then
    read -r -p "Username to bootstrap deps for: " USERNAME
    [ -z "$USERNAME" ] && { err "no username"; exit 1; }
fi

log "Deps bootstrap inside LXC as user '$USERNAME'"
log "(first sudo will prompt for $USERNAME's password)"
bash "$LSDIR/pixel/client/helper/lxc-run.sh" --as "$USERNAME" \
    "$LSDIR/pixel/lxc/helper/bootstrap-deps.sh"
