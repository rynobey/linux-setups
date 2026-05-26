#!/data/data/com.termux/files/usr/bin/bash
# Run a local script INSIDE the pubuntu LXC (which lives inside Alpine
# which lives inside Podroid), without requiring linux-setups to be
# cloned in either Alpine or the LXC.
#
# Usage:
#   bash lxc-run.sh [--as <username>] <local-script-path> [args-to-script ...]
#
# Examples:
#   bash lxc-run.sh ../podroid/create-user.sh
#   bash lxc-run.sh --as ryno ../podroid/02-bootstrap-lxc.sh
#   LXC_NAME=foo LXC_USER=ryno bash lxc-run.sh ../podroid/install-docker.sh
#
# By default the script runs inside the LXC as root (uid 0). Pass --as
# <username> (or set LXC_USER) to switch to a non-root user — uses
# `runuser -l` which doesn't prompt for a password since we're already
# root from lxc-attach. The remote script will then have $HOME, $USER,
# etc. set to that user's environment, and any sudo calls inside it
# will prompt for the user's sudo password the first time.
#
# How it works:
#   1. SSH preflight + verify the LXC is running.
#   2. tar up the WHOLE linux-setups repo (minus .git) — the script will
#      be exec'd at its repo-relative path inside the LXC, so any
#      reference it makes via $SCRIPT_DIR/sibling.sh OR $SCRIPT_DIR/../..
#      resolves the same way it would in your local checkout. Critical
#      for things like authorize-pubkeys.sh that walk up to find
#      ../../pubkeys/ at the repo root. Cost is tiny — the whole repo
#      minus .git is well under a megabyte.
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

LXC_USER="${LXC_USER:-}"

# Allow --as before the script path so script args can also start with --
while [ $# -gt 0 ]; do
    case "$1" in
        --as) LXC_USER="$2"; shift 2 ;;
        --)   shift; break ;;
        *)    break ;;
    esac
done

if [ "$#" -lt 1 ]; then
    sed -n '2,60p' "$0" >&2
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

# Find the linux-setups repo root: this script is at <root>/pixel/termux/lxc-run.sh,
# so grandparent of our own location is the repo root.
LXC_RUN_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$LXC_RUN_DIR/../.." && pwd)

# If the user's script lives inside the repo, tar from the repo root and
# exec at the repo-relative path. Otherwise (one-off external script),
# fall back to tar'ing just the script's parent directory.
case "$LOCAL_SCRIPT_ABS" in
    "$REPO_ROOT"/*)
        TAR_ROOT="$REPO_ROOT"
        SCRIPT_RELPATH="${LOCAL_SCRIPT_ABS#$REPO_ROOT/}"
        ;;
    *)
        TAR_ROOT=$(dirname "$LOCAL_SCRIPT_ABS")
        SCRIPT_RELPATH=$(basename "$LOCAL_SCRIPT_ABS")
        ;;
esac

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

# ---- 4. tar the chosen root, stream + extract on Alpine -------------------
# When TAR_ROOT is the linux-setups repo root, this carries pubkeys/ and
# every other repo-relative dependency the in-LXC script might reach for.
# .git is excluded to keep the payload small.
log "packaging $(basename "$TAR_ROOT")/ → ${LXC_NAME}:${LXC_INTERNAL_DIR}/"
tar -C "$TAR_ROOT" --exclude='./.git' --exclude='./.git/*' -cf - . \
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

# ---- 6. exec with TTY through lxc-attach ----------------------------------
# When LXC_USER is set, wrap the in-LXC command in `runuser -l <user> -c`
# so the script runs as that user (with the user's $HOME / $USER set,
# and starting in their home dir). We're already root inside the LXC
# via lxc-attach, so runuser doesn't prompt for a password — but any
# `sudo` inside the script will prompt for the user's password (cached
# for ~15 min after first entry).
INNER_CMD="${ENV_PREFIX}bash $LXC_INTERNAL_DIR/$SCRIPT_RELPATH$QUOTED_ARGS"
if [ -n "$LXC_USER" ]; then
    log "running $SCRIPT_RELPATH$QUOTED_ARGS inside LXC '$LXC_NAME' as user '$LXC_USER'"
    # Ensure the user can read the temp dir even if extracted as root
    PREP_CMD="chown -R $LXC_USER: $LXC_INTERNAL_DIR && cd ~$LXC_USER &&"
    INNER_CMD="$PREP_CMD runuser -l $(printf '%q' "$LXC_USER") -c $(printf '%q' "$INNER_CMD")"
else
    log "running $SCRIPT_RELPATH$QUOTED_ARGS inside LXC '$LXC_NAME' as root"
fi

EXIT_CODE=0
ssh -t -p "$ALPINE_PORT" "${ALPINE_USER}@${ALPINE_HOST}" \
    "trap 'rm -rf $REMOTE_DIR' EXIT; lxc-attach -n $LXC_NAME -- bash -c $(printf '%q' "$INNER_CMD")" \
    || EXIT_CODE=$?

exit $EXIT_CODE
