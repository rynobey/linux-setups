#!/usr/bin/env bash
# Open an SSH session to the Podroid Ubuntu LXC ('pubuntu' on the
# tailnet by default). Bound to Mod+Shift+Return in the default sway
# config — run via `foot -e connect-dev`.
#
# Usage:
#   connect-dev                 # ssh $USER@pubuntu
#   connect-dev --host alt      # ssh $USER@alt
#   DEV_USER=other connect-dev  # override the user
#
# Env overrides:
#   DEV_USER   default: $USER
#   DEV_HOST   default: pubuntu

set -euo pipefail

DEV_USER="${DEV_USER:-$USER}"
DEV_HOST="${DEV_HOST:-pubuntu}"

while [ $# -gt 0 ]; do
    case "$1" in
        --host) DEV_HOST="$2"; shift 2 ;;
        --user) DEV_USER="$2"; shift 2 ;;
        -h|--help)
            cat <<EOF
connect-dev — ssh into the Podroid LXC

  --host <name>   target host (default: pubuntu)
  --user <name>   target user (default: \$USER)

Env: DEV_USER, DEV_HOST
EOF
            exit 0
            ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done

exec ssh "${DEV_USER}@${DEV_HOST}"
