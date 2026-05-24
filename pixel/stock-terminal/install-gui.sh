#!/usr/bin/env bash
# Install sway + foot + firefox inside the Stock Terminal's Debian VM.
#
# Prereq: hardware acceleration enabled (zink Vulkan 1.3 visible via
# `glxinfo | grep renderer`). See README.md in this dir for the
# one-time ADB / virglrenderer setup.
#
# Idempotent: skips installs for tools already present, only writes a
# default sway config if ~/.config/sway/config doesn't exist.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log()  { printf '\033[1;34m[install-gui]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }

# ---- apt install -----------------------------------------------------------
pkgs=(sway swayidle swaylock foot wofi firefox-esr xdg-utils mesa-utils)
log "apt installing: ${pkgs[*]}"
sudo apt-get update -y
sudo apt-get install -y "${pkgs[@]}"

# ---- install connect-dev.sh into PATH --------------------------------------
sudo install -m 0755 "$SCRIPT_DIR/connect-dev.sh" /usr/local/bin/connect-dev
log "installed connect-dev → /usr/local/bin/connect-dev"

# ---- sway config -----------------------------------------------------------
SWAY_CONFIG_DIR="${HOME}/.config/sway"
SWAY_CONFIG="${SWAY_CONFIG_DIR}/config"
if [ -f "$SWAY_CONFIG" ]; then
    log "existing sway config at $SWAY_CONFIG — leaving alone"
else
    log "writing default sway config to $SWAY_CONFIG"
    mkdir -p "$SWAY_CONFIG_DIR"
    cat > "$SWAY_CONFIG" <<'EOF'
# Minimal sway config for the Pixel Stock Terminal GPU host.
# Source: linux-setups/pixel/stock-terminal/install-gui.sh

# Super (Windows / Cmd) key as the modifier.
set $mod Mod4

# Default terminal + launcher.
set $term foot
set $menu wofi --show drun

# --- keybinds ---------------------------------------------------------------
bindsym $mod+Return       exec $term
bindsym $mod+Shift+Return exec $term -e connect-dev
bindsym $mod+d            exec $menu
bindsym $mod+Shift+q      kill
bindsym $mod+f            fullscreen
bindsym $mod+h            split h
bindsym $mod+v            split v
bindsym $mod+Shift+e      exit

# Focus movement (vim-style).
bindsym $mod+Left   focus left
bindsym $mod+Down   focus down
bindsym $mod+Up     focus up
bindsym $mod+Right  focus right

# Window movement.
bindsym $mod+Shift+Left   move left
bindsym $mod+Shift+Down   move down
bindsym $mod+Shift+Up     move up
bindsym $mod+Shift+Right  move right

# Workspaces 1-5.
bindsym $mod+1 workspace 1
bindsym $mod+2 workspace 2
bindsym $mod+3 workspace 3
bindsym $mod+4 workspace 4
bindsym $mod+5 workspace 5
bindsym $mod+Shift+1 move container to workspace 1
bindsym $mod+Shift+2 move container to workspace 2
bindsym $mod+Shift+3 move container to workspace 3
bindsym $mod+Shift+4 move container to workspace 4
bindsym $mod+Shift+5 move container to workspace 5

# Reload + restart.
bindsym $mod+Shift+c reload
bindsym $mod+Shift+r restart

# --- look ------------------------------------------------------------------
font pango:JetBrainsMono Nerd Font 11
gaps inner 4
default_border pixel 2

# --- autostart -------------------------------------------------------------
# (nothing yet — add `exec firefox &` etc here if you want it)
EOF
fi

# ---- smoke test ------------------------------------------------------------
log "renderer reported by glxinfo (should say zink Vulkan):"
glxinfo 2>/dev/null | grep "OpenGL renderer" || warn "glxinfo failed — graphics stack may not be initialized"

log "done. Launch sway with:  sway"
log "(Mod+Shift+Return → connect-dev → ssh into the LXC)"
