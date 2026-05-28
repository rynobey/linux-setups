#!/usr/bin/env bash
# Make Alpine's running Xvnc display reachable from inside the pubuntu
# LXC, so apps inside pubuntu render via Podroid's in-app X11 viewer.
#
# The naive approach (bind-mount /tmp/.X11-unix → LXC) doesn't work
# because:
#   TigerVNC's Xvnc creates the X server's pathname unix socket
#   (/tmp/.X11-unix/X0) but immediately unlinks the file, keeping only
#   the abstract Linux socket (@/tmp/.X11-unix/X0). Abstract sockets
#   are scoped to the network namespace, which the LXC has its own of
#   — so no path lets pubuntu reach Alpine's X server directly.
#
# Workaround: install socat on Alpine, run a daemon that bridges from
# a real pathname socket (which we CAN bind into the LXC) to the
# abstract socket. Architecture:
#
#   pubuntu (X client)                Alpine                      Podroid app
#   ─────────────────                ──────                      ───────────
#   X app  ──connect /tmp/.X11-unix/X0──►   socat-relay  ──►  @/tmp/.X11-unix/X0
#          (bind-mount → /var/lib/podroid-x11-bridge/X0)        ↑ (abstract socket
#                                                                  bound by Xvnc)
#                                          ┌─ Xvnc :0
#                                          └─ VNC :5900 ──RFB──► Podroid's X11 tab
#
# Three bind mounts inside the LXC:
#   /tmp/.X11-unix             ← socat bridge (was X11 socket dir directly,
#                                  but Xvnc-unlinked-pathname needs this relay)
#   /var/lib/podroid-pulse     ← PulseAudio runtime + native socket
#                                (Ubuntu systemd inside the LXC remounts /run
#                                 as tmpfs so we can't put this under /run)
#   /var/lib/podroid-x11-auth  ← Alpine's /root/.Xauthority (read-only).
#                                Xvnc isn't currently writing one, but we
#                                bind it preemptively for future-proofing.
#
# Runs ON ALPINE (root). Idempotent — re-runs cleanly: replaces both
# the LXC config block AND the /etc/init.d bridge service in place.

set -euo pipefail

LXC_NAME="${LXC_NAME:-pubuntu}"
CONFIG="/var/lib/lxc/${LXC_NAME}/config"
SENTINEL_BEGIN='# --- X11 bind mounts (enable-x11-mounts.sh) BEGIN ---'
SENTINEL_END='# --- X11 bind mounts (enable-x11-mounts.sh) END ---'

BRIDGE_DIR=/var/lib/podroid-x11-bridge
BRIDGE_SVC=/etc/init.d/podroid-x11-bridge

