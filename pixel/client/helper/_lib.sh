# Shared helpers for client/*.sh entry scripts. Source this, don't run.
#
# Provides:
#   - log() / warn() / err() with consistent [client] prefix
#   - LSDIR / CLIENT_DIR variables resolved from the caller's location
#   - lxc_exists()      — true if the named LXC exists on Alpine
#   - lxc_is_running()  — true if it's in RUNNING state
#
# Usage in an entry script:
#     #!/usr/bin/env bash
#     set -euo pipefail
#     _LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helper"
#     . "$_LIB_DIR/_lib.sh"
#     ...

log()  { printf '\033[1;34m[client]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; }

# Repo paths. Callers should source this from a script in <repo>/pixel/client/.
CLIENT_DIR="${CLIENT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
LSDIR="${LSDIR:-$(cd "$CLIENT_DIR/../.." && pwd)}"

# SSH connection defaults (override per-call via env / flags).
# Host varies by context:
#   - Termux on the Pixel itself → localhost (reaches Alpine via the
#     Podroid port forward bound to 0.0.0.0:9922)
#   - Any other machine (laptop, server) → 'pixel' (the Pixel's
#     Tailscale name, routes via tailnet to the same port forward).
# Override via ALPINE_HOST=... if your Tailscale name differs.
if [ -n "${PREFIX:-}" ] && [ -x "${PREFIX}/bin/pkg" ]; then
    _ALPINE_HOST_DEFAULT="localhost"
else
    _ALPINE_HOST_DEFAULT="pixel"
fi
ALPINE_HOST="${ALPINE_HOST:-$_ALPINE_HOST_DEFAULT}"
ALPINE_PORT="${ALPINE_PORT:-9922}"
ALPINE_USER="${ALPINE_USER:-root}"
LXC_NAME="${LXC_NAME:-pubuntu}"

# Test whether an LXC exists on Alpine (via SSH preflight). 0 = exists.
lxc_exists() {
    local name="${1:-$LXC_NAME}"
    ssh -p "$ALPINE_PORT" -o ConnectTimeout=5 -o BatchMode=yes \
        "${ALPINE_USER}@${ALPINE_HOST}" \
        "test -d /var/lib/lxc/$name" 2>/dev/null
}

# Test whether the LXC is currently running. 0 = running.
lxc_is_running() {
    local name="${1:-$LXC_NAME}"
    local state
    state=$(ssh -p "$ALPINE_PORT" -o ConnectTimeout=5 -o BatchMode=yes \
        "${ALPINE_USER}@${ALPINE_HOST}" \
        "lxc-info -n $name -s 2>/dev/null | awk '{print \$2}'" 2>/dev/null || echo "")
    [ "$state" = "RUNNING" ]
}

# Read /etc/podroid-last-user from inside the LXC's rootfs (visible from
# Alpine without needing lxc-attach). Echoes the username; empty if not set.
lxc_last_user() {
    local name="${1:-$LXC_NAME}"
    ssh -p "$ALPINE_PORT" "${ALPINE_USER}@${ALPINE_HOST}" \
        "cat /var/lib/lxc/$name/rootfs/etc/podroid-last-user 2>/dev/null" 2>/dev/null || true
}
