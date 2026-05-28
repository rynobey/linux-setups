#!/usr/bin/env bash
# Run a local script INSIDE the pubuntu LXC (which lives inside Alpine
# which lives inside Podroid), without requiring linux-setups to be
# cloned in either Alpine or the LXC.
#
# Usage:
#   bash lxc-run.sh [--as <username>] <local-script-path> [args-to-script ...]
#
# Examples:
#   bash lxc-run.sh ../podroid/create-user.sh
#   bash lxc-run.sh --as ryno ../lxc/helper/bootstrap-deps.sh
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
#      like /var/lib/lxc/$LXC_NAME/rootfs/var/tmp/lxc-run.XXXXXX from
#      Alpine, but the same dir appears as /var/tmp/lxc-run.XXXXXX from
#      inside the LXC (privileged LXC means uid 0 == uid 0, so the file
#      is readable inside). /var/tmp instead of /tmp because the
#      container's first-boot tmp cleanup can race a /tmp stage and
#      wipe it mid-extract.
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

# Default ALPINE_HOST: Termux → localhost, other machines → 'pixel'.
# See pixel/client/helper/_lib.sh for the full rationale.
if [ -n "${PREFIX:-}" ] && [ -x "${PREFIX}/bin/pkg" ]; then
    _ALPINE_HOST_DEFAULT="localhost"
else
    _ALPINE_HOST_DEFAULT="pixel"
fi
ALPINE_HOST="${ALPINE_HOST:-$_ALPINE_HOST_DEFAULT}"
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

# Find the linux-setups repo root: this script is at
# <root>/pixel/client/helper/lxc-run.sh, so go three levels up.
LXC_RUN_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$LXC_RUN_DIR/../../.." && pwd)

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
    err "  or run pixel/client/05-setup-lxc-fresh.sh to create+start it"
    exit 1
fi

# ---- 3. mktemp working dir inside the LXC's rootfs ------------------------
# We stage in /var/tmp instead of /tmp specifically to avoid a race with
# the container's first-boot tmp cleanup. When 05-setup-lxc-fresh.sh
# starts the LXC and immediately follows with lxc-run, the container's
# systemd-tmpfiles-setup is still racing against our extract — anything
# we put under /tmp can be wiped mid-tar (manifests as "Cannot mkdir:
# No such file or directory" on every file). /var/tmp has the same 1777
# perms but a 30-day cleanup threshold and isn't touched at boot.
#
# Also wait for the container to be reachable via lxc-attach before
# staging, so we're past the early-boot transient before doing work.
LXC_ROOTFS="/var/lib/lxc/$LXC_NAME/rootfs"

# Readiness probe — retry lxc-attach until a no-op runs, then proceed.
ssh -p "$ALPINE_PORT" "${ALPINE_USER}@${ALPINE_HOST}" "
    for i in 1 2 3 4 5 6 7 8 9 10; do
        if lxc-attach -n $LXC_NAME -- true 2>/dev/null; then exit 0; fi
        sleep 1
    done
    exit 1
" || { err "LXC '$LXC_NAME' not reachable via lxc-attach after 10s"; exit 1; }

REMOTE_DIR=$(ssh -p "$ALPINE_PORT" "${ALPINE_USER}@${ALPINE_HOST}" \
    "mktemp -d $LXC_ROOTFS/var/tmp/lxc-run.XXXXXX")

# Path as seen from INSIDE the LXC (strips the rootfs prefix → /var/tmp/lxc-run.XXX)
LXC_INTERNAL_DIR="${REMOTE_DIR#$LXC_ROOTFS}"

# ---- 4. tar the chosen root, stream + extract on Alpine -------------------
# When TAR_ROOT is the linux-setups repo root, this carries pubkeys/ and
# every other repo-relative dependency the in-LXC script might reach for.
# .git is excluded to keep the payload small.
#
# chmod a+rX after extract: mktemp -d creates the dir 0700 (root-only),
# so without this any --as <user> invocation can't read its own scripts.
# `a+rX` adds read for everyone, plus execute on directories only (capital
# X). Keeps the regular files at their tar-extracted mode but ensures the
# whole tree is traversable + readable by non-root users.
log "packaging $(basename "$TAR_ROOT")/ → ${LXC_NAME}:${LXC_INTERNAL_DIR}/"
tar -C "$TAR_ROOT" --exclude='./.git' --exclude='./.git/*' -cf - . \
    | ssh -p "$ALPINE_PORT" "${ALPINE_USER}@${ALPINE_HOST}" \
            "tar -xf - -C $REMOTE_DIR && chmod -R a+rX $REMOTE_DIR && chmod a+rx $REMOTE_DIR"

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
# When LXC_USER is set, wrap the in-LXC command in `runuser --pty -l`:
#   -l  : login shell — sources /etc/profile, ~/.profile, sets $HOME,
#         $USER, cd's into $HOME.
#   --pty: allocates a NEW pseudo-terminal for the user's session. This
#         is the critical bit. Without --pty, login mode runs setsid(),
#         detaching from the inherited PTY, so any subsequent sudo
#         inside the user's script fails with "a terminal is required
#         to read the password". The --pty bridge gives sudo something
#         to read its password prompt from.
#
# We're already root inside the LXC via lxc-attach, so runuser itself
# doesn't prompt for a password — only sudo inside the user's script
# will (cached for ~15 min after first entry).
INNER_CMD="${ENV_PREFIX}bash $LXC_INTERNAL_DIR/$SCRIPT_RELPATH$QUOTED_ARGS"
if [ -n "$LXC_USER" ]; then
    log "running $SCRIPT_RELPATH$QUOTED_ARGS inside LXC '$LXC_NAME' as user '$LXC_USER'"
    INNER_CMD="runuser --pty -l $(printf '%q' "$LXC_USER") -c $(printf '%q' "$INNER_CMD")"
else
    log "running $SCRIPT_RELPATH$QUOTED_ARGS inside LXC '$LXC_NAME' as root"
fi

EXIT_CODE=0
ssh -t -p "$ALPINE_PORT" "${ALPINE_USER}@${ALPINE_HOST}" \
    "trap 'rm -rf $REMOTE_DIR' EXIT; lxc-attach -n $LXC_NAME -- bash -c $(printf '%q' "$INNER_CMD")" \
    || EXIT_CODE=$?

exit $EXIT_CODE
