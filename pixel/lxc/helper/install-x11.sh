#!/usr/bin/env bash
# Install X11 client tools + a lightweight window manager inside the
# pubuntu LXC, and wire the environment so apps render to Alpine's
# already-running Xvnc display (which Podroid's in-app X11 viewer
# shows via RFB on 127.0.0.1:5900).
#
# Prereq: pixel/podroid/helper/enable-x11-mounts.sh has been run so
# the bind mounts exist inside the LXC:
#   /tmp/.X11-unix           ← X11 client socket (DISPLAY=:0)
#   /var/lib/podroid-pulse   ← PulseAudio runtime + native socket
#                              (NOT /run/podroid-pulse — systemd
#                               remounts /run as tmpfs inside the LXC
#                               and hides anything bind-mounted there)
#   /var/lib/podroid-x11-auth ← Alpine's MIT-MAGIC-COOKIE-1 file
#
# Runs INSIDE pubuntu as the user (via pixel/client/helper/lxc-run.sh).
# Uses sudo for apt; the user is expected to be in the sudo group.
#
# Idempotent: re-runs cleanly. apt-installs are no-ops if already
# present; the /etc/profile.d file is rewritten in place.
#
# Env / flags:
#   --wm <name>   install a different window manager (default: fluxbox)
#                 alternatives that just work: openbox, jwm, i3, xfwm4

set -euo pipefail

WM="${WM:-fluxbox}"

while [ $# -gt 0 ]; do
    case "$1" in
        --wm)      WM="$2"; shift 2 ;;
        -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done

log()  { printf '\033[1;34m[install-x11]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; }

# ---- sanity: the bind mounts must be in place ------------------------------
missing=()
for path in /tmp/.X11-unix /var/lib/podroid-x11-auth /var/lib/podroid-pulse; do
    [ -e "$path" ] || missing+=("$path")
done
if [ "${#missing[@]}" -gt 0 ]; then
    err "missing bind mounts inside the LXC:"
    for p in "${missing[@]}"; do
        err "  $p"
    done
    err ""
    err "Run pixel/podroid/helper/enable-x11-mounts.sh on Alpine first"
    err "  (or via:  bash pixel/client/helper/alpine-run.sh pixel/podroid/helper/enable-x11-mounts.sh)"
    err "Then restart the LXC if necessary so the optional binds pick up."
    exit 1
fi

# ---- apt install -----------------------------------------------------------
# x11-apps: xeyes, xclock, xterm, xcalc — minimal sanity tests
# x11-xserver-utils: xrandr, xhost, etc.
# xauth: needed for setting XAUTHORITY against the cookie file
# pulseaudio-utils: paplay, pactl — verify audio path
# $WM: window manager (default fluxbox; passing --wm switches it)
log "[1/3] installing X11 client libs + ${WM} (apt)"
sudo apt-get update -y
sudo apt-get install -y \
    x11-apps x11-xserver-utils xauth \
    pulseaudio-utils \
    "$WM"

# ---- /etc/profile.d/podroid-x11.sh -----------------------------------------
# Mirror of Alpine's /etc/profile.d/podroid-x11.sh but with paths
# matched to our bind-mount destinations. Sourced by login shells
# (interactive bash + zsh + dash via /etc/profile), so any ssh-in or
# `runuser -l` session inherits DISPLAY/PULSE_SERVER/XAUTHORITY for free.
log "[2/3] writing /etc/profile.d/podroid-x11.sh (DISPLAY + PULSE_SERVER + XAUTHORITY)"
sudo tee /etc/profile.d/podroid-x11.sh > /dev/null <<'EOF'
# Podroid X11 + audio environment for pubuntu LXC.
# These point at bind-mounted unix sockets shared with the Alpine host
# (set up by pixel/podroid/helper/enable-x11-mounts.sh). Apps launched
# from a login shell here render via the in-app Podroid X11 viewer.

# X11 display via Alpine's Xvnc :0 (bind-mounted unix socket)
export DISPLAY=:0

# MIT-MAGIC-COOKIE-1 owned by Alpine's root, made readable to us via the
# read-only bind mount of /root/.Xauthority. Without this, every X
# client would get "No protocol specified / Cannot open display".
export XAUTHORITY=/var/lib/podroid-x11-auth

# PulseAudio native protocol over Alpine's unix socket (NOT the TCP
# port 4713 — that's a capture-only stream consumed by the Podroid
# app for Android playback, and not what a Firefox / mpv client wants).
# Bind target is /var/lib/podroid-pulse (NOT /run/podroid-pulse) — see
# the enable-x11-mounts.sh header for why systemd in this LXC remounts
# /run as tmpfs and hides anything mounted under it.
export XDG_RUNTIME_DIR=/var/lib/podroid-pulse
export PULSE_SERVER=unix:/var/lib/podroid-pulse/native
EOF
sudo chmod 0644 /etc/profile.d/podroid-x11.sh

# Also drop the same env into the current shell so the user can test
# immediately without re-loginning.
. /etc/profile.d/podroid-x11.sh

# ---- sanity test -----------------------------------------------------------
log "[3/3] sanity-testing X connection"

# xauth list on the bound file — if it shows a cookie entry, the auth
# bind worked. Empty output is the "Xvnc hadn't started when LXC mounted"
# race; user has to restart pubuntu in that case.
if ! XAUTHORITY="$XAUTHORITY" xauth list 2>/dev/null | grep -q .; then
    warn "XAUTHORITY file is empty — Xvnc probably hadn't started when the LXC"
    warn "mounted /root/.Xauthority. From Alpine:"
    warn "  lxc-stop -n pubuntu && lxc-start -n pubuntu"
    warn "Then re-run this script."
fi

# Minimal connectivity probe — xset -q reads server info, fails cleanly
# if DISPLAY is broken (no socket, bad cookie, server died).
if xset -q >/dev/null 2>&1; then
    log "✓ X11 connection works ($XAUTHORITY → $DISPLAY)"
else
    warn "xset -q failed — X server reachable but auth or display may be broken"
    warn "Debug:"
    warn "  ls -la /tmp/.X11-unix/   (should show X0 socket)"
    warn "  xauth list                (should show cookie)"
    warn "  DISPLAY=:0 XAUTHORITY=$XAUTHORITY xset -q   (try directly)"
fi

# ---- print next steps -----------------------------------------------------
cat <<EOF

==============================================================
X11 setup complete inside pubuntu.

Try it:

  # In a fresh shell (so /etc/profile.d/podroid-x11.sh is sourced):
  ssh <user>@pubuntu          # via Tailscale
  # or already-running interactive shell? source the file:
  . /etc/profile.d/podroid-x11.sh

  # Start the window manager (one-time, leave it running):
  ${WM} &

  # Quick visual tests — apps appear in the Podroid X11 viewer:
  xeyes &
  xclock -update 1 &
  xterm &

  # Audio test:
  paplay /usr/share/sounds/alsa/Front_Center.wav 2>/dev/null || true

Then open Podroid → the X11 tab. You should see ${WM}'s root window
with whatever you've launched.

If apps fail with "Cannot open display" or "Authorization required":
  - Make sure DISPLAY=:0 and XAUTHORITY=/var/lib/podroid-x11-auth are set
  - Verify the cookie file is non-empty: xauth list
  - If empty, restart pubuntu from Alpine to re-trigger the optional bind
==============================================================
EOF
