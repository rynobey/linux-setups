#!/data/data/com.termux/files/usr/bin/bash
# Run any local script on Podroid's Alpine host via SSH, without
# requiring linux-setups to be cloned inside Alpine.
#
# Usage:
#   bash alpine-run.sh <local-script-path> [args-to-script ...]
#
# Examples:
#   bash alpine-run.sh ../podroid/create-lxc.sh
#   bash alpine-run.sh ../podroid/backup.sh
#   bash alpine-run.sh ../podroid/restore.sh --latest
#   BACKUP_DIR=/tmp/alt bash alpine-run.sh ../podroid/backup.sh
#
# What this does:
#   1. Preflight SSH (BatchMode → fails fast on missing keys)
#   2. Build the script payload locally: sudo shim + your script body
#   3. Copy the payload to a temp file on Alpine via SSH
#   4. Execute with `ssh -t` (real TTY) so interactive prompts work —
#      `age -p`'s passphrase prompt, sudo's password prompt (if any),
#      restore.sh's confirmation prompt, etc.
#   5. Auto-clean the remote temp file via a trap on exit
#
# Env-var passthrough: any of these set locally are forwarded to the
# remote script (extend the list below as needed):
#   LXC_NAME, LXC_DIST, LXC_RELEASE, LXC_ARCH,
#   SHARED_HOST, SHARED_GUEST,
#   BACKUP_DIR, BACKUP_PREFIX,
#   SKIP_TMUX_CHECK
#
# SSH connection env:
#   ALPINE_HOST (default: localhost — Podroid's port forward reaches
#                Alpine via Pixel's localhost)
#   ALPINE_PORT (default: 9922)
#   ALPINE_USER (default: root)

set -euo pipefail

if [ "$#" -lt 1 ]; then
    sed -n '2,40p' "$0" >&2
    exit 2
fi

LOCAL_SCRIPT="$1"
shift

ALPINE_HOST="${ALPINE_HOST:-localhost}"
ALPINE_PORT="${ALPINE_PORT:-9922}"
ALPINE_USER="${ALPINE_USER:-root}"

ENV_VARS_PASSTHROUGH=(
    LXC_NAME LXC_DIST LXC_RELEASE LXC_ARCH
    SHARED_HOST SHARED_GUEST
    BACKUP_DIR BACKUP_PREFIX
    SKIP_TMUX_CHECK
)

log()  { printf '\033[1;34m[alpine-run]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; }

# ---- 1. local script must exist -------------------------------------------
if [ ! -f "$LOCAL_SCRIPT" ]; then
    err "$LOCAL_SCRIPT not found (cwd: $(pwd))"
    exit 1
fi

# ---- 2. SSH preflight ------------------------------------------------------
if ! ssh -p "$ALPINE_PORT" -o ConnectTimeout=5 -o BatchMode=yes \
        "${ALPINE_USER}@${ALPINE_HOST}" 'true' 2>/dev/null; then
    err "can't SSH to ${ALPINE_USER}@${ALPINE_HOST}:${ALPINE_PORT}"
    err "  - is Podroid VM running?"
    err "  - is port forward $ALPINE_PORT → 22 enabled?"
    err "  - is Termux's ~/.ssh/id_ed25519.pub in Alpine's /root/.ssh/authorized_keys?"
    err "  test: ssh -p $ALPINE_PORT ${ALPINE_USER}@${ALPINE_HOST}"
    exit 1
fi

# ---- 3. copy script body (with sudo shim) to a temp file on Alpine --------
# mktemp on the remote side so we get a unique name. The shim is a no-op
# pass-through so source scripts that use `sudo apk add ...` Just Work
# on Alpine root (which doesn't have sudo installed by default).
REMOTE_TMP=$(ssh -p "$ALPINE_PORT" "${ALPINE_USER}@${ALPINE_HOST}" 'mktemp /tmp/alpine-run.XXXXXX')

{
    echo '#!/bin/bash'
    cat <<'PREAMBLE'
# Auto-injected by alpine-run.sh: sudo shim for Alpine root.
if ! command -v sudo >/dev/null 2>&1; then
    sudo() { "$@"; }
fi
PREAMBLE
    tail -n +2 "$LOCAL_SCRIPT"   # source minus its shebang
} | ssh -p "$ALPINE_PORT" "${ALPINE_USER}@${ALPINE_HOST}" \
        "cat > $REMOTE_TMP && chmod +x $REMOTE_TMP"

# ---- 4. build env-var preamble for the exec --------------------------------
ENV_PREFIX=""
for var in "${ENV_VARS_PASSTHROUGH[@]}"; do
    if [ -n "${!var:-}" ]; then
        ENV_PREFIX+="$var=$(printf '%q' "${!var}") "
    fi
done

# ---- 5. quote args for the remote shell -----------------------------------
QUOTED_ARGS=""
for a in "$@"; do
    QUOTED_ARGS+=" $(printf '%q' "$a")"
done

log "running $(basename "$LOCAL_SCRIPT")$QUOTED_ARGS on ${ALPINE_USER}@${ALPINE_HOST}"

# ---- 6. exec with TTY allocation, auto-clean tmp file ---------------------
# `ssh -t` gets us a pseudo-TTY so interactive prompts work.
# `trap rm` on the remote shell cleans up even if the script crashes
# or the user hits Ctrl-C.
EXIT_CODE=0
ssh -t -p "$ALPINE_PORT" "${ALPINE_USER}@${ALPINE_HOST}" \
    "trap 'rm -f $REMOTE_TMP' EXIT; ${ENV_PREFIX}bash $REMOTE_TMP$QUOTED_ARGS" \
    || EXIT_CODE=$?

exit $EXIT_CODE