log()  { printf '\033[1;34m[enable-x11-mounts]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; }

if [ ! -f "$CONFIG" ]; then
    err "LXC config not found at $CONFIG — has create-lxc.sh been run?"
    exit 1
fi

# ---- 1. install socat on Alpine -------------------------------------------
if ! command -v socat >/dev/null 2>&1; then
    log "[1/5] installing socat (apk add socat)"
    sudo apk add --no-cache socat
else
    log "[1/5] socat already installed"
fi

# ---- 2. write the bridge OpenRC service -----------------------------------
# Depends on podroid-x11 (so Xvnc is up before we try to connect),
# runs before podroid-ready so it's part of normal boot.
log "[2/5] writing $BRIDGE_SVC"
sudo tee "$BRIDGE_SVC" >/dev/null <<'EOF'
#!/sbin/openrc-run
description="Bridge Alpine's abstract X11 socket to a pathname for LXC bind-mount access"

depend() {
    need podroid-x11
    before podroid-ready
}

SOCAT_PIDFILE=/run/podroid-x11-bridge.pid
BRIDGE_DIR=/var/lib/podroid-x11-bridge
BRIDGE_LOG=/var/log/podroid-x11-bridge.log

start() {
    ebegin "Starting X11 socket bridge (pathname → abstract)"
    mkdir -p "$BRIDGE_DIR"
    chmod 1777 "$BRIDGE_DIR"

    # Wait briefly for Xvnc's abstract socket to be ready (race on cold boot)
    for i in 1 2 3 4 5 6 7 8 9 10; do
        ss -xln 2>/dev/null | grep -q "@/tmp/.X11-unix/X0" && break
        sleep 0.5
    done

    # socat options:
    #   UNIX-LISTEN:.../X0   pathname socket we expose (bind-mounted into LXC)
    #     fork              spawn child per client connection
    #     reuseaddr         allow re-bind on restart
    #     mode=0666         world-rw so non-root users in LXC can connect
    #   ABSTRACT-CONNECT:.../X0   target — Alpine's abstract X socket
    start-stop-daemon --start --background \
        --pidfile "$SOCAT_PIDFILE" --make-pidfile \
        --stdout "$BRIDGE_LOG" --stderr "$BRIDGE_LOG" \
        --exec /usr/bin/socat -- \
        UNIX-LISTEN:$BRIDGE_DIR/X0,fork,reuseaddr,mode=0666 \
        ABSTRACT-CONNECT:/tmp/.X11-unix/X0
    eend $?
}

stop() {
    ebegin "Stopping X11 socket bridge"
    start-stop-daemon --stop --pidfile "$SOCAT_PIDFILE" 2>/dev/null
    eend 0
}
EOF
sudo chmod +x "$BRIDGE_SVC"

# ---- 3. enable + start the bridge service ---------------------------------
log "[3/5] enabling + starting podroid-x11-bridge"
sudo rc-update add podroid-x11-bridge default >/dev/null 2>&1 || true
# Restart cleanly (handles re-runs after this script was modified)
sudo rc-service podroid-x11-bridge stop 2>/dev/null || true
sudo rc-service podroid-x11-bridge start

# Verify the bridge socket exists
sleep 1
if [ -S "$BRIDGE_DIR/X0" ]; then
    log "  ✓ bridge socket at $BRIDGE_DIR/X0"
else
    warn "  ✗ bridge socket NOT at $BRIDGE_DIR/X0 — check /var/log/podroid-x11-bridge.log"
fi

# ---- 4. update LXC config with three bind mounts --------------------------
# Sentinel-bounded block so re-runs cleanly replace whatever was there.
MOUNT_LINES=(
    "lxc.mount.entry = $BRIDGE_DIR tmp/.X11-unix none bind,create=dir,optional 0 0"
    "lxc.mount.entry = /run/podroid-pulse var/lib/podroid-pulse none bind,create=dir,optional 0 0"
    "lxc.mount.entry = /root/.Xauthority var/lib/podroid-x11-auth none bind,create=file,optional,ro 0 0"
)

if grep -qF "$SENTINEL_BEGIN" "$CONFIG"; then
    log "[4/5] removing existing X11 block from $CONFIG"
    sudo sed -i "/${SENTINEL_BEGIN//\//\\/}/,/${SENTINEL_END//\//\\/}/d" "$CONFIG"
fi

log "[4/5] appending X11 mount block to $CONFIG"
{
    echo ""
    echo "$SENTINEL_BEGIN"
    for line in "${MOUNT_LINES[@]}"; do
        echo "$line"
    done
    echo "$SENTINEL_END"
} | sudo tee -a "$CONFIG" >/dev/null

for line in "${MOUNT_LINES[@]}"; do
    log "  $(echo "$line" | awk '{print $3}') → $(echo "$line" | awk '{print $4}')"
done

# ---- 5. restart the LXC + verify mounts -----------------------------------
log "[5/5] restarting LXC '$LXC_NAME' to apply mounts"
if sudo lxc-info -n "$LXC_NAME" -s 2>/dev/null | grep -q RUNNING; then
    sudo lxc-stop -n "$LXC_NAME"
fi
sudo lxc-start -n "$LXC_NAME"
sudo lxc-wait -n "$LXC_NAME" -s RUNNING -t 30

sleep 1
log "verifying mounts inside the LXC"
missing=0
for path in /tmp/.X11-unix/X0 /var/lib/podroid-pulse /var/lib/podroid-x11-auth; do
    if sudo lxc-attach -n "$LXC_NAME" -- test -e "$path" 2>/dev/null; then
        log "  ✓ $path present"
    else
        warn "  ✗ $path missing"
        missing=1
    fi
done

log ""
if [ "$missing" -eq 0 ]; then
    log "All three mounts present inside the LXC."
fi

log "Done. Next: install X clients + WM inside pubuntu:"
log "  bash pixel/client/helper/lxc-run.sh --as <user> pixel/lxc/helper/install-x11.sh"
