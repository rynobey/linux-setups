#!/data/data/com.termux/files/usr/bin/bash
# Run any local script INSIDE the pubuntu LXC (which lives inside Alpine
# which lives inside Podroid), without requiring linux-setups to be
# cloned in either Alpine or the LXC.
#
# Usage:
#   bash lxc-run.sh <local-script-path> [args-to-script ...]
#
# Examples:
#   bash lxc-run.sh ../podroid/create-user.sh
#   bash lxc-run.sh ../podroid/02-bootstrap-lxc.sh
#   LXC_NAME=foo bash lxc-run.sh ../podroid/install-docker.sh
#
# How it works (different from alpine-run.sh because of the extra
# namespace hop):
#   1. SSH preflight to Alpine (same as alpine-run.sh)
#   2. mktemp inside the LXC's rootfs on Alpine — path looks like
#      /var/lib/lxc/$LXC_NAME/rootfs/tmp/lxc-run.XXXXXX from Alpine's
#      view, but the same file appears as /tmp/lxc-run.XXXXXX from
#      inside the LXC. Privileged LXC means uid 0 in Alpine == uid 0
#      in pubuntu, so the file is readable inside.
#   3. Stream the script body to that file via SSH.
#   4. ssh -t to Alpine, then `lxc-attach -n $LXC_NAME -- bash /tmp/...`.
#      The `ssh -t` PTY is propagated through lxc-attach to the
#      in-container bash, so create-user.sh's `read` and passwd's
#      noecho prompt all work interactively.
#   5. Trap-clean the temp file even if interrupted.
#
# Why not pipe the script via stdin to `lxc-attach -- bash -s` ?
#   Because that hijacks stdin with the script content, and any
#   interactive `read` inside the script then reads from the same
#   pipe instead of the user's terminal. Writing to a file in the
#   LXC's rootfs lets bash exec the FILE while stdin stays the PTY.
#
# Env / SSH connection (same defaults as alpine-run.sh):
#   ALPINE_HOST (default: localhost)
#   ALPINE_PORT (default: 9922)
#   ALPINE_USER (default: root)
#
# Env passthrough to the in-LXC script (extend the allowlist if needed):
#   LXC_NAME (which LXC to attach into, default: pubuntu)
#   SKIP_PUBKEYS, SKIP_DOCKER, SKIP_TOOLCHAINS, SKIP_SESH, SKIP_NODE

set -euo pipefail

if [ "$#" -lt 1 ]; then
    sed -n '2,45p' "$0" >&2
    exit 2
fi

LOCAL_SCRIPT="$1"
shift

ALPINE_HOST="${ALPINE_HOST:-localhost}"
ALPINE_PORT="${ALPINE_PORT:-9922}"
ALPINE_USER="${ALPINE_USER:-root}"
LXC_NAME="${LXC_NAME:-pubuntu}"

ENV_VARS_PASSTHROUGH=(
    SKIP_PUBKEYS SKIP_DOCKER SKIP_TOOLCHAINS SKIP_SESH SKIP_NODE
)

log()  { printf '\033[1;34m[lxc-run]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; }

# ---- 1. local script must exist -------------------------------------------
if [ ! -f "$LOCAL_SCRIPT" ]; then
    err "$LOCAL_SCRIPT not found (cwd: $(pwd))"
    exit 1
fi

# ---- 2. SSH preflight + verify the LXC is running -------------------------
if ! ssh -p "$ALPINE_PORT" -o ConnectTimeout=5 -o BatchMode=yes \
        "${ALPINE_USER}@${ALPINE_HOST}" 'true' 2>/dev/null; then
    err "can't SSH to ${ALPINE_USER}@${ALPINE_HOST}:${ALPINE_PORT}"
    err "is Podroid VM running with Alpine sshd reachable?"
    exit 1
fi

STATE=$(ssh -p "$ALPINE_PORT" "${ALPINE_USER}@${ALPINE_HOST}" \
    "lxc-info -n $LXC_NAME -s 2>/dev/null | awk '{print \$2}'" 2>/dev/null || echo "")
if [ "$STATE" != "RUNNING" ]; then
    err "LXC '$LXC_NAME' is not running (state: ${STATE:-unknown})"
    err "  start it on Alpine first:  lxc-start -n $LXC_NAME"
    err "  or run pixel/termux/setup-pubuntu-lxc.sh to create+start it"
    exit 1
fi

# ---- 3. copy script to a file inside the LXC's rootfs ---------------------
LXC_ROOTFS="/var/lib/lxc/$LXC_NAME/rootfs"
REMOTE_FILE=$(ssh -p "$ALPINE_PORT" "${ALPINE_USER}@${ALPINE_HOST}" \
    "mktemp $LXC_ROOTFS/tmp/lxc-run.XXXXXX")

# What the file path looks like from INSIDE the LXC (just /tmp/lxc-run.XXX)
LXC_INTERNAL_PATH="${REMOTE_FILE#$LXC_ROOTFS}"

cat "$LOCAL_SCRIPT" | ssh -p "$ALPINE_PORT" "${ALPINE_USER}@${ALPINE_HOST}" \
    "cat > $REMOTE_FILE && chmod +x $REMOTE_FILE"

# ---- 4. build env-var preamble + arg quoting -------------------------------
ENV_PREFIX=""
for var in "${ENV_VARS_PASSTHROUGH[@]}"; do
    if [ -n "${!var:-}" ]; then
        ENV_PREFIX+="$var=$(printf '%q' "${!var}") "
    fi
done

QUOTED_ARGS=""
for a in "$@"; do
    QUOTED_ARGS+=" $(printf '%q' "$a")"
done

log "running $(basename "$LOCAL_SCRIPT")$QUOTED_ARGS inside LXC '$LXC_NAME'"

# ---- 5. exec with TTY through lxc-attach ----------------------------------
EXIT_CODE=0
ssh -t -p "$ALPINE_PORT" "${ALPINE_USER}@${ALPINE_HOST}" \
    "trap 'rm -f $REMOTE_FILE' EXIT; lxc-attach -n $LXC_NAME -- ${ENV_PREFIX}bash $LXC_INTERNAL_PATH$QUOTED_ARGS" \
    || EXIT_CODE=$?

exit $EXIT_CODE
