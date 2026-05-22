#!/usr/bin/env bash
# Cleanup script for the VNC / Input Leap / AVF Display experiments
# we ran during the pixel10-avf setup but ultimately parked.
#
# Removes:
#   - Helper scripts in ~/bin/ (vnc-start, vnc-stop, orient, route-*,
#     cursor-bridge)
#   - Running VNC sessions and cursor-bridge processes
#   - Source builds under ~/build/input-leap and /usr/local/bin installs
#   - VNC and XFCE dotfiles
#   - Stale apt sources from the failed input-leap search (sid pin)
#   - Optionally: the GUI packages themselves (XFCE, TigerVNC, etc.)
#
# Interactive: asks [y/n] before each major step so you can pick and
# choose. Run as your normal user; uses sudo where needed.
#
# To wipe even more aggressively (nuclear option): Android Settings →
# Apps → Terminal → Clear storage. That destroys the entire VM image,
# which is faster than this script if you're starting over.

set -u

# ---- Helpers -----------------------------------------------------------------
log()  { printf '\033[1;34m[cleanup]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; }

confirm() {
    local prompt="${1:-Continue?}"
    local default="${2:-n}"
    local yn_hint
    if [ "$default" = "y" ]; then
        yn_hint="[Y/n]"
    else
        yn_hint="[y/N]"
    fi
    read -rp "$prompt $yn_hint " choice
    choice="${choice:-$default}"
    [[ "$choice" =~ ^[Yy]$ ]]
}

if [ "$EUID" -eq 0 ]; then
    err "Don't run as root. Run as your normal user; the script uses sudo as needed."
    exit 1
fi

cat <<EOF
============================================================
This script removes artifacts from the VNC / Input Leap /
AVF Display experiments. You'll be asked before each step.

Run this on the AVF VM, NOT on your laptop.
============================================================
EOF
if ! confirm "Proceed?"; then
    log "Aborted."
    exit 0
fi

# ---- Step 1: stop running processes -----------------------------------------
log "Stopping any running VNC / cursor-bridge processes…"

# cursor-bridge via PID file (avoids the pkill self-match trap)
if [ -f /tmp/cursor-bridge.pid ]; then
    pid=$(cat /tmp/cursor-bridge.pid 2>/dev/null || true)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
        sleep 1
        kill -9 "$pid" 2>/dev/null || true
        log "  killed cursor-bridge (PID $pid)"
    fi
    rm -f /tmp/cursor-bridge.pid
fi

# VNC servers (best-effort)
if command -v vncserver >/dev/null 2>&1; then
    vncserver -kill :1 >/dev/null 2>&1 || true
    vncserver -kill :2 >/dev/null 2>&1 || true
    log "  killed any VNC servers on :1 / :2"
fi

# Stop tigervnc systemd units if they were enabled (autostart path)
for unit in 'tigervncserver@:1.service' 'tigervncserver@:2.service'; do
    if systemctl list-unit-files "$unit" >/dev/null 2>&1; then
        sudo systemctl disable --now "$unit" 2>/dev/null || true
    fi
done

# Stray input-leap / barrier processes (these were never actually
# successfully running here, but be defensive)
for proc in input-leaps input-leapc barriers barrierc weston-terminal; do
    if pgrep -x "$proc" >/dev/null 2>&1; then
        pkill -x "$proc" 2>/dev/null || true
    fi
done

# ---- Step 2: helper scripts in ~/bin/ ---------------------------------------
HELPERS=(vnc-start vnc-stop orient route-toggle route-to-left cursor-bridge)
echo
log "About to remove these helper scripts from ~/bin/:"
for h in "${HELPERS[@]}"; do
    if [ -e "$HOME/bin/$h" ]; then
        printf '  ~/bin/%s\n' "$h"
    fi
done
if confirm "Remove them?" y; then
    for h in "${HELPERS[@]}"; do
        rm -f "$HOME/bin/$h"
    done
    log "Helper scripts removed."
fi

# ---- Step 3: source build + /usr/local installs -----------------------------
echo
log "Input Leap source build tree and /usr/local installs:"
[ -d "$HOME/build/input-leap" ] && printf '  ~/build/input-leap (entire tree)\n'
for f in /usr/local/bin/input-leaps /usr/local/bin/input-leapc \
         /usr/local/share/man/man1/input-leaps.1 \
         /usr/local/share/man/man1/input-leapc.1 \
         /usr/local/share/applications/io.github.input_leap.input-leap.desktop \
         /usr/local/share/metainfo/io.github.input_leap.input-leap.appdata.xml \
         /usr/local/share/icons/hicolor/scalable/apps/io.github.input_leap.input-leap.svg; do
    [ -e "$f" ] && printf '  %s\n' "$f"
done
if confirm "Remove them?" y; then
    rm -rf "$HOME/build/input-leap"
    sudo rm -f /usr/local/bin/input-leaps /usr/local/bin/input-leapc
    sudo rm -f /usr/local/share/man/man1/input-leaps.1 \
               /usr/local/share/man/man1/input-leapc.1
    sudo rm -f /usr/local/share/applications/io.github.input_leap.input-leap.desktop
    sudo rm -f /usr/local/share/metainfo/io.github.input_leap.input-leap.appdata.xml
    sudo rm -f /usr/local/share/icons/hicolor/scalable/apps/io.github.input_leap.input-leap.svg
    log "Source build artifacts removed."
fi

# ---- Step 4: dotfiles & cached session state --------------------------------
echo
log "VNC / XFCE / Input Leap dotfiles:"
for d in "$HOME/.vnc" "$HOME/.config/xfce4" "$HOME/.config/input-leap" \
         "$HOME/.config/barrier" "$HOME/.cache/sessions"; do
    [ -e "$d" ] && printf '  %s\n' "$d"
done
warn "Removing ~/.vnc deletes your VNC password (you can re-set later)."
if confirm "Remove these dotfiles?" n; then
    rm -rf "$HOME/.vnc" "$HOME/.config/xfce4" "$HOME/.config/input-leap" \
           "$HOME/.config/barrier" "$HOME/.cache/sessions"
    log "Dotfiles removed."
fi

# ---- Step 5: stale apt sources from input-leap search -----------------------
echo
log "Stale apt sources from the failed input-leap search:"
for f in /etc/apt/sources.list.d/debian-sid.sources \
         /etc/apt/preferences.d/pin-sid; do
    [ -e "$f" ] && printf '  %s\n' "$f"
done
if confirm "Remove these?" y; then
    sudo rm -f /etc/apt/sources.list.d/debian-sid.sources \
               /etc/apt/preferences.d/pin-sid
    sudo apt-get update -y
    log "Stale apt sources removed."
fi

# ---- Step 6: purge GUI packages (optional, heavier) -------------------------
echo
log "GUI packages we installed during the experiments:"
cat <<EOF
  xfce4 + xfce4-* family (desktop environment)
  tigervnc-* (server, common, tools)
  lightdm + lightdm-gtk-greeter (display manager attempt)
  weston (only relevant on AVF Display path)
  firefox-esr (was installed for the browser story)
  python3-xlib, xclip, mesa-utils (cursor-bridge deps)
  libavahi-compat-libdnssd-dev, libice-dev, libsm-dev (input-leap build)
EOF
warn "Removing these will free a few hundred MB but you'll need to"
warn "reinstall anything you actually want to use later."
if confirm "Purge GUI packages?" n; then
    sudo apt-get remove --purge -y \
        xfce4 'xfce4-*' \
        tigervnc-standalone-server tigervnc-common tigervnc-tools \
        lightdm lightdm-gtk-greeter \
        weston \
        firefox-esr \
        python3-xlib xclip mesa-utils \
        libavahi-compat-libdnssd-dev libice-dev libsm-dev \
        || warn "Some packages weren't installed; that's fine."
    sudo apt-get autoremove --purge -y
    sudo apt-get clean
    log "GUI packages purged."
fi

# ---- Done -------------------------------------------------------------------
cat <<EOF

============================================================
Cleanup complete.

If you want a fully clean VM (faster than running this
script in many cases), use:
  Android Settings → Apps → Terminal → Clear storage
Then re-run the bootstrap from the pixel10-avf README.
============================================================
EOF
