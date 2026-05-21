#!/usr/bin/env bash
# Sets up XFCE + TigerVNC (two sessions) + Input Leap/Barrier inside the
# AVF Linux Terminal VM on a Pixel 10. Safe to re-run.

set -euo pipefail

# ---- Config (override via env if you like) -----------------------------------
PIXEL_GEOMETRY="${PIXEL_GEOMETRY:-1920x1080}"
IPAD_GEOMETRY="${IPAD_GEOMETRY:-2048x1536}"
VNC_DEPTH="${VNC_DEPTH:-24}"

# ---- Helpers -----------------------------------------------------------------
log() { printf '\033[1;34m[setup]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }

require_sudo() {
    if ! sudo -n true 2>/dev/null; then
        log "sudo password will be requested for package installation"
        sudo -v
    fi
}

# ---- Sanity checks -----------------------------------------------------------
if ! command -v apt >/dev/null 2>&1; then
    echo "This script expects a Debian-based system (apt not found)." >&2
    exit 1
fi

require_sudo

# ---- Detect Input Leap vs Barrier --------------------------------------------
INPUT_BRIDGE=""
if apt-cache show input-leap >/dev/null 2>&1; then
    INPUT_BRIDGE="input-leap"
    BRIDGE_SERVER_BIN="input-leaps"
    BRIDGE_CLIENT_BIN="input-leapc"
    BRIDGE_CONFIG_DIR="$HOME/.config/input-leap"
    BRIDGE_CONFIG_FILE="$BRIDGE_CONFIG_DIR/input-leap.conf"
elif apt-cache show barrier >/dev/null 2>&1; then
    INPUT_BRIDGE="barrier"
    BRIDGE_SERVER_BIN="barriers"
    BRIDGE_CLIENT_BIN="barrierc"
    BRIDGE_CONFIG_DIR="$HOME/.config/barrier"
    BRIDGE_CONFIG_FILE="$BRIDGE_CONFIG_DIR/barrier.conf"
else
    warn "Neither input-leap nor barrier available in apt — Input Leap step will be skipped."
    warn "You can install it manually later; the VNC sessions will still work."
fi

# ---- Package install ---------------------------------------------------------
log "Updating apt index"
sudo apt-get update -y

log "Installing desktop + VNC packages"
sudo apt-get install -y --no-install-recommends \
    xfce4 \
    xfce4-terminal \
    xfce4-notifyd \
    dbus-x11 \
    xfonts-base \
    tigervnc-standalone-server \
    tigervnc-common \
    firefox-esr \
    curl \
    rsync \
    openssh-server \
    ca-certificates

if [ -n "$INPUT_BRIDGE" ]; then
    log "Installing $INPUT_BRIDGE"
    sudo apt-get install -y --no-install-recommends "$INPUT_BRIDGE"
fi

# ---- VNC password ------------------------------------------------------------
mkdir -p "$HOME/.vnc"
if [ ! -f "$HOME/.vnc/passwd" ]; then
    log "Setting VNC password (used for both :1 and :2 sessions)"
    vncpasswd
else
    log "VNC password already set — skipping (delete ~/.vnc/passwd to redo)"
fi

# ---- xstartup ----------------------------------------------------------------
log "Writing ~/.vnc/xstartup"
cat > "$HOME/.vnc/xstartup" <<'EOF'
#!/bin/sh
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
export XKL_XMODMAP_DISABLE=1
exec startxfce4
EOF
chmod +x "$HOME/.vnc/xstartup"

# ---- Per-session VNC config --------------------------------------------------
log "Writing ~/.vnc/config"
cat > "$HOME/.vnc/config" <<EOF
depth=$VNC_DEPTH
localhost=no
EOF

# ---- Input Leap / Barrier server config --------------------------------------
if [ -n "$INPUT_BRIDGE" ]; then
    log "Writing $INPUT_BRIDGE config (pixel ↔ ipad)"
    mkdir -p "$BRIDGE_CONFIG_DIR"
    cat > "$BRIDGE_CONFIG_FILE" <<'EOF'
section: screens
    pixel:
    ipad:
end
section: links
    pixel:
        right = ipad
    ipad:
        left = pixel
end
section: options
    keystroke(ctrl+alt+l) = lockCursorToScreen(toggle)
end
EOF
fi

# ---- Helper scripts ----------------------------------------------------------
mkdir -p "$HOME/bin"

log "Writing ~/bin/vnc-start"
cat > "$HOME/bin/vnc-start" <<EOF
#!/usr/bin/env bash
# Starts VNC :1 (Pixel) and :2 (iPad) sessions plus the input bridge.
set -e

PIXEL_GEOMETRY="\${PIXEL_GEOMETRY:-$PIXEL_GEOMETRY}"
IPAD_GEOMETRY="\${IPAD_GEOMETRY:-$IPAD_GEOMETRY}"

# Clean up any stale sessions
vncserver -kill :1 >/dev/null 2>&1 || true
vncserver -kill :2 >/dev/null 2>&1 || true
pkill -f "$BRIDGE_SERVER_BIN" 2>/dev/null || true
pkill -f "$BRIDGE_CLIENT_BIN" 2>/dev/null || true

# Pixel display on :1 (port 5901)
vncserver :1 -geometry "\$PIXEL_GEOMETRY" -localhost no

# iPad display on :2 (port 5902)
vncserver :2 -geometry "\$IPAD_GEOMETRY" -localhost no

EOF

if [ -n "$INPUT_BRIDGE" ]; then
    cat >> "$HOME/bin/vnc-start" <<EOF
# Wait for X servers to settle, then start the input bridge
sleep 2
DISPLAY=:1 nohup $BRIDGE_SERVER_BIN \\
    --config "$BRIDGE_CONFIG_FILE" \\
    --no-tray --name pixel \\
    --address 127.0.0.1:24800 \\
    >/tmp/${BRIDGE_SERVER_BIN}.log 2>&1 &
DISPLAY=:2 nohup $BRIDGE_CLIENT_BIN \\
    --no-tray --name ipad \\
    127.0.0.1:24800 \\
    >/tmp/${BRIDGE_CLIENT_BIN}.log 2>&1 &

EOF
fi

cat >> "$HOME/bin/vnc-start" <<'EOF'
echo
echo "VNC :1 (Pixel) listening on port 5901"
echo "VNC :2 (iPad)  listening on port 5902"
echo
echo "Connect Pixel viewer to localhost:5901"
echo "Connect iPad viewer to <pixel-tailnet-or-wifi-ip>:5902 (set view-only)"
EOF
chmod +x "$HOME/bin/vnc-start"

log "Writing ~/bin/vnc-stop"
cat > "$HOME/bin/vnc-stop" <<EOF
#!/usr/bin/env bash
pkill -f "$BRIDGE_SERVER_BIN" 2>/dev/null || true
pkill -f "$BRIDGE_CLIENT_BIN" 2>/dev/null || true
vncserver -kill :1 >/dev/null 2>&1 || true
vncserver -kill :2 >/dev/null 2>&1 || true
echo "VNC sessions and input bridge stopped"
EOF
chmod +x "$HOME/bin/vnc-stop"

# ---- PATH --------------------------------------------------------------------
if ! grep -q 'HOME/bin' "$HOME/.bashrc" 2>/dev/null; then
    log "Adding ~/bin to PATH in ~/.bashrc"
    printf '\nexport PATH="$HOME/bin:$PATH"\n' >> "$HOME/.bashrc"
fi

# ---- Done --------------------------------------------------------------------
cat <<EOF

==============================================================
Setup complete.

Next steps:
  1. In the Android Terminal app, forward guest ports 5901 and
     5902 to the same host ports.
  2. For iPad access, install Tailscale inside the VM (see
     README) or set up a socat bridge from Termux.
  3. Open a new shell (or run: source ~/.bashrc) so ~/bin is on PATH.
  4. Start the sessions:   vnc-start
     Stop the sessions:    vnc-stop

Pixel viewer  → localhost:5901
iPad viewer   → <pixel-ip>:5902   (set view-only mode)
==============================================================
EOF
