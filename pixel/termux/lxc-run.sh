#!/data/data/com.termux/files/usr/bin/bash
# Run a local script INSIDE the pubuntu LXC (which lives inside Alpine
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
# How it works:
#   1. SSH preflight + verify the LXC is running.
#   2. tar up the script's PARENT DIRECTORY locally — so sibling scripts
#      like authorize-pubkeys.sh / install-docker.sh that 02-bootstrap-lxc.sh
#      references via $SCRIPT_DIR/foo.sh come along automatically. Without
#      this, only the entry script would land inside the LXC and any
#      "$SCRIPT_DIR/sibling.sh" call would fail with "No such file".
#   3. mktemp a working dir inside the LXC's rootfs on Alpine — path looks
#      like /var/lib/lxc/$LXC_NAME/rootfs/tmp/lxc-run.XXXXXX from Alpine,
#      but the same dir appears as /tmp/lxc-run.XXXXXX from inside the
#      LXC (privileged LXC means uid 0 == uid 0, so the file is readable
#      inside).
#   4. Stream the tarball to that dir via SSH, extract.
#   5. ssh -t to Alpine, then `lxc-attach -n $LXC_NAME -- bash <script>`.
#      The `ssh -t` PTY is propagated through lxc-attach to the
#      in-container bash, so interactive `read` and noecho passwd prompts
#      all work.
#   6. Trap-clean the temp dir even if interrupted.
#
# Why not pipe the script via stdin to `lxc-attach -- bash -s`?
#   Stdin would carry the script body, leaving any interactive `read`
#   inside the script reading from the EOF'd pipe instead of the user's
#   terminal. Writing the file in the LXC's rootfs keeps stdin = PTY.
#
# Env / SSH connection:
#   ALPINE_HOST (default: localhost)
#   ALPINE_PORT (default: 9922)
#   ALPINE_USER (default: root)
#   LXC_NAME    (default: pubuntu)
#
# Env passthrough to the in-LXC script (extend the allowlist if needed):
#   SKIP_PUBKEYS, SKIP_DOCKER, SKIP_TOOLCHAINS, SKIP_SESH, SKIP_NODE

set -euo pipefail

if [ "$#" -lt 1 ]; then
    sed -n '2,50p' "$0" >&2
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

LOCAL_SCRIPT_ABS=$(cd "$(dirname "$LOCAL_SCRIPT")" && pwd)/$(basename "$LOCAL_SCRIPT")
SCRIPT_DIR=$(dirname "$LOCAL_SCRIPT_ABS")
SCRIPT_NAME=$(basename "$LOCAL_SCRIPT_ABS")

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

# ---- 3. mktemp working dir inside the LXC's rootfs ------------------------
LXC_ROOTFS="/var/lib/lxc/$LXC_NAME/rootfs"
REMOTE_DIR=$(ssh -p "$ALPINE_PORT" "${ALPINE_USER}@${ALPINE_HOST}" \
    "mktemp -d $LXC_ROOTFS/tmp/lxc-run.XXXXXX")

# Path as seen from INSIDE the LXC (strips the rootfs prefix → /tmp/lxc-run.XXX)
LXC_INTERNAL_DIR="${REMOTE_DIR#$LXC_ROOTFS}"

# ---- 4. tar the script's parent dir, stream + extract on Alpine -----------
# All sibling scripts (authorize-pubkeys.sh, install-*.sh, etc.) come along.
# Cost is negligible — these dirs are <100 KB total.
log "packaging $(basename "$SCRIPT_DIR")/ → ${LXC_NAME}:${LXC_INTERNAL_DIR}/"
tar -C "$SCRIPT_DIR" -cf - . \
    | ssh -p "$ALPINE_PORT" "${ALPINE_USER}@${ALPINE_HOST}" \
            "tar -xf - -C $REMOTE_DIR && chmod -R +x $REMOTE_DIR"

# ---- 5. build env-var preamble + arg quoting -------------------------------
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

log "running $SCRIPT_NAME$QUOTED_ARGS inside LXC '$LXC_NAME'"

# ---- 6. exec with TTY through lxc-attach ----------------------------------
EXIT_CODE=0
ssh -t -p "$ALPINE_PORT" "${ALPINE_USER}@${ALPINE_HOST}" \
    "trap 'rm -rf $REMOTE_DIR' EXIT; lxc-attach -n $LXC_NAME -- ${ENV_PREFIX}bash $LXC_INTERNAL_DIR/$SCRIPT_NAME$QUOTED_ARGS" \
    || EXIT_CODE=$?

exit $EXIT_CODE
