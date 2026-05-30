#!/data/data/com.termux/files/usr/bin/bash
# Deploy the day-to-day runtime scripts to Termux $HOME:
#
#   ~/start-x11.sh           Bring up Termux:X11 + direct-X TCP bridge + audio
#                            + i3 window manager. Generates an xauth cookie and
#                            (best-effort) deploys it to pubuntu over SSH.
#   ~/stop-x11.sh            Tear it all down (i3, X server, direct-X bridge,
#                            pulseaudio; leaves the Termux:X11 Android activity
#                            alone — cheap to keep running).
#   ~/sync-x11-cookie.sh     Manual cookie deploy helper for when pubuntu was
#                            down at start-x11 time or got rebuilt.
#   ~/runtime.env            Small env file the above scripts source.
#   ~/.config/i3/config      i3 keybinds + workspaces + bar (mod=Ctrl+Alt).
#   ~/.local/bin/i3-cheatsheet  $mod+slash binding popup (full keybind list).
#   ~/.config/xfce4/terminal/terminalrc  no-Alt-menu xfce4-terminal defaults.
#
# This script also installs the Termux-side packages the runtime scripts
# depend on (x11-repo, mesa, vulkan-loader-android, virgl, socat, ...).
#
# Re-running overwrites the deployed scripts (keeps a .bak copy of each).
# Edits you make to deployed scripts go away on re-run; edit this script
# (or its embedded heredocs) for persistent changes.
#
# Env overrides:
#   DISPLAY_NUM      default: 0          (Termux:X11 listens on :0 by default)
#   START_PULSE      default: 1          set 0 to skip pulseaudio
#   USE_XAUTH        default: 1          start Termux:X11 with cookie auth
#                                        (-auth ~/.Xauthority); set 0 for
#                                        permissive -ac mode (no auth). Cookie
#                                        is auto-deployed to pubuntu via SSH
#                                        if reachable. See architecture doc.
#   PUBUNTU_SSH_PORT default: 9923       for cookie auto-deploy target
#   PUBUNTU_SSH_USER default: ryno
#   I3_MOD           default: Ctrl+Mod1  i3 primary modifier (= Ctrl+Alt)
#   I3_FLOAT_MOD     default: Mod4       single modifier for mouse-drag-float
#   I3_FONT          default: DejaVu Sans Mono 10  (initial value — desktop-look.env
#                                        owns the live setting after first deploy)
#   BACKUP           default: 0          if 1, save <file>.bak before each
#                                        overwrite. Default off so $HOME stays
#                                        clean across repeated 06 runs.
#
# VNC + x2x bridge (second-screen / iPad-as-extension) — applied by start-vnc.sh:
#   VNC_DISPLAY_NUM  default: 1          Xvnc runs on :1 (sibling to :0)
#   VNC_RESOLUTION   default: 2388x1668  iPad Pro 11" landscape (long-edge horizontal)
#   VNC_PORT         default: 5901       standard VNC port for :1
#   VNC_BIND         default: tailscale  bind interface (tailscale|localhost|all)
#   VNC_DPI          default: same as I3_DPI (196) — set lower for laptop, higher for high-PPI tablets
#   X2X_DIRECTION    default: east       which edge of :0 leads to :1 (east|west|north|south)

set -euo pipefail

DISPLAY_NUM="${DISPLAY_NUM:-0}"
START_PULSE="${START_PULSE:-1}"
USE_XAUTH="${USE_XAUTH:-1}"
PUBUNTU_SSH_PORT="${PUBUNTU_SSH_PORT:-9923}"
PUBUNTU_SSH_USER="${PUBUNTU_SSH_USER:-ryno}"

# i3 keybind modifiers — match what we had in the proot-Ubuntu setup.
# Ctrl+Alt was chosen because Termux:X11 + on-screen / external keyboards
# often lack a usable Super key, and bare Alt collides with terminal app
# shortcuts. Ctrl+Alt+letter is safe across most other apps.
I3_MOD="${I3_MOD:-Ctrl+Mod1}"
# floating_modifier accepts a SINGLE modifier (used for mouse-drag); pick
# Mod4 (Super) since it likely won't conflict with anything else.
I3_FLOAT_MOD="${I3_FLOAT_MOD:-Mod4}"
I3_FONT="${I3_FONT:-DejaVu Sans Mono 10}"

# X11 DPI. Default 196 is ~2x of the X11 baseline 96 — makes UI elements
# comfortably large on the Pixel 10 screen. Lower to 144 for less, 240+ for
# more. Affects: Pango font rendering (i3bar, rofi), GTK widget scaling,
# Qt apps that honor Xft.dpi.
I3_DPI="${I3_DPI:-196}"

# VNC + x2x defaults — see header for what each one does.
VNC_DISPLAY_NUM="${VNC_DISPLAY_NUM:-1}"
VNC_RESOLUTION="${VNC_RESOLUTION:-2388x1668}"
VNC_PORT="${VNC_PORT:-5901}"
VNC_BIND="${VNC_BIND:-tailscale}"
VNC_DPI="${VNC_DPI:-$I3_DPI}"
X2X_DIRECTION="${X2X_DIRECTION:-east}"

log()  { printf '\033[1;34m[deploy-runtime]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }

# ---- 0. Termux-side prereqs (the runtime scripts need these) -------------
# DroidDesk's "Mesa Zink Core" + "Vulkan Loader" step came down to a handful
# of Termux packages from x11-repo. Without them the X server (Termux:X11)
# and any Termux-native graphical app fall back to all-software rendering.
#
# Per package:
#   termux-x11-nightly        the Termux:X11 server (Lorie)
#   mesa                      OpenGL implementation (includes Zink)
#   vulkan-loader-android     Vulkan ICD loader, Android-specific build
#   mesa-vulkan-icd-swrast    Software Vulkan (lavapipe). PowerVR DXT has no
#                             Mesa Vulkan ICD (PVR is Rogue-only), so swrast
#                             is the workable fallback Vulkan.
#   virglrenderer-android     GL-over-virgl backend (Mesa virpipe driver
#                             targets it for HW-GLES via Android EGL).
#   xorg-xrandr               Resolution control (e.g. for external display).
#   socat                     Used by start-x11.sh for the direct-X bridge
#                             so pubuntu can reach Termux:X11 over TCP
#                             without paying SSH X-forward's single-thread cap.
#   xorg-xauth                Cookie management for USE_XAUTH=1.
#
# Env knobs:
#   START_PULSE             default 1   include pulseaudio (start-x11 uses it)
#   INSTALL_TERMUX_FIREFOX  default 0   ALSO install Termux-native firefox.
log "[0/4] installing Termux-side prereqs (X11, Mesa, Vulkan loader, virgl, socat, xorg-xauth, i3, ...)"

# Make apt non-interactive end-to-end. Termux's `pkg` wraps apt; apt honours
# both DEBIAN_FRONTEND and the dpkg confnew/confold options. Without these
# an upgrade that triggers a conffile prompt (rare but real) hangs forever
# waiting for stdin that doesn't exist.
export DEBIAN_FRONTEND=noninteractive
APT_OPTS=(
    -y
    -o "Dpkg::Options::=--force-confdef"
    -o "Dpkg::Options::=--force-confold"
    -o Acquire::Retries=3
)

pkg install "${APT_OPTS[@]}" x11-repo || true

# vulkan-loader-generic and vulkan-loader-android collide (both ship libvulkan.so).
# We want the -android one (hooks into Android's Vulkan layer, can reach
# vulkan.powervr.so). If the generic build is sitting there from a transitive
# dep, swap it for the android variant.
if dpkg -s vulkan-loader-generic >/dev/null 2>&1 \
        && ! dpkg -s vulkan-loader-android >/dev/null 2>&1; then
    log "    swapping vulkan-loader-generic → vulkan-loader-android"
    pkg uninstall -y vulkan-loader-generic >/dev/null 2>&1 || true
fi

TERMUX_PKGS="termux-x11-nightly mesa vulkan-loader-android mesa-vulkan-icd-swrast virglrenderer-android xorg-xrandr socat xorg-xauth xorg-xrdb xorg-setxkbmap"
# Window manager + GUI toolkit (Termux-native, replaces the old proot-i3 desktop)
TERMUX_PKGS="$TERMUX_PKGS i3 i3status rofi xfce4-terminal dbus"
# VNC server (Xvnc) for second-screen sessions (iPad/laptop), x2x for
# bridging mouse/keyboard, xdotool for the keyboard-driven screen switcher
# (i3 keybind → push cursor past the x2x edge → instant focus transfer).
TERMUX_PKGS="$TERMUX_PKGS tigervnc x2x xdotool"
[ "${START_PULSE:-1}" = "1" ]            && TERMUX_PKGS="$TERMUX_PKGS pulseaudio"
[ "${INSTALL_TERMUX_FIREFOX:-0}" = "1" ] && TERMUX_PKGS="$TERMUX_PKGS firefox"

# Show progress per-package so a hang is visible. apt's output is verbose but
# diagnosable; the suppressed version masked the hangs we hit on 2026-05-29.
# Skip already-installed packages so re-runs are cheap.
for p in $TERMUX_PKGS; do
    if dpkg -s "$p" >/dev/null 2>&1; then
        continue
    fi
    log "    installing $p"
    if ! pkg install "${APT_OPTS[@]}" "$p"; then
        warn "    pkg install $p failed (continuing — re-run later or install by hand)"
    fi
done

write_with_backup() {
    local path="$1"
    if [ -f "$path" ] && [ "${BACKUP:-0}" = "1" ]; then
        cp "$path" "$path.bak"
    fi
    cat > "$path"
    chmod +x "$path"
}

# ---- 1. runtime.env (sourced by the other scripts) -------------------------
log "[1/4] writing ~/runtime.env"
write_with_backup "$HOME/runtime.env" <<EOF
# Generated by pixel/termux/06-deploy-runtime-scripts.sh — DO NOT edit manually;
# re-run the deploy script if these need to change.
export DISPLAY_NUM="$DISPLAY_NUM"
export START_PULSE="$START_PULSE"
# X11 auth: default ON. Termux:X11 starts with magic-cookie auth
# (-auth ~/.Xauthority); cookies are auto-synced to pubuntu over SSH if
# reachable. Set USE_XAUTH=0 to fall back to the permissive -ac mode.
# See pixel/docs/pixel-desktop-architecture.md (security section).
export USE_XAUTH="$USE_XAUTH"
export PUBUNTU_SSH_PORT="$PUBUNTU_SSH_PORT"
export PUBUNTU_SSH_USER="$PUBUNTU_SSH_USER"

# virgl — Mesa's virpipe driver talks to virgl_test_server_android, which
# loads Android's PowerVR GLES blob → hardware-accelerated GL for Termux
# clients. Without these exports Mesa silently falls back to llvmpipe
# (software). Benchmarks earlier picked virgl over llvmpipe for
# consistency on hard scenes — see project_pixel10_proot_overhead_dominates.
# start-x11.sh ensures the daemon is running on this socket.
export GALLIUM_DRIVER=virpipe
export LIBGL_ALWAYS_SOFTWARE=0
export VTEST_SOCKET_NAME="\$PREFIX/tmp/virgl_test.sock"

# VNC + x2x bridge — used by start-vnc.sh / stop-vnc.sh / change-x2x-edge.sh.
# Empty stop-vnc/start-vnc deps means the iPad-as-second-screen layer is purely
# additive; touching these does not affect start-x11.sh / the Pixel display.
export VNC_DISPLAY_NUM="$VNC_DISPLAY_NUM"
export VNC_RESOLUTION="$VNC_RESOLUTION"
export VNC_PORT="$VNC_PORT"
export VNC_BIND="$VNC_BIND"
export VNC_DPI="$VNC_DPI"
export X2X_DIRECTION="$X2X_DIRECTION"
EOF

# ---- 1b. i3 config + cheatsheet + xfce4-terminal config -------------------
# Same keybinds and layout we had in the proot-Ubuntu setup, now installed in
# Termux's own $HOME. Re-runs idempotent — each file gets a .bak copy.
log "[1b/4] writing ~/.Xresources (Xft.dpi=$I3_DPI for scaling)"
write_with_backup "$HOME/.Xresources" <<EOF
! Generated by pixel/termux/06-deploy-runtime-scripts.sh.
! Edit I3_DPI in that script (or re-run with I3_DPI=N) to change.

! Pango/Xft text scaling for all X clients that respect Xft.dpi.
! 96  = native, "100%" scale
! 144 = ~1.5x  (large)
! 196 = ~2x    (Pixel 10 default — comfortable on the phone screen)
! 240 = ~2.5x  (very large)
Xft.dpi:       $I3_DPI

! Sane subpixel/hinting defaults so scaled text still looks crisp.
Xft.antialias: true
Xft.hinting:   true
Xft.hintstyle: hintslight
Xft.rgba:      rgb
Xft.lcdfilter: lcddefault
EOF

log "[1b/4] writing ~/.config/i3/config (mod=$I3_MOD, float_mod=$I3_FLOAT_MOD)"
mkdir -p "$HOME/.config/i3"
write_with_backup "$HOME/.config/i3/config" <<EOF
# i3 config — Pixel 10 + Termux:X11 (Termux-native, no proot)
# Generated by pixel/termux/06-deploy-runtime-scripts.sh.
#
# Modifier: $I3_MOD (Ctrl+Alt by default. Override with I3_MOD env var when
#   redeploying. Ctrl+Alt+letter is safe across most other apps; bare Alt
#   collides with terminal app shortcuts, and Super isn't always reachable
#   on external keyboards.)
#
# Cheat sheet (with \$mod = $I3_MOD):
#   \$mod+slash           pop this cheatsheet in a floating terminal (Ctrl+Alt+/)
#   \$mod+Enter           terminal
#   \$mod+d               app launcher (rofi)
#   \$mod+Shift+q         kill focused window
#   \$mod+h/j/k/l         focus left/down/up/right
#   \$mod+Shift+h/j/k/l   move window
#   \$mod+1..9            switch workspace
#   \$mod+Shift+1..9      move window to workspace
#   \$mod+f               fullscreen
#   \$mod+Shift+space     toggle floating
#   \$mod+s/w/e           layout: stacking / tabbed / split
#   \$mod+b / \$mod+v      split horizontal/vertical
#   \$mod+r               resize mode (then h/j/k/l, Esc to exit)
#   \$mod+-               show scratchpad ; \$mod+Shift+- send to scratchpad
#   \$mod+Shift+c         reload config
#   \$mod+Shift+r         restart i3 (in-place)
#   \$mod+Shift+e         quit i3

set \$mod $I3_MOD
font pango:$I3_FONT

# Mouse+<floating_modifier> drags floating windows. Single-modifier only;
# can't be the same compound-modifier as \$mod when \$mod is Ctrl+Mod1.
floating_modifier $I3_FLOAT_MOD

# Disable XKB's Ctrl+Alt+F1..F12 → XF86Switch_VT_* grab so those keysyms
# reach i3 unchanged. Without this, F-keys can't bind when \$mod includes
# Ctrl+Alt (the X server layer rewrites them). exec_always re-runs on i3
# reload, so a Termux:X11 restart heals itself.
exec_always --no-startup-id setxkbmap -option "" -option srvrkeys:none

# Default terminal + app launcher
bindsym \$mod+Return exec xfce4-terminal
bindsym \$mod+d      exec rofi-dpi -show drun

# Focus / move
bindsym \$mod+h focus left
bindsym \$mod+j focus down
bindsym \$mod+k focus up
bindsym \$mod+l focus right
bindsym \$mod+Left  focus left
bindsym \$mod+Down  focus down
bindsym \$mod+Up    focus up
bindsym \$mod+Right focus right

bindsym \$mod+Shift+h move left
bindsym \$mod+Shift+j move down
bindsym \$mod+Shift+k move up
bindsym \$mod+Shift+l move right
bindsym \$mod+Shift+Left  move left
bindsym \$mod+Shift+Down  move down
bindsym \$mod+Shift+Up    move up
bindsym \$mod+Shift+Right move right

# Window ops
bindsym \$mod+Shift+q kill
bindsym \$mod+f       fullscreen toggle
bindsym \$mod+Shift+space floating toggle
bindsym \$mod+space   focus mode_toggle

# Split orientation
bindsym \$mod+b split horizontal
bindsym \$mod+v split vertical

# Layouts
bindsym \$mod+s layout stacking
bindsym \$mod+w layout tabbed
bindsym \$mod+e layout toggle split

# Workspaces (named — same as proot setup)
set \$ws1 "1:term"
set \$ws2 "2:web"
set \$ws3 "3:code"
set \$ws4 "4:files"
set \$ws5 "5"
set \$ws6 "6"
set \$ws7 "7"
set \$ws8 "8"
set \$ws9 "9"
set \$ws10 "10:scratch"

bindsym \$mod+1 workspace \$ws1
bindsym \$mod+2 workspace \$ws2
bindsym \$mod+3 workspace \$ws3
bindsym \$mod+4 workspace \$ws4
bindsym \$mod+5 workspace \$ws5
bindsym \$mod+6 workspace \$ws6
bindsym \$mod+7 workspace \$ws7
bindsym \$mod+8 workspace \$ws8
bindsym \$mod+9 workspace \$ws9
bindsym \$mod+0 workspace \$ws10

bindsym \$mod+Shift+1 move container to workspace \$ws1
bindsym \$mod+Shift+2 move container to workspace \$ws2
bindsym \$mod+Shift+3 move container to workspace \$ws3
bindsym \$mod+Shift+4 move container to workspace \$ws4
bindsym \$mod+Shift+5 move container to workspace \$ws5
bindsym \$mod+Shift+6 move container to workspace \$ws6
bindsym \$mod+Shift+7 move container to workspace \$ws7
bindsym \$mod+Shift+8 move container to workspace \$ws8
bindsym \$mod+Shift+9 move container to workspace \$ws9
bindsym \$mod+Shift+0 move container to workspace \$ws10

# Reload / restart / quit
bindsym \$mod+Shift+c reload
bindsym \$mod+Shift+r restart
bindsym \$mod+Shift+e exec "i3-nagbar -t warning -m 'Exit i3?' -B 'Yes' 'i3-msg exit'"

# Cheatsheet — bound to mod+slash (Ctrl+Alt+/) because Termux:X11's XKB
# keymap rewrites Ctrl+Alt+F1..F12 to XF86Switch_VT_* regardless of
# srvrkeys:none, making F-keys unusable as i3 bindings when \$mod includes
# Ctrl+Alt. The actual command is in a wrapper script (next file written
# by 06); i3's exec parser is fragile with nested quotes + line continuations.
bindsym \$mod+slash exec --no-startup-id ~/.local/bin/i3-cheatsheet
for_window [title="i3 cheatsheet"] floating enable, resize set width 800 px height 600 px

# Resize mode
mode "resize" {
    bindsym h resize shrink width  10 px or 10 ppt
    bindsym j resize grow   height 10 px or 10 ppt
    bindsym k resize shrink height 10 px or 10 ppt
    bindsym l resize grow   width  10 px or 10 ppt
    bindsym Left  resize shrink width  10 px or 10 ppt
    bindsym Down  resize grow   height 10 px or 10 ppt
    bindsym Up    resize shrink height 10 px or 10 ppt
    bindsym Right resize grow   width  10 px or 10 ppt
    bindsym Escape mode "default"
    bindsym Return mode "default"
}
bindsym \$mod+r mode "resize"

# Scratchpad
bindsym \$mod+Shift+minus move scratchpad
bindsym \$mod+minus scratchpad show

# Window-placement rules (auto-route apps to specific workspaces)
for_window [class="firefox"]        move to workspace \$ws2
for_window [class="Code"]           move to workspace \$ws3
for_window [class="Thunar"]         move to workspace \$ws4
for_window [window_role="pop-up"]   floating enable
for_window [class="Rofi"]           floating enable

# Status bar
bar {
    status_command i3status
    position bottom
    font pango:$I3_FONT
}

# Sensible startup
# Load Xresources (Xft.dpi, etc.) so Pango/GTK clients pick up the scale.
# x-dpi-apply picks the right source per-display: ~/.Xresources for :0,
# the profile's \$VNC_DPI for the VNC display. Without that split, i3 on
# the VNC display would overwrite the per-profile DPI with the global one.
exec_always --no-startup-id \$HOME/.local/bin/x-dpi-apply
exec --no-startup-id dbus-update-activation-environment --systemd DISPLAY XAUTHORITY 2>/dev/null || true
# (xset s off / xset -dpms commands were here but xset isn't packaged in
# Termux's x11-repo; Termux:X11 has no real screensaver anyway, so they
# weren't doing anything useful.)
EOF
chmod 644 "$HOME/.config/i3/config"

log "[1b/4] writing ~/.local/bin/i3-cheatsheet"
mkdir -p "$HOME/.local/bin"
write_with_backup "$HOME/.local/bin/i3-cheatsheet" <<'EOF'
#!/data/data/com.termux/files/usr/bin/bash
# Cheat-sheet pager — bound to $mod+slash in i3 config.
# Opens an xfce4-terminal showing all bindsym lines from the i3 config.
exec xfce4-terminal -T "i3 cheatsheet" -e \
    "sh -c 'grep -E \"^bindsym \" \"$HOME/.config/i3/config\" | sed \"s/^bindsym //; s/exec //\" | less'"
EOF
chmod +x "$HOME/.local/bin/i3-cheatsheet"

log "[1b/4] writing ~/.local/bin/x-dpi-apply (display-aware Xft.dpi loader)"
write_with_backup "$HOME/.local/bin/x-dpi-apply" <<'EOF'
#!/data/data/com.termux/files/usr/bin/bash
# Apply Xft.dpi for the current $DISPLAY:
#   - on the VNC display (:$VNC_DISPLAY_NUM)  → use $VNC_DPI from the
#     currently-active profile (env-inherited from start-vnc.sh)
#   - on every other display (:0, mostly)     → merge ~/.Xresources
#                                                (which desktop-apply owns)
#
# Bound by i3's `exec_always` so it runs on i3 start + on every i3 reload.
# Without this, the unconditional `xrdb -merge ~/.Xresources` would
# overwrite the per-display VNC DPI on i3 reload.
#
# IMPORTANT: do NOT re-source ~/runtime.env here. The active profile's
# VNC_DPI overrides runtime.env's default value in start-vnc.sh, but only
# in the env passed to i3. If we re-source the file, we lose the profile
# value and end up applying runtime.env's default to every display.
set -uo pipefail

# Strip ":" + screen suffix from $DISPLAY (":1.0" → "1")
CURR="${DISPLAY##:}"
CURR="${CURR%%.*}"

if [ -n "${VNC_DPI:-}" ] && [ "$CURR" = "${VNC_DISPLAY_NUM:-1}" ]; then
    echo "Xft.dpi: $VNC_DPI" | xrdb -merge
else
    [ -f "$HOME/.Xresources" ] && xrdb -merge "$HOME/.Xresources"
fi
EOF
chmod +x "$HOME/.local/bin/x-dpi-apply"

log "[1b/4] writing ~/.local/bin/rofi-dpi (per-display rofi launcher)"
write_with_backup "$HOME/.local/bin/rofi-dpi" <<'EOF'
#!/data/data/com.termux/files/usr/bin/bash
# Launch rofi at the current display's Xft.dpi. rofi's own dpi:-1 autodetect
# on Termux:X11 returns the X server's reported 96 (not Xft.dpi), which on
# our 170-DPI Pixel makes the launcher visibly smaller than everything else.
# Reading xrdb directly gives us the right per-display value.
DPI=$(xrdb -query 2>/dev/null | awk '/^Xft\.dpi:/ {print $2; exit}')
exec rofi -dpi "${DPI:-96}" "$@"
EOF
chmod +x "$HOME/.local/bin/rofi-dpi"

log "[1b/4] writing ~/.local/bin/x2x-refresh (re-grab pointer after i3 restart)"
write_with_backup "$HOME/.local/bin/x2x-refresh" <<'EOF'
#!/data/data/com.termux/files/usr/bin/bash
# Re-spawn the currently-running x2x bridge with the SAME args.
#
# Why: i3-msg restart (and some other X session operations) invalidate
# x2x's pointer grab. Once invalidated, x2x can no longer detect the
# cursor crossing the configured edge — neither manual mouse traversal
# nor the screen-switch keybind work. Restarting x2x re-grabs the edge
# and everything works again.
#
# Safe no-op when no x2x is running.
set -uo pipefail
LOG_DIR="${LOG_DIR:-$HOME/.cache/x11-logs}"

LIVE=$(pgrep -af 'x2x -from' 2>/dev/null | grep -v 'pgrep ' | head -1)
[ -z "$LIVE" ] && exit 0   # no x2x running → nothing to refresh

# Extract the cmdline (everything after the leading PID).
CMD=$(echo "$LIVE" | cut -d' ' -f2-)

# Kill old + clean pidfile, then re-spawn with identical args.
pkill -f 'x2x -from' 2>/dev/null
rm -f "$LOG_DIR/x2x.pid"
sleep 1
nohup $CMD >>"$LOG_DIR/x2x.log" 2>&1 &
echo $! > "$LOG_DIR/x2x.pid"
echo "[x2x-refresh] restarted: $CMD"
EOF
chmod +x "$HOME/.local/bin/x2x-refresh"

log "[1b/4] writing ~/.local/bin/screen-switch (x2x keyboard trigger)"
write_with_backup "$HOME/.local/bin/screen-switch" <<'EOF'
#!/data/data/com.termux/files/usr/bin/bash
# Force x2x to transfer focus between Pixel (:0) and the secondary VNC
# display. The two paths use DIFFERENT mechanisms because x2x's return
# detection won't accept synthetic events.
#
# Forward (Pixel → secondary): push cursor across the configured x2x
#   edge with xdotool. x2x catches the edge ENTRY event and forwards
#   user input to the secondary.
#
# Return (secondary → Pixel): we cannot trigger x2x with xdotool here —
#   x2x's return path tracks ITS OWN forwarded input events, not arbitrary
#   motion on :1, so xdotool warps are invisible to it. Instead we
#   RESTART x2x. The kill releases x2x's keyboard/pointer grab on :0,
#   instantly returning user input to the Pixel; the fresh x2x is ready
#   for the next forward transfer.
#
# Why we read X2X_DIRECTION from the running x2x process instead of
# runtime.env: the active profile (loaded by start-vnc.sh) may have
# overridden runtime.env's default. The truth is in x2x's cmdline.

set -uo pipefail

X2X_DIRECTION=$(pgrep -af 'x2x -from' 2>/dev/null \
                | grep -oE '\-(east|west|north|south)' | head -1 | sed 's/^-//')
if [ -z "$X2X_DIRECTION" ]; then
    # No x2x running → no second screen to switch to. Silent no-op.
    exit 0
fi

VNC_DISPLAY_NUM=$(pgrep -af 'x2x -from' 2>/dev/null \
                  | grep -oE '\-to :[0-9]+' | head -1 | sed 's/^-to ://')
VNC_DISPLAY_NUM="${VNC_DISPLAY_NUM:-1}"

CURR="${DISPLAY##:}"; CURR="${CURR%%.*}"

if [ "$CURR" = "$VNC_DISPLAY_NUM" ]; then
    # On secondary → restart x2x to release its grab on :0
    exec "$HOME/.local/bin/x2x-refresh"
fi

# On primary → cross the configured edge with a two-step nudge so x2x
# always sees an edge-entry event regardless of starting cursor position.
case "$X2X_DIRECTION" in
    east)  xdotool mousemove_relative --  -100 0
           xdotool mousemove_relative --  3000 0 ;;
    west)  xdotool mousemove_relative --   100 0
           xdotool mousemove_relative -- -3000 0 ;;
    north) xdotool mousemove_relative -- 0   100
           xdotool mousemove_relative -- 0 -3000 ;;
    south) xdotool mousemove_relative -- 0  -100
           xdotool mousemove_relative -- 0  3000 ;;
esac
EOF
chmod +x "$HOME/.local/bin/screen-switch"

log "[1b/4] writing xfce4-terminal config (xfconf XML — terminalrc is ignored when xfconfd is running)"
# Why xfconf, not terminalrc:
#   xfce4-terminal reads settings from xfconfd when it's running on the X
#   session. Termux's dbus-activation autostarts xfconfd as soon as ANY
#   xfconf client (incl. xfce4-terminal itself) asks for it. From that
#   point on, xfconfd is the canonical store — edits to terminalrc are
#   silently ignored. So we write the xfconf XML directly. To change colours
#   or font durably: edit this heredoc and re-run 06; xfconfd's inotify
#   watcher picks it up live.
mkdir -p "$HOME/.config/xfce4/xfconf/xfce-perchannel-xml"
write_with_backup "$HOME/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-terminal.xml" <<EOF
<?xml version="1.1" encoding="UTF-8"?>

<channel name="xfce4-terminal" version="1.0">
  <!-- font: match I3_FONT so the whole desktop looks consistent. -->
  <property name="font-name" type="string" value="$I3_FONT"/>

  <!-- Palette = "Dark Pastels" (xfce4-terminal built-in scheme). The default
       xfce4 blue (#3465a4) is muddy on dark backgrounds; the regular blue
       here is #1e6fa8 and bright blue is #566fb3 — much more readable for
       shell prompts, syntax highlighting, ls colouring. To swap palette:
       pick from \$PREFIX/share/xfce4/terminal/colorschemes/<name>.theme,
       lift its ColorForeground/Background/Cursor/Palette lines, paste here. -->
  <property name="color-foreground" type="string" value="#dcdcdc"/>
  <property name="color-background" type="string" value="#2c2c2c"/>
  <property name="color-cursor" type="string" value="#dcdcdc"/>
  <property name="color-palette" type="string" value="#3f3f3f;#705050;#60b48a;#dfaf8f;#1e6fa8;#dc8cc3;#8cd0d3;#dcdcdc;#709080;#dca3a3;#72d5a3;#f0dfaf;#566fb3;#ec93d3;#93e0e3;#ffffff"/>

  <!-- Keyboard & menu — Alt+letter must not steal focus from terminal apps
       like tmux/vim. Hide menu bar by default; right-click → "Show Menubar"
       to bring it back temporarily. -->
  <property name="misc-menubar-default" type="bool" value="false"/>
  <property name="shortcuts-no-mnemonics" type="bool" value="true"/>
  <property name="shortcuts-no-menukey" type="bool" value="false"/>

  <!-- Misc UI. -->
  <property name="scrolling-unlimited" type="bool" value="true"/>
  <property name="misc-show-toolbar" type="bool" value="false"/>
  <property name="misc-show-borders" type="bool" value="true"/>
</channel>
EOF

# ---- 1c. rofi config + pubuntu launchers -----------------------------------
# rofi is the app launcher bound to $mod+d in the i3 config. We:
#   1. Drop a rofi config that enables a combi mode (apps + windows + run +
#      pubuntu-docker) so a single $mod+Tab gives everything at once.
#   2. Drop .desktop files for common pubuntu-side apps so they show up in
#      `rofi -show drun` alongside Termux-native apps. Each entry sshs into
#      pubuntu and runs the app with DISPLAY pointing back at Termux:X11.
#   3. Drop a small "rofi-pubuntu-docker" script that lists running pubuntu
#      Docker containers and opens a shell into the picked one.

log "[1c/4] writing ~/.config/rofi/config.rasi (theme + combi mode)"
mkdir -p "$HOME/.config/rofi"
# Use the deploy-time absolute path for the custom mode — rofi doesn't expand
# ~ in .rasi files, so `~/.local/bin/...` would be a literal path and fail.
PUBUNTU_HELPER="$HOME/.local/bin/rofi-pubuntu"
write_with_backup "$HOME/.config/rofi/config.rasi" <<EOF
configuration {
    /* Names changed in rofi 1.7: modi → modes, combi-modi → combi-modes.
     * pubuntu mode is intentionally NOT in this list: it SSHs into pubuntu,
     * ~1-2s latency that rofi would pay on every launch. Access it
     * explicitly via Ctrl+Alt+Shift+p (see i3 config). */
    modes:        "drun,run,window";
    /* combi shows everything in the listed modes simultaneously — keep it
     * fast, no pubuntu mode here either. */
    combi-modes:  "drun,window";
    show-icons:   true;
    icon-theme:  "Adwaita";
    display-drun:   " Apps";
    display-run:    " Run";
    display-window: " Windows";
    display-combi:  " All";

    /* Terminal used when launching CLI apps (vim, htop, etc.) from rofi.
     * Default 'rofi-sensible-terminal' isn't installed in Termux, so
     * vim/htop/... would fail with "no terminal found". xfce4-terminal
     * is what 06 installs and what i3 binds Ctrl+Alt+Enter to. */
    terminal: "xfce4-terminal";

    /* DPI scaling — dpi: -1 is rofi's magic value for "follow Xft.dpi from
     * the running X server". Per-display! On :0 (Pixel) Xft.dpi comes from
     * ~/.Xresources (managed by desktop-apply). On :1 (the VNC display)
     * Xft.dpi comes from the active profile's VNC_DPI (managed by
     * start-vnc.sh + x-dpi-apply). Same rofi process, different size per
     * display. */
    dpi:  -1;

    /* Explicit font size — themes often set their own font, so set ours
     * loud and clear here. Point sizes scale with dpi above.
     * Matched to I3_FONT so rofi and i3bar are visually consistent. */
    font: "$I3_FONT";

    /* Vim-style row nav with Ctrl+J/K. Why this needs three lines instead
     * of one: rofi 2.0 binds Ctrl+J to \`kb-accept-entry\` and Ctrl+K to
     * \`kb-remove-to-eol\` by default — so naively writing
     *     kb-row-down: "...,Control+j";
     * makes rofi error at startup with "unexpected invalid property name"
     * (the parser's way of saying "this binding is already in use"). We
     * have to UNBIND them from the default actions first, then re-bind
     * them to row nav. Defaults preserved: Return / Ctrl+M still accept,
     * Ctrl+P/N still move rows. */
    kb-accept-entry:  "Control+m,Return,KP_Enter";  /* drop Control+j */
    kb-remove-to-eol: "";                            /* drop Control+k entirely */
    kb-row-down:      "Down,Control+n,Control+j";
    kb-row-up:        "Up,Control+p,Control+k";
}

/* Pick a built-in theme. List with \`ls \$PREFIX/share/rofi/themes/\` and
 * substitute below, or run \`rofi-theme-selector\` to browse interactively. */
@theme "Arc-Dark"
EOF

log "[1c/4] writing pubuntu .desktop launchers in ~/.local/share/applications"
mkdir -p "$HOME/.local/share/applications"

# Pubuntu shell — opens xfce4-terminal with an SSH session into pubuntu.
write_with_backup "$HOME/.local/share/applications/pubuntu-shell.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Pubuntu Shell
Comment=SSH into pubuntu in a terminal
Exec=xfce4-terminal -T "pubuntu" -e "ssh -p ${PUBUNTU_SSH_PORT} ${PUBUNTU_SSH_USER}@localhost"
Icon=utilities-terminal
Categories=System;TerminalEmulator;
EOF

# Pubuntu Firefox — ssh + DISPLAY = direct-X bridge in Termux.
# AVF_TAP_IP is filled at deploy time; if Podroid isn't running when 06
# runs, we leave a placeholder and warn.
DEPLOY_AVF_TAP_IP=$(ifconfig 2>/dev/null | awk '/^avf_tap/ {found=1; next} found && /inet / {print $2; exit} /^[a-z]/ {found=0}')
if [ -z "$DEPLOY_AVF_TAP_IP" ]; then
    DEPLOY_AVF_TAP_IP="10.198.187.116"   # known stable AVF TAP IP on Pixel 10
    warn "    avf_tap_fixed interface not present at deploy time;"
    warn "    .desktop launchers use $DEPLOY_AVF_TAP_IP as best-effort. Edit"
    warn "    files in ~/.local/share/applications/ if your TAP IP differs."
fi

write_with_backup "$HOME/.local/share/applications/pubuntu-firefox.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Firefox (pubuntu)
Comment=Firefox inside pubuntu, displayed via direct-X
Exec=ssh -p ${PUBUNTU_SSH_PORT} ${PUBUNTU_SSH_USER}@localhost 'DISPLAY=${DEPLOY_AVF_TAP_IP}:0 nohup firefox %U >/dev/null 2>&1 &'
Icon=firefox
Categories=Network;WebBrowser;
StartupNotify=false
EOF

# Pubuntu emergency kill — when an X app misbehaves, kill all pubuntu X clients
write_with_backup "$HOME/.local/share/applications/pubuntu-kill-x.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Pubuntu — kill all X apps
Comment=Kill every pubuntu process that has DISPLAY pointing at Termux:X11
Exec=ssh -p ${PUBUNTU_SSH_PORT} ${PUBUNTU_SSH_USER}@localhost 'pkill -f "DISPLAY=${DEPLOY_AVF_TAP_IP}"'
Icon=process-stop
Categories=System;
EOF

# Hide unhelpful default rofi-drun entries. Each .desktop file in the user
# dir takes precedence over the same-named system file (freedesktop spec).
# IMPORTANT: a `.desktop` file needs at minimum Type+Name+NoDisplay to be
# considered valid — bare `Hidden=true` is silently ignored by rofi.
#
# The list below targets only entries that ARE visible by default. Many
# Termux .desktop files (gtk3-demo, i3, gtk3-icon-browser, etc.) already
# carry `NoDisplay=true` from their packages, so no override is needed.
#
# Audit visible entries with:
#   for f in \$PREFIX/share/applications/*.desktop; do
#       grep -q '^NoDisplay=true' "\$f" || echo "  \$(basename \$f .desktop)"
#   done
log "[1c/4] hiding default-but-noise entries from rofi drun"
for app in org.gnome.Vte.App.Gtk3 org.gnome.Vte.App.Gtk4 rofi xfce4-about \
           vim gvim; do
    write_with_backup "$HOME/.local/share/applications/$app.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=hidden
NoDisplay=true
EOF
done

# Clean up stale broken overrides from a previous deploy (the bare
# Hidden=true files we used to write). They didn't actually do anything,
# but they're dead weight.
for app in gtk3-demo gtk3-icon-browser gtk3-widget-factory i3; do
    f="$HOME/.local/share/applications/$app.desktop"
    if [ -f "$f" ] && grep -qx "Hidden=true" "$f" 2>/dev/null \
        && ! grep -q "^Type=" "$f" 2>/dev/null; then
        rm -f "$f"
    fi
done

log "[1c/4] writing ~/.local/bin/rofi-pubuntu (custom rofi mode)"
mkdir -p "$HOME/.local/bin"
write_with_backup "$HOME/.local/bin/rofi-pubuntu" <<EOF
#!/data/data/com.termux/files/usr/bin/bash
# rofi script-mode for running commands in pubuntu.
# - No args:    emit suggestion list from ~/.config/pubuntu-commands.txt
#               (rofi shows it, user can also TYPE any command).
# - With arg:   run \$1 in pubuntu via SSH, displayed in xfce4-terminal.
#
# The command runs with the AVF TAP DISPLAY exported, so GUI apps render
# in Termux:X11. CLI commands run in the terminal and pause on exit so
# you can read output.
set -uo pipefail
SSH_TARGET="${PUBUNTU_SSH_USER}@localhost"
SSH_PORT=${PUBUNTU_SSH_PORT}
SUGGESTIONS="\$HOME/.config/pubuntu-commands.txt"

if [ -z "\${1:-}" ]; then
    # List suggestions
    if [ -f "\$SUGGESTIONS" ]; then
        grep -vE "^\s*#|^\s*\$" "\$SUGGESTIONS"
    else
        # Defaults if no custom file exists
        echo "htop"
        echo "ncdu /"
        echo "df -h"
        echo "docker ps"
        echo "firefox"
        echo "thunar"
    fi
else
    CMD="\$1"
    # GUI vs CLI heuristic: if the command starts with one of these
    # known GUI app names, set DISPLAY and launch detached; otherwise
    # run in xfce4-terminal so output is visible.
    case "\$CMD" in
        firefox*|thunar*|code*|gimp*|libreoffice*|inkscape*|blender*|kicad*)
            ssh -p "\$SSH_PORT" "\$SSH_TARGET" \\
                "DISPLAY=10.198.187.116:0 nohup \$CMD >/dev/null 2>&1 &" </dev/null
            ;;
        *)
            xfce4-terminal --title "pubuntu: \$CMD" -e \\
                "ssh -t -p \$SSH_PORT \$SSH_TARGET 'echo + \$CMD; \$CMD; echo; echo --- done. press Enter to close ---; read'" &
            disown
            ;;
    esac
fi
EOF
chmod +x "$HOME/.local/bin/rofi-pubuntu"

# Default suggestions file (user can edit freely — it's not overwritten
# by re-deploys after the first write).
if [ ! -f "$HOME/.config/pubuntu-commands.txt" ]; then
    mkdir -p "$HOME/.config"
    cat > "$HOME/.config/pubuntu-commands.txt" <<'EOF'
# Suggestions for the rofi "pubuntu" mode (Ctrl+Alt+Shift+P).
# One command per line. Edit freely — this file isn't overwritten on
# 06 re-deploy (only created if missing).
# GUI apps (firefox/thunar/code/gimp/etc.) launch detached via the
# AVF TAP DISPLAY; everything else runs inside xfce4-terminal so you
# see its output.

# GUI apps
firefox
thunar

# CLI
htop
ncdu /
df -h
docker ps
docker images
systemctl --no-pager status
journalctl -xe
free -h
EOF
fi

# Append rofi keybinds to the i3 config (idempotent). $mod+Tab: combi
# (fast, no pubuntu mode). $mod+Shift+p: pubuntu mode (slow, on-demand only).
PUBUNTU_HELPER_BIND="$HOME/.local/bin/rofi-pubuntu"
# Remove any old docker-mode bindings from earlier deploys (idempotent).
sed -i "/^# Docker mode on-demand/,+1d; /^bindsym \\\$mod+Shift+d exec.*rofi.*docker/d" \
    "$HOME/.config/i3/config" 2>/dev/null
if ! grep -q "rofi -show combi" "$HOME/.config/i3/config"; then
    cat >> "$HOME/.config/i3/config" <<EOF

# Combi launcher (apps + windows) — fast.
bindsym \$mod+Tab exec --no-startup-id rofi-dpi -show combi
# Pubuntu mode on-demand only (SSHs into pubuntu, ~1-2s on first launch).
bindsym \$mod+Shift+p exec --no-startup-id rofi-dpi -modi "pubuntu:${PUBUNTU_HELPER_BIND}" -show pubuntu
EOF
fi

# Screen-switch keybind: cursor jumps to the other display (Pixel ↔
# secondary VNC). Uses the screen-switch helper which knows the current
# display and the x2x edge direction.
#
# Two bindings because layouts vary: 'grave' (\`) isn't reliably mapped
# on Termux:X11 with all software keyboards — 'x' is the dependable
# fallback (mnemonic: "X-display switch"; chosen over 's' because i3's
# default 's' = layout stacking which collides).
# i3 accepts multiple bindings on the same action, so both work.
if ! grep -q "screen-switch" "$HOME/.config/i3/config"; then
    cat >> "$HOME/.config/i3/config" <<EOF

# Screen-switch (Pixel <-> secondary VNC display, follows X2X_DIRECTION)
bindsym \$mod+x exec --no-startup-id \$HOME/.local/bin/screen-switch
bindsym \$mod+grave exec --no-startup-id \$HOME/.local/bin/screen-switch
EOF
fi

# Clean up the old docker helper if it's still around from earlier deploys
rm -f "$HOME/.local/bin/rofi-pubuntu-docker" 2>/dev/null

# ---- 1d. Look-and-feel: desktop-look.env + desktop-apply + presets ---------
# Architecture: a single user-facing config file (~/.config/desktop-look.env)
# is the source of truth for everything UI-tunable. A small helper
# (desktop-apply) reads it and rewrites the four downstream config files
# (.Xresources, rofi, i3, xfce4-terminal xfconf XML) so they stay in sync.
# Presets are just pre-canned desktop-look.env contents; `desktop-preset NAME`
# copies one over the live look-env and calls desktop-apply.
#
# Day-to-day workflow:
#   $EDITOR ~/.config/desktop-look.env  # tweak DPI / FONT_SIZE / palette / etc.
#   desktop-apply                       # propagate to all configs + restart i3
#
# Wholesale swap:
#   desktop-preset vnc-tablet           # cp preset → look-env, then apply
log "[1d/4] writing desktop-look.env + desktop-apply + presets"
mkdir -p "$HOME/.config/desktop-presets" "$HOME/.local/bin"

# desktop-look.env: only write on first deploy. After that the user owns
# this file — re-running 06 must not stomp their tweaks. To reset, delete
# the file and re-run 06, or run \`desktop-preset native\`.
if [ ! -f "$HOME/.config/desktop-look.env" ]; then
    # I3_FONT default looks like "DejaVu Sans Mono 10". Split family + size
    # so they're independently tweakable.
    DEFAULT_FONT_FAMILY="${I3_FONT% *}"
    DEFAULT_FONT_SIZE="${I3_FONT##* }"
    cat > "$HOME/.config/desktop-look.env" <<EOF
# Single source of truth for dynamic look-and-feel. Edit any line and run
# \`desktop-apply\` to push the value into:
#   ~/.Xresources                       (Xft.dpi)
#   ~/.config/rofi/config.rasi          (dpi, font)
#   ~/.config/i3/config                 (font pango:, bar position, gaps)
#   ~/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-terminal.xml
#                                       (font-name, palette colours)
# Or to swap an entire look at once: \`desktop-preset <name>\`.

# X session DPI — affects Pango (i3bar, rofi, gtk apps, xfce4-terminal),
# Xft fonts, and anything reading Xft.dpi. Higher = bigger UI.
DPI=$I3_DPI

# Font family + size used by i3 titles, i3bar, rofi, xfce4-terminal.
FONT_FAMILY="$DEFAULT_FONT_FAMILY"
FONT_SIZE=$DEFAULT_FONT_SIZE

# i3bar position — top or bottom. Top is recommended on Pixel-class phones
# so the bar doesn't get clipped by the rounded bottom corners.
BAR_POSITION=bottom

# i3 gaps — px of empty space between tiled windows and screen edges.
# Useful for rounded-corner clearance (e.g. GAPS_BOTTOM=80 on Pixel 10).
GAPS_TOP=0
GAPS_BOTTOM=0
GAPS_LEFT=0
GAPS_RIGHT=0

# xfce4-terminal palette. Default = "Dark Pastels" (built-in xfce4 scheme,
# noticeably brighter blue/cyan than the muddy xfce4 defaults).
TERMINAL_FG="#dcdcdc"
TERMINAL_BG="#2c2c2c"
TERMINAL_CURSOR="#dcdcdc"
TERMINAL_PALETTE="#3f3f3f;#705050;#60b48a;#dfaf8f;#1e6fa8;#dc8cc3;#8cd0d3;#dcdcdc;#709080;#dca3a3;#72d5a3;#f0dfaf;#566fb3;#ec93d3;#93e0e3;#ffffff"
EOF
fi

# Presets are always overwritten — they're canonical templates, not
# user-owned. To save your own preset, copy your customised look-env:
#   cp ~/.config/desktop-look.env ~/.config/desktop-presets/myname.env
write_with_backup "$HOME/.config/desktop-presets/native.env" <<'EOF'
# Pixel 10 phone screen — high-DPI, comfortable scale
DPI=196
FONT_FAMILY="DejaVu Sans Mono"
FONT_SIZE=10
BAR_POSITION=bottom
GAPS_TOP=0
GAPS_BOTTOM=0
GAPS_LEFT=0
GAPS_RIGHT=0
TERMINAL_FG="#dcdcdc"
TERMINAL_BG="#2c2c2c"
TERMINAL_CURSOR="#dcdcdc"
TERMINAL_PALETTE="#3f3f3f;#705050;#60b48a;#dfaf8f;#1e6fa8;#dc8cc3;#8cd0d3;#dcdcdc;#709080;#dca3a3;#72d5a3;#f0dfaf;#566fb3;#ec93d3;#93e0e3;#ffffff"
EOF

write_with_backup "$HOME/.config/desktop-presets/vnc-tablet.env" <<'EOF'
# Mid-range tablet via VNC — moderate DPI
DPI=144
FONT_FAMILY="DejaVu Sans Mono"
FONT_SIZE=11
BAR_POSITION=bottom
GAPS_TOP=0
GAPS_BOTTOM=0
GAPS_LEFT=0
GAPS_RIGHT=0
TERMINAL_FG="#dcdcdc"
TERMINAL_BG="#2c2c2c"
TERMINAL_CURSOR="#dcdcdc"
TERMINAL_PALETTE="#3f3f3f;#705050;#60b48a;#dfaf8f;#1e6fa8;#dc8cc3;#8cd0d3;#dcdcdc;#709080;#dca3a3;#72d5a3;#f0dfaf;#566fb3;#ec93d3;#93e0e3;#ffffff"
EOF

write_with_backup "$HOME/.config/desktop-presets/vnc-desktop.env" <<'EOF'
# Laptop or desktop monitor via VNC — standard DPI
DPI=96
FONT_FAMILY="DejaVu Sans Mono"
FONT_SIZE=12
BAR_POSITION=bottom
GAPS_TOP=0
GAPS_BOTTOM=0
GAPS_LEFT=0
GAPS_RIGHT=0
TERMINAL_FG="#dcdcdc"
TERMINAL_BG="#2c2c2c"
TERMINAL_CURSOR="#dcdcdc"
TERMINAL_PALETTE="#3f3f3f;#705050;#60b48a;#dfaf8f;#1e6fa8;#dc8cc3;#8cd0d3;#dcdcdc;#709080;#dca3a3;#72d5a3;#f0dfaf;#566fb3;#ec93d3;#93e0e3;#ffffff"
EOF

# desktop-apply: read desktop-look.env, rewrite all 4 generated configs,
# live-restart i3 if it's running. Idempotent.
write_with_backup "$HOME/.local/bin/desktop-apply" <<'EOF'
#!/data/data/com.termux/files/usr/bin/bash
# Push values from ~/.config/desktop-look.env (or a custom file passed as $1)
# into the four live config files. Safe to re-run.
#
# Usage:
#   desktop-apply                      # apply ~/.config/desktop-look.env
#   desktop-apply path/to/other.env    # apply a different file (e.g. a preset
#                                      # without making it the new default)
set -uo pipefail

LOOK="${1:-$HOME/.config/desktop-look.env}"
if [ ! -f "$LOOK" ]; then
    echo "[desktop-apply] no look file at $LOOK" >&2
    echo "    run 'desktop-preset native' to seed one, or edit/re-run 06." >&2
    exit 1
fi

# Defaults for any unset keys so a partial look-env doesn't blow up sed.
DPI=96
FONT_FAMILY="DejaVu Sans Mono"
FONT_SIZE=10
BAR_POSITION=bottom
GAPS_TOP=0
GAPS_BOTTOM=0
GAPS_LEFT=0
GAPS_RIGHT=0
TERMINAL_FG="#dcdcdc"
TERMINAL_BG="#2c2c2c"
TERMINAL_CURSOR="#dcdcdc"
TERMINAL_PALETTE=""
# shellcheck source=/dev/null
. "$LOOK"

FONT="$FONT_FAMILY $FONT_SIZE"
echo "[desktop-apply] DPI=$DPI FONT=\"$FONT\" BAR=$BAR_POSITION GAPS=t:$GAPS_TOP/b:$GAPS_BOTTOM/l:$GAPS_LEFT/r:$GAPS_RIGHT"

# --- 1. ~/.Xresources : Xft.dpi --------------------------------------------
if [ -f "$HOME/.Xresources" ] && grep -q '^Xft.dpi:' "$HOME/.Xresources"; then
    sed -i "s/^Xft.dpi:.*/Xft.dpi:       $DPI/" "$HOME/.Xresources"
else
    {
        echo "! Auto-managed by desktop-apply — edit ~/.config/desktop-look.env instead."
        echo "Xft.dpi:       $DPI"
    } > "$HOME/.Xresources"
fi

# --- 2. rofi config : font (dpi is hard-set to -1 so rofi follows Xft.dpi
# per-display; don't overwrite it here) ------------------------------------
ROFI="$HOME/.config/rofi/config.rasi"
if [ -f "$ROFI" ]; then
    sed -i "s|^    font: .*|    font: \"$FONT\";|" "$ROFI"
fi

# --- 3. i3 config : global font, bar font/position, gaps -------------------
I3CONF="$HOME/.config/i3/config"
if [ -f "$I3CONF" ]; then
    sed -i "s|^font pango:.*|font pango:$FONT|"         "$I3CONF"
    sed -i "s|^    font pango:.*|    font pango:$FONT|" "$I3CONF"
    sed -i "s|^    position .*|    position $BAR_POSITION|" "$I3CONF"
    # Gaps — one line per direction; insert if missing, rewrite if present.
    for E in top bottom left right; do
        case "$E" in
            top)    V="$GAPS_TOP"    ;;
            bottom) V="$GAPS_BOTTOM" ;;
            left)   V="$GAPS_LEFT"   ;;
            right)  V="$GAPS_RIGHT"  ;;
        esac
        if grep -q "^gaps $E " "$I3CONF"; then
            sed -i "s|^gaps $E .*|gaps $E $V|" "$I3CONF"
        else
            echo "gaps $E $V" >> "$I3CONF"
        fi
    done
fi

# --- 4. xfce4-terminal xfconf XML : font-name + palette --------------------
# Why xfconf-via-XML and not terminalrc: xfconfd shadows terminalrc whenever
# it's running on the X session (Termux's dbus-activation autostarts it).
# Edits to terminalrc are silently ignored. xfconfd watches this XML via
# inotify, so writes here are picked up live.
XFCONF="$HOME/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-terminal.xml"
if [ -f "$XFCONF" ]; then
    upd() {  # upd <property-name> <new-value>
        local k="$1" v="$2"
        # Use | as sed delimiter since values contain # (hex colours).
        sed -i "s|<property name=\"$k\" type=\"string\" value=\"[^\"]*\"/>|<property name=\"$k\" type=\"string\" value=\"$v\"/>|" "$XFCONF"
    }
    upd font-name        "$FONT"
    upd color-foreground "$TERMINAL_FG"
    upd color-background "$TERMINAL_BG"
    upd color-cursor     "$TERMINAL_CURSOR"
    [ -n "$TERMINAL_PALETTE" ] && upd color-palette "$TERMINAL_PALETTE"
fi

# --- 5. live-apply if X session is up --------------------------------------
if pgrep -x i3 >/dev/null 2>&1; then
    : "${DISPLAY:=:0}"
    : "${XAUTHORITY:=$HOME/.Xauthority}"
    export DISPLAY XAUTHORITY
    command -v xrdb >/dev/null 2>&1 && xrdb -merge "$HOME/.Xresources" 2>/dev/null
    i3-msg restart 2>&1 | head -3 || true
    # i3-msg restart invalidates x2x's pointer grab — refresh it if it's
    # running so manual edge-traversal + the Ctrl+Alt+x keybind keep working.
    [ -x "$HOME/.local/bin/x2x-refresh" ] && "$HOME/.local/bin/x2x-refresh"
    echo "[desktop-apply]   live-applied to $DISPLAY"
else
    echo "[desktop-apply]   (no i3 running — files updated; effect on next start-x11.sh)"
fi
EOF
chmod +x "$HOME/.local/bin/desktop-apply"

# desktop-preset: thin shim. Copies a named preset over desktop-look.env then
# delegates to desktop-apply. The old preset-script's heavy lifting now lives
# in desktop-apply so both `desktop-preset NAME` and `desktop-apply` go through
# exactly the same code path.
write_with_backup "$HOME/.local/bin/desktop-preset" <<'EOF'
#!/data/data/com.termux/files/usr/bin/bash
# Swap to a predefined look. Presets are full desktop-look.env files in
# ~/.config/desktop-presets/. Selecting one copies it over the live look-env
# and runs desktop-apply.
#
# Usage:
#   desktop-preset               list available
#   desktop-preset list          list available
#   desktop-preset <name>        swap + apply
set -euo pipefail

PRESET_DIR="$HOME/.config/desktop-presets"
PRESET="${1:-list}"

list_presets() {
    echo "Available presets (from $PRESET_DIR):"
    local f name desc
    for f in "$PRESET_DIR"/*.env; do
        [ -e "$f" ] || { echo "  (none — drop a .env file in the dir)"; return; }
        name=$(basename "$f" .env)
        desc=$(head -1 "$f" | sed 's/^# *//')
        printf "  %-15s %s\n" "$name" "$desc"
    done
    echo
    echo "Usage:  desktop-preset <name>"
    echo "(or edit ~/.config/desktop-look.env directly + 'desktop-apply')"
}

case "$PRESET" in
    ""|list|-l|--list|-h|--help) list_presets; exit 0 ;;
esac

PRESET_FILE="$PRESET_DIR/$PRESET.env"
if [ ! -f "$PRESET_FILE" ]; then
    echo "[desktop-preset] no preset at $PRESET_FILE" >&2
    list_presets >&2
    exit 1
fi

echo "[desktop-preset] switching look to '$PRESET'"
cp "$PRESET_FILE" "$HOME/.config/desktop-look.env"
exec "$HOME/.local/bin/desktop-apply"
EOF
chmod +x "$HOME/.local/bin/desktop-preset"

# ---- 1e. Ensure ~/.local/bin is on $PATH for interactive shells ------------
# 06 puts multiple helpers in ~/.local/bin (desktop-apply, desktop-preset,
# rofi-pubuntu, i3-cheatsheet). Default Termux PATH is just $PREFIX/bin,
# so without this nudge `desktop-apply` fails with "command not found".
# Idempotent: only append the export line if we haven't done it before.
if [ -f "$HOME/.bashrc" ] && ! grep -q 'HOME/.local/bin' "$HOME/.bashrc"; then
    log "[1e/4] appending ~/.local/bin to PATH in ~/.bashrc"
    {
        echo ""
        echo "# Added by 06-deploy-runtime-scripts.sh — picks up desktop-apply, desktop-preset, etc."
        echo 'export PATH="$HOME/.local/bin:$PATH"'
    } >> "$HOME/.bashrc"
fi

# Also source ~/runtime.env from .bashrc so interactive shells get the virgl
# env vars (GALLIUM_DRIVER=virpipe, VTEST_SOCKET_NAME, ...). Without this,
# launching e.g. `firefox &` from a Termux shell would NOT pick up virgl —
# only apps started from i3 (which already sources runtime.env) would.
if [ -f "$HOME/.bashrc" ] && ! grep -q 'source.*runtime.env\|\. .*runtime.env' "$HOME/.bashrc"; then
    log "[1e/4] sourcing ~/runtime.env from ~/.bashrc (so virgl env reaches shells)"
    {
        echo ""
        echo "# Added by 06-deploy-runtime-scripts.sh — picks up virgl env (GALLIUM_DRIVER=virpipe, etc.)"
        echo '[ -f "$HOME/runtime.env" ] && . "$HOME/runtime.env"'
    } >> "$HOME/.bashrc"
fi

# ---- 2. start-x11.sh — fire up the display stack ---------------------------
log "[2/4] writing ~/start-x11.sh"
write_with_backup "$HOME/start-x11.sh" <<'EOF'
#!/data/data/com.termux/files/usr/bin/bash
# Bring up the GUI stack:
#   1. Foreground the Termux:X11 Android app (so the X server has a Surface).
#   2. Set up xauth (cookie generated if missing). Start Termux:X11 with
#      -auth pointing at ~/.Xauthority (or -ac if USE_XAUTH=0).
#   3. Best-effort: deploy the cookie to pubuntu over SSH.
#   4. Start pulseaudio (optional).
#   5. Start a socat direct-X bridge so pubuntu / Alpine clients can hit
#      Termux:X11 over TCP at ~110 MB/s instead of SSH X-forward's ~8 MB/s.
#      Bound ONLY to the AVF TAP interface (not LAN/Tailscale/cellular).
#      See pixel/docs/pixel-desktop-architecture.md "Measured 2026-05-29".
#
# Logs:
#   $PREFIX/tmp/termux-x11.log     X server output
#   $PREFIX/tmp/socat_x11.log      direct-X bridge log
#
# Stop with:  bash ~/stop-x11.sh
set -uo pipefail
source ~/runtime.env
LOG_DIR="${TMPDIR:-/data/data/com.termux/files/usr/tmp}"
mkdir -p "$LOG_DIR"

# 1. foreground the Termux:X11 activity so the X server has a Surface
if command -v am >/dev/null 2>&1; then
    am start --user 0 -n com.termux.x11/.MainActivity >/dev/null 2>&1 || true
fi

# 2. X11 auth setup (idempotent — keeps existing cookie across restarts)
#    USE_XAUTH=1 → run with magic-cookie auth (-auth ~/.Xauthority)
#    USE_XAUTH=0 → run with no auth (-ac); only safe because the direct-X
#                  bridge is bound to AVF TAP and that subnet is your own
#                  VMs only.
XAUTH_FILE="$HOME/.Xauthority"
AVF_TAP_IP=$(ifconfig 2>/dev/null | awk '/^avf_tap/ {found=1; next} found && /inet / {print $2; exit} /^[a-z]/ {found=0}')
if [ "$USE_XAUTH" = "1" ]; then
    # 1. Generate a new cookie if the file is empty or has none
    if [ ! -s "$XAUTH_FILE" ] || ! xauth -f "$XAUTH_FILE" list 2>/dev/null \
            | grep -q "MIT-MAGIC-COOKIE-1"; then
        echo "[start-x11] generating new xauth cookie → $XAUTH_FILE"
        COOKIE=$(openssl rand -hex 16 2>/dev/null || \
                 dd if=/dev/urandom bs=16 count=1 2>/dev/null | xxd -p -c 32)
        rm -f "$XAUTH_FILE"
        touch "$XAUTH_FILE"
        chmod 600 "$XAUTH_FILE"
        xauth -f "$XAUTH_FILE" add ":$DISPLAY_NUM" . "$COOKIE"
    else
        echo "[start-x11] reusing existing xauth cookie in $XAUTH_FILE"
        # Pick up whatever cookie is in the file so we can add missing entries
        COOKIE=$(xauth -f "$XAUTH_FILE" list 2>/dev/null \
                 | grep "MIT-MAGIC-COOKIE-1" | head -1 | awk '{print $3}')
    fi

    # 2. ALWAYS ensure the AVF-TAP-IP entry exists (this is what pubuntu/Alpine
    # use to connect via TCP, and it must share the cookie with :0). The
    # earlier branch only added it on first generation, leaving "I reused the
    # local cookie but never published the network entry" as a silent gap
    # that broke pubuntu auth.
    if [ -n "$AVF_TAP_IP" ] && [ -n "$COOKIE" ]; then
        if ! xauth -f "$XAUTH_FILE" list "$AVF_TAP_IP:$DISPLAY_NUM" 2>/dev/null \
                | grep -q "MIT-MAGIC-COOKIE-1"; then
            echo "[start-x11] adding xauth entry for $AVF_TAP_IP:$DISPLAY_NUM (network access)"
            xauth -f "$XAUTH_FILE" add "$AVF_TAP_IP:$DISPLAY_NUM" . "$COOKIE"
        fi
    fi

    X11_AUTH_FLAGS="-auth $XAUTH_FILE"
else
    X11_AUTH_FLAGS="-ac"
fi

# Start the X server. -listen tcp enables TCP listening on port 6000 so
# pubuntu can connect directly via DISPLAY=<AVF_TAP_IP>:0 with no socat
# bridge needed. The X server's own TCP listener is faster than the
# socat-bridged-to-Unix-socket route AND eliminates a moving part.
# (Earlier today's socat-bridge path relied on Termux:X11 creating a
# filesystem socket at $PREFIX/tmp/.X11-unix/X0; the current Termux:X11
# build only creates an abstract socket, so socat has nothing to bridge.
# Switching to direct TCP listening sidesteps the whole question.)
#
# NOTE: stale-socket auto-cleanup was removed — it was breaking working
# states. If termux-x11 reports "Cannot establish any listening sockets",
# fully kill the Termux:X11 Android app from the phone's recent apps,
# then re-run this script.
if pgrep -f "termux-x11 :$DISPLAY_NUM" >/dev/null 2>&1; then
    echo "[start-x11] termux-x11 process already running on :$DISPLAY_NUM"
else
    echo "[start-x11] starting Termux:X11 on :$DISPLAY_NUM with TCP listening ($X11_AUTH_FLAGS)"
    nohup termux-x11 ":$DISPLAY_NUM" -listen tcp $X11_AUTH_FLAGS \
        >"$LOG_DIR/termux-x11.log" 2>&1 &
    sleep 2
fi

# 3. Sync cookie to pubuntu (best-effort) so the user doesn't have to.
#    Quiet failure if pubuntu's SSH isn't reachable yet.
if [ "$USE_XAUTH" = "1" ] && [ -n "$AVF_TAP_IP" ] \
        && command -v nc >/dev/null 2>&1 && nc -z -w 2 localhost "$PUBUNTU_SSH_PORT" 2>/dev/null; then
    echo "[start-x11] deploying xauth cookie to pubuntu (best-effort)"
    if xauth -f "$XAUTH_FILE" extract - "$AVF_TAP_IP:$DISPLAY_NUM" 2>/dev/null \
            | ssh -p "$PUBUNTU_SSH_PORT" -o BatchMode=yes -o ConnectTimeout=3 \
                  "${PUBUNTU_SSH_USER}@localhost" \
                  "touch ~/.Xauthority; chmod 600 ~/.Xauthority; xauth -f ~/.Xauthority merge -" \
            2>/dev/null; then
        echo "[start-x11]   cookie deployed to pubuntu's ~/.Xauthority"
    else
        echo "[start-x11]   couldn't reach pubuntu over SSH (run ~/sync-x11-cookie.sh manually later)"
    fi
fi

# 4. pulseaudio (best-effort)
if [ "$START_PULSE" = "1" ] && command -v pulseaudio >/dev/null 2>&1; then
    if ! pgrep -x pulseaudio >/dev/null 2>&1; then
        echo "[start-x11] starting pulseaudio"
        pulseaudio --start --exit-idle-time=-1 --load="module-native-protocol-tcp auth-ip-acl=127.0.0.1 auth-anonymous=1" >/dev/null 2>&1 || true
    fi
fi

# 4b. virgl_test_server_android — required for HW-accelerated GL via PowerVR.
# Mesa's virpipe driver (which we export as GALLIUM_DRIVER in runtime.env)
# talks to this daemon over the unix socket; it loads Android's PowerVR
# GLES blob and renders on the GPU. Without the daemon, mesa silently
# falls back to llvmpipe (software). Cheap to leave running; lives until
# the next stop-x11.
if command -v virgl_test_server_android >/dev/null 2>&1; then
    VIRGL_SOCKET="$PREFIX/tmp/virgl_test.sock"
    if ! pgrep -x virgl_test_server_android >/dev/null 2>&1; then
        echo "[start-x11] starting virgl_test_server_android (PowerVR backend for GL clients)"
        # Stale socket from a previous unclean exit will refuse new bindings.
        rm -f "$VIRGL_SOCKET"
        nohup virgl_test_server_android --socket-path "$VIRGL_SOCKET" \
            >"$LOG_DIR/virgl-server.log" 2>&1 &
        sleep 1
    fi
fi

# 5. (no socat bridge needed — Termux:X11 is started with -listen tcp, so it
#     listens directly on port 6000. From pubuntu/Alpine, connect via
#     DISPLAY=<AVF_TAP_IP>:0. The AVF_TAP IP is reachable from VMs inside
#     Podroid but NOT from LAN/Tailscale/cellular, so the exposure scope
#     is the same as the old bind=<AVF_TAP_IP> socat had.)
if [ -n "$AVF_TAP_IP" ]; then
    echo "[start-x11] X server is listening on TCP 6000 (-listen tcp). From pubuntu:"
    echo "[start-x11]   export DISPLAY=$AVF_TAP_IP:0"
fi

# 6. launch i3 window manager (Termux-native — replaces the old proot i3)
if command -v i3 >/dev/null 2>&1 && [ -f "$HOME/.config/i3/config" ]; then
    if pgrep -x i3 >/dev/null 2>&1; then
        echo "[start-x11] i3 already running"
    else
        echo "[start-x11] starting i3 window manager"
        # dbus-launch wraps i3 so GTK/xfce4-terminal etc. get a session bus.
        # If dbus-launch isn't available, fall back to plain i3.
        if command -v dbus-launch >/dev/null 2>&1; then
            DISPLAY=":$DISPLAY_NUM" XAUTHORITY="$XAUTH_FILE" \
                nohup dbus-launch --exit-with-session i3 \
                >>"$LOG_DIR/i3.log" 2>&1 &
        else
            DISPLAY=":$DISPLAY_NUM" XAUTHORITY="$XAUTH_FILE" \
                nohup i3 >>"$LOG_DIR/i3.log" 2>&1 &
        fi
        disown $!
    fi
fi

echo
echo "[start-x11] all started. Switch to the Termux:X11 app on the phone to see"
echo "[start-x11] the i3 desktop. Some keybinds (mod=Ctrl+Alt):"
echo "[start-x11]   Ctrl+Alt+Enter   xfce4-terminal"
echo "[start-x11]   Ctrl+Alt+d       rofi app launcher"
echo "[start-x11]   Ctrl+Alt+/       cheatsheet of all keybinds"
echo "[start-x11]   Ctrl+Alt+Shift+e quit i3"
EOF

# ---- 3. sync-x11-cookie.sh — push Termux's xauth cookie to pubuntu ---------
log "[3/4] writing ~/sync-x11-cookie.sh"
write_with_backup "$HOME/sync-x11-cookie.sh" <<'EOF'
#!/data/data/com.termux/files/usr/bin/bash
# Push Termux's xauth cookie (from ~/.Xauthority) into pubuntu's
# ~/.Xauthority so pubuntu X clients authenticate against Termux:X11
# without -ac being set on the X server.
#
# Run after start-x11.sh has generated a cookie (USE_XAUTH=1). The
# auto-deploy in start-x11.sh tries this on every start; this script
# is for when:
#   - pubuntu wasn't reachable at start-x11 time
#   - you rebuilt pubuntu and need to push the cookie again
#   - you rotated the cookie (rm ~/.Xauthority then re-run start-x11.sh)
#
# Env:
#   PUBUNTU_SSH_HOST     default: localhost  (Podroid forward to pubuntu)
#   PUBUNTU_SSH_PORT     default: 9923
#   PUBUNTU_SSH_USER     default: ryno
#   DISPLAY_NUM          default: 0
set -euo pipefail
source ~/runtime.env
PUBUNTU_SSH_HOST="${PUBUNTU_SSH_HOST:-localhost}"

XAUTH_FILE="$HOME/.Xauthority"
if [ ! -s "$XAUTH_FILE" ]; then
    echo "[sync-x11-cookie] $XAUTH_FILE is empty/missing — run start-x11.sh with USE_XAUTH=1 first" >&2
    exit 1
fi

AVF_TAP_IP=$(ifconfig 2>/dev/null | awk '/^avf_tap/ {found=1; next} found && /inet / {print $2; exit} /^[a-z]/ {found=0}')
if [ -z "$AVF_TAP_IP" ]; then
    echo "[sync-x11-cookie] avf_tap_fixed interface not present — is Podroid running?" >&2
    exit 1
fi

ENTRY="$AVF_TAP_IP:$DISPLAY_NUM"
if ! xauth -f "$XAUTH_FILE" list "$ENTRY" 2>/dev/null | grep -q "MIT-MAGIC-COOKIE-1"; then
    echo "[sync-x11-cookie] no cookie for $ENTRY in $XAUTH_FILE" >&2
    echo "[sync-x11-cookie] start-x11.sh with USE_XAUTH=1 should have created one" >&2
    exit 1
fi

echo "[sync-x11-cookie] pushing $ENTRY cookie → ${PUBUNTU_SSH_USER}@${PUBUNTU_SSH_HOST}:${PUBUNTU_SSH_PORT}"
xauth -f "$XAUTH_FILE" extract - "$ENTRY" \
    | ssh -p "$PUBUNTU_SSH_PORT" -o ConnectTimeout=5 \
          "${PUBUNTU_SSH_USER}@${PUBUNTU_SSH_HOST}" \
          'touch ~/.Xauthority; chmod 600 ~/.Xauthority; xauth -f ~/.Xauthority merge -'
echo "[sync-x11-cookie] done. Verify in pubuntu with:"
echo "    ssh -p $PUBUNTU_SSH_PORT $PUBUNTU_SSH_USER@$PUBUNTU_SSH_HOST 'DISPLAY=$ENTRY xset q' | head -3"
EOF

# ---- 4. stop-x11.sh --------------------------------------------------------
log "[4/4] writing ~/stop-x11.sh"
write_with_backup "$HOME/stop-x11.sh" <<'EOF'
#!/data/data/com.termux/files/usr/bin/bash
# Tear down the GUI session. We DON'T stop the Termux:X11 Android
# activity itself (cheap to leave running, faster restart next time).
set -uo pipefail
source ~/runtime.env

# 1. ask i3 to exit cleanly (gives apps a chance to save state)
if command -v i3-msg >/dev/null 2>&1 && pgrep -x i3 >/dev/null 2>&1; then
    echo "[stop-x11] asking i3 to exit"
    DISPLAY=":$DISPLAY_NUM" i3-msg exit >/dev/null 2>&1 || true
    sleep 1
fi

# 2. stop the direct-X bridge
if pgrep -f "socat TCP-LISTEN:6000" >/dev/null 2>&1; then
    echo "[stop-x11] stopping direct-X bridge (socat on :6000)"
    pkill -f "socat TCP-LISTEN:6000" 2>/dev/null || true
fi

# 3. stop the X server
# IMPORTANT: termux-x11's cmdline is `termux-x11 com.termux.x11 :0 -...`
# (note the package name after the binary name). A pkill -f pattern like
# "termux-x11 :$DISPLAY_NUM" will MISS this because the literal substring
# isn't in the cmdline. Use exact-name match instead (-x) which targets
# the binary name only and doesn't risk self-matching.
echo "[stop-x11] stopping Termux:X11 listener"
pkill -x termux-x11 2>/dev/null || true

# 4. (optional) stop pulseaudio
if [ "$START_PULSE" = "1" ] && pgrep -x pulseaudio >/dev/null 2>&1; then
    pulseaudio -k 2>/dev/null || true
fi

echo "[stop-x11] done."
EOF

# ---- 5. VNC + x2x bridge — second-screen layer (iPad / external monitor) ---
# Architecture: Xvnc runs a second X server at :$VNC_DISPLAY_NUM, sized for
# the remote device. i3 starts inside that session. x2x bridges
# mouse/keyboard from :0 to :$VNC_DISPLAY_NUM — move the cursor past the
# configured edge and the Pixel's input device controls the secondary.
# Pixel display :0 is untouched; this layer is purely additive.
#
# Profiles (~/.config/vnc-profiles/*.env) bundle per-target settings
# (resolution, edge direction, DPI). Switch between them via the
# `vnc-screen` wrapper:
#     vnc-screen ipad         iPad Pro 11" landscape, east edge
#     vnc-screen monitor      FHD windowed on a 4K monitor, north edge
#     vnc-screen none         tear down the VNC layer
#     vnc-screen list         show available profiles

log "[5a/5] writing VNC profiles in ~/.config/vnc-profiles/"
mkdir -p "$HOME/.config/vnc-profiles"

write_with_backup "$HOME/.config/vnc-profiles/ipad.env" <<'EOF'
# iPad Pro 11" landscape secondary — sits east of the Pixel.
VNC_RESOLUTION=2388x1668
X2X_DIRECTION=east
VNC_DPI=196
EOF

write_with_backup "$HOME/.config/vnc-profiles/monitor.env" <<'EOF'
# FHD viewport (1920x1080) — for displaying in a window on a larger
# external monitor (e.g. 4K on a desk). Native 4K is too heavy for
# RFB; 1080p in a window stays smooth and keeps text crisp. North
# edge — cursor moves UP from the Pixel to reach the monitor.
# DPI 72 makes text physically small inside the windowed viewport;
# bump up to 96 if you'd rather have laptop-screen-sized text,
# or 144 for big-desktop-monitor-sized text.
VNC_RESOLUTION=1920x1080
X2X_DIRECTION=north
VNC_DPI=120
EOF

log "[5b/5] writing ~/.local/bin/vnc-screen (profile switcher)"
write_with_backup "$HOME/.local/bin/vnc-screen" <<'EOF'
#!/data/data/com.termux/files/usr/bin/bash
# Switch the second-screen Xvnc to a different profile.
# Stops any running VNC layer first, then re-spawns with the new profile.
# Same-profile re-runs are cheap (stop is idempotent + fast).
set -euo pipefail

PROFILE_DIR="$HOME/.config/vnc-profiles"
CHOICE="${1:-list}"

list_profiles() {
    echo "Available second-screen profiles (in $PROFILE_DIR):"
    local f name desc
    for f in "$PROFILE_DIR"/*.env; do
        [ -e "$f" ] || { echo "  (none — drop a .env file in the dir)"; return; }
        name=$(basename "$f" .env)
        desc=$(head -1 "$f" | sed 's/^# *//')
        printf "  %-15s %s\n" "$name" "$desc"
    done
    echo "  none            tear down everything (no second screen)"
    echo
    echo "Usage:  vnc-screen <name|none|list>"
}

case "$CHOICE" in
    none|stop|off)
        exec bash "$HOME/stop-vnc.sh"
        ;;
    list|-l|--list|-h|--help)
        list_profiles
        exit 0
        ;;
esac

PROFILE_FILE="$PROFILE_DIR/$CHOICE.env"
if [ ! -f "$PROFILE_FILE" ]; then
    echo "[vnc-screen] no profile '$CHOICE' (looked at $PROFILE_FILE)" >&2
    list_profiles >&2
    exit 1
fi

# Clean teardown of any previously-running VNC stack, then start with the
# requested profile. Sleep gives Xvnc's socket a moment to clear so the
# next bind succeeds.
echo "[vnc-screen] switching to profile '$CHOICE'"
bash "$HOME/stop-vnc.sh" >/dev/null 2>&1 || true
sleep 1
exec bash "$HOME/start-vnc.sh" "$CHOICE"
EOF
chmod +x "$HOME/.local/bin/vnc-screen"

log "[5c/5] writing ~/start-vnc.sh, ~/stop-vnc.sh, ~/change-x2x-edge.sh"
write_with_backup "$HOME/start-vnc.sh" <<'EOF'
#!/data/data/com.termux/files/usr/bin/bash
# Bring up the second-screen VNC layer:
#   1. ensure Xvnc :$VNC_DISPLAY_NUM is running (creating password on first run)
#   2. ensure i3 is running inside it
#   3. ensure x2x is bridging input from :$DISPLAY_NUM to :$VNC_DISPLAY_NUM
# Re-runnable safely — each step skips work already done.
#
# Usage:
#   start-vnc.sh                  use runtime.env defaults (iPad-ish)
#   start-vnc.sh <profile>        load ~/.config/vnc-profiles/<profile>.env
#                                 over the defaults (cleaner: use 'vnc-screen')
set -uo pipefail
source ~/runtime.env

# Optional profile override — applies AFTER runtime.env so per-profile
# values (VNC_RESOLUTION, X2X_DIRECTION, VNC_DPI, etc.) take priority. Use
# the 'vnc-screen' wrapper for safe profile-switching with cleanup.
PROFILE="${1:-}"
if [ -n "$PROFILE" ]; then
    PROFILE_FILE="$HOME/.config/vnc-profiles/$PROFILE.env"
    if [ ! -f "$PROFILE_FILE" ]; then
        echo "[start-vnc] no profile '$PROFILE' at $PROFILE_FILE" >&2
        echo "[start-vnc] available profiles:" >&2
        ls -1 "$HOME/.config/vnc-profiles/" 2>/dev/null | sed 's/\.env$//; s/^/  /' >&2
        exit 1
    fi
    . "$PROFILE_FILE"
    echo "[start-vnc] using profile '$PROFILE' from $PROFILE_FILE"
fi

LOG_DIR="${LOG_DIR:-$HOME/.cache/x11-logs}"
PASSWD_FILE="${VNC_PASSWORD_FILE:-$HOME/.vnc/passwd}"
mkdir -p "$LOG_DIR" "$(dirname "$PASSWD_FILE")"

# --- 1. password file ------------------------------------------------------
if [ ! -f "$PASSWD_FILE" ]; then
    # VNC's wire protocol caps the password at 8 chars — anything longer is
    # silently truncated on the client, so we generate exactly 8.
    PW=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c8)
    printf '%s\n%s\n' "$PW" "$PW" | vncpasswd "$PASSWD_FILE" >/dev/null 2>&1 \
        || { echo "[start-vnc] vncpasswd failed" >&2; exit 1; }
    chmod 600 "$PASSWD_FILE"
    echo "[start-vnc] generated NEW VNC password: $PW"
    echo "[start-vnc]   (stored hashed in $PASSWD_FILE — keep this somewhere safe)"
    echo
fi

# --- 2. bind interface -----------------------------------------------------
case "$VNC_BIND" in
    tailscale)
        # Two paths to find the tailnet IP:
        #   (a) tailscale CLI (Termux 'tailscale' package; needs 'tailscale up')
        #   (b) ifconfig scan for tun*/tailscale* interface — covers the
        #       Android Tailscale app case where the VPN runs at the OS level
        #       and Termux only sees the resulting tun0 interface.
        BIND_IP=$(tailscale ip -4 2>/dev/null | head -1)
        if [ -z "$BIND_IP" ]; then
            BIND_IP=$(ifconfig 2>/dev/null | awk '
                /^(tun|tailscale)/ {iface=$1; found=1; next}
                found && /inet / {print $2; exit}
                /^[a-z]/ {found=0}
            ')
        fi
        if [ -z "$BIND_IP" ]; then
            echo "[start-vnc] ERROR: VNC_BIND=tailscale but no tailnet IP found." >&2
            echo "[start-vnc]   Tried: 'tailscale ip -4' (no CLI?) and 'ifconfig' for tun*/tailscale*." >&2
            echo "[start-vnc]   Bring up tailscale first (Android app or 'tailscale up' in Termux)," >&2
            echo "[start-vnc]   or set VNC_BIND=localhost / all in ~/runtime.env." >&2
            exit 1
        fi
        LISTEN_ARGS=(-interface "$BIND_IP")
        echo "[start-vnc] binding Xvnc to tailscale IP $BIND_IP:$VNC_PORT"
        ;;
    localhost)
        LISTEN_ARGS=(-interface 127.0.0.1)
        echo "[start-vnc] binding Xvnc to 127.0.0.1:$VNC_PORT (ssh tunnel only)"
        ;;
    all)
        LISTEN_ARGS=()
        echo "[start-vnc] binding Xvnc to ALL interfaces on :$VNC_PORT (less safe)"
        ;;
    *)
        echo "[start-vnc] unknown VNC_BIND='$VNC_BIND'" >&2; exit 1 ;;
esac

# --- 3. Xvnc ---------------------------------------------------------------
# pgrep matches the X-server *binary* exactly. Two X servers can both be
# called 'Xvnc' if the user starts more than one — we add the display
# argument to the match to be precise. Cmdline format is:
#     Xvnc :1 -geometry ... (Xvnc puts args on cmdline)
if pgrep -f "Xvnc :$VNC_DISPLAY_NUM" >/dev/null 2>&1; then
    echo "[start-vnc] Xvnc already running on :$VNC_DISPLAY_NUM"
else
    echo "[start-vnc] starting Xvnc :$VNC_DISPLAY_NUM (geometry=$VNC_RESOLUTION, port=$VNC_PORT)"
    # -SecurityTypes VncAuth — VNC's traditional DES-hash password auth (good
    #   enough when paired with tailscale; for stronger crypto wrap an SSH
    #   tunnel and set VNC_BIND=localhost instead).
    # -depth 24 — 24-bit colour; lower depths save bandwidth at the cost of
    #   gradient banding.
    # -dpi $VNC_DPI — applies to fontconfig + Xft via the X server's RESOURCE
    #   atom; i3/rofi/GTK clients honour it on connect.
    nohup Xvnc ":$VNC_DISPLAY_NUM" \
        -geometry "$VNC_RESOLUTION" \
        -depth 24 \
        -dpi "$VNC_DPI" \
        -rfbport "$VNC_PORT" \
        -SecurityTypes VncAuth \
        -PasswordFile "$PASSWD_FILE" \
        "${LISTEN_ARGS[@]}" \
        >"$LOG_DIR/xvnc.log" 2>&1 &
    # Give the server ~2s to bind and write to the log before we look for it.
    sleep 2
    if ! pgrep -f "Xvnc :$VNC_DISPLAY_NUM" >/dev/null 2>&1; then
        echo "[start-vnc] Xvnc failed to start — see $LOG_DIR/xvnc.log" >&2
        tail -5 "$LOG_DIR/xvnc.log" >&2
        exit 1
    fi
fi

# --- 4. xauth cookie for :$VNC_DISPLAY_NUM ---------------------------------
# x2x (and any local X client) needs MIT-MAGIC-COOKIE-1 to talk to :1's unix
# socket. Xvnc's VncAuth gate only protects the RFB port (network); the local
# X protocol still uses the standard cookie.
if [ "${USE_XAUTH:-1}" = "1" ]; then
    XAUTH_FILE="$HOME/.Xauthority"
    if ! xauth -f "$XAUTH_FILE" list ":$VNC_DISPLAY_NUM" 2>/dev/null \
            | grep -q "MIT-MAGIC-COOKIE-1"; then
        echo "[start-vnc] adding xauth cookie for :$VNC_DISPLAY_NUM"
        COOKIE=$(mcookie 2>/dev/null || head -c16 /dev/urandom | xxd -p -c32)
        xauth -f "$XAUTH_FILE" add ":$VNC_DISPLAY_NUM" . "$COOKIE"
    fi
fi

# --- 4b. per-display Xft.dpi via xrdb -------------------------------------
# X server's `-dpi N` only reports a number; what actually scales Pango/GTK
# (i3bar, rofi, xfce4-terminal, etc.) is the Xft.dpi resource. xrdb stores
# resources per-display so we can set a different DPI on :1 than on :0
# without touching ~/.Xresources (which desktop-apply manages for :0).
#
# This is what makes the profile's VNC_DPI actually take effect on apps
# running in the VNC session.
echo "[start-vnc] setting Xft.dpi=$VNC_DPI on :$VNC_DISPLAY_NUM (per-display)"
echo "Xft.dpi: $VNC_DPI" | DISPLAY=":$VNC_DISPLAY_NUM" XAUTHORITY="$HOME/.Xauthority" \
    xrdb -merge

# --- 5. i3 inside the VNC session ------------------------------------------
# We track the i3-on-:$VNC_DISPLAY_NUM PID separately from the regular i3
# pidfile so stop-vnc.sh doesn't accidentally kill the Pixel-display i3.
I3_PIDFILE="$LOG_DIR/i3-vnc.pid"
if [ -f "$I3_PIDFILE" ] && kill -0 "$(cat "$I3_PIDFILE")" 2>/dev/null; then
    echo "[start-vnc] i3 already running on :$VNC_DISPLAY_NUM (pid $(cat "$I3_PIDFILE"))"
else
    echo "[start-vnc] starting i3 on :$VNC_DISPLAY_NUM"
    DISPLAY=":$VNC_DISPLAY_NUM" XAUTHORITY="$HOME/.Xauthority" \
        nohup i3 >"$LOG_DIR/i3-vnc.log" 2>&1 &
    echo $! > "$I3_PIDFILE"
    sleep 1
fi

# --- 6. x2x bridge :0 → :$VNC_DISPLAY_NUM ---------------------------------
# x2x runs on the :0 side (its -from), reads pointer/keyboard events, and
# replays them on :$VNC_DISPLAY_NUM (its -to) when the cursor crosses the
# configured edge.
X2X_PIDFILE="$LOG_DIR/x2x.pid"
if [ -f "$X2X_PIDFILE" ] && kill -0 "$(cat "$X2X_PIDFILE")" 2>/dev/null; then
    echo "[start-vnc] x2x bridge already running (pid $(cat "$X2X_PIDFILE"))"
else
    case "$X2X_DIRECTION" in
        east|west|north|south) DIR_FLAG="-$X2X_DIRECTION" ;;
        *) echo "[start-vnc] unknown X2X_DIRECTION='$X2X_DIRECTION'" >&2; exit 1 ;;
    esac
    echo "[start-vnc] starting x2x bridge :$DISPLAY_NUM → :$VNC_DISPLAY_NUM ($DIR_FLAG)"
    DISPLAY=":$DISPLAY_NUM" XAUTHORITY="$HOME/.Xauthority" \
        nohup x2x -from ":$DISPLAY_NUM" -to ":$VNC_DISPLAY_NUM" "$DIR_FLAG" \
        >"$LOG_DIR/x2x.log" 2>&1 &
    echo $! > "$X2X_PIDFILE"
fi

echo
echo "[start-vnc] all up. Connect the iPad to: $BIND_IP:$VNC_PORT (display :$VNC_DISPLAY_NUM)"
echo "[start-vnc]   - in VNC client: server = $BIND_IP, port = $VNC_PORT"
echo "[start-vnc]   - password: in $PASSWD_FILE (regenerate via 'rm $PASSWD_FILE && bash ~/start-vnc.sh')"
echo "[start-vnc]   - cursor crosses $X2X_DIRECTION edge of Pixel screen to reach iPad"
EOF

write_with_backup "$HOME/stop-vnc.sh" <<'EOF'
#!/data/data/com.termux/files/usr/bin/bash
# Tear down the VNC layer (Xvnc + its i3 + x2x). Leaves Pixel :0 untouched.
set -uo pipefail
source ~/runtime.env

LOG_DIR="${LOG_DIR:-$HOME/.cache/x11-logs}"

# Stop x2x FIRST — otherwise a still-running bridge will try to reconnect
# to Xvnc as we shut it down and emit confusing errors.
if [ -f "$LOG_DIR/x2x.pid" ]; then
    PID=$(cat "$LOG_DIR/x2x.pid")
    if kill -0 "$PID" 2>/dev/null; then
        echo "[stop-vnc] stopping x2x (pid $PID)"
        kill "$PID" 2>/dev/null
    fi
    rm -f "$LOG_DIR/x2x.pid"
fi

# i3 on :$VNC_DISPLAY_NUM
if [ -f "$LOG_DIR/i3-vnc.pid" ]; then
    PID=$(cat "$LOG_DIR/i3-vnc.pid")
    if kill -0 "$PID" 2>/dev/null; then
        echo "[stop-vnc] stopping i3-on-:$VNC_DISPLAY_NUM (pid $PID)"
        kill "$PID" 2>/dev/null
        sleep 1
    fi
    rm -f "$LOG_DIR/i3-vnc.pid"
fi

# Xvnc itself. -f because the binary name 'Xvnc' is generic, plus the
# display argument to make sure we don't kill some other Xvnc.
if pgrep -f "Xvnc :$VNC_DISPLAY_NUM" >/dev/null 2>&1; then
    echo "[stop-vnc] stopping Xvnc :$VNC_DISPLAY_NUM"
    pkill -f "Xvnc :$VNC_DISPLAY_NUM" 2>/dev/null
fi

# Clean stale unix socket — Xvnc usually does this on its own but can leave
# it behind on a hard kill, blocking the next start.
rm -f "$PREFIX/tmp/.X11-unix/X$VNC_DISPLAY_NUM" 2>/dev/null
rm -f "/tmp/.X11-unix/X$VNC_DISPLAY_NUM" 2>/dev/null

echo "[stop-vnc] done."
EOF

write_with_backup "$HOME/change-x2x-edge.sh" <<'EOF'
#!/data/data/com.termux/files/usr/bin/bash
# Restart only the x2x bridge with a new direction, without disrupting either
# X session or the iPad VNC connection. Cheap to call repeatedly while you
# decide which edge feels right.
#
# Usage: change-x2x-edge.sh east|west|north|south
set -euo pipefail

NEW_DIR="${1:?usage: change-x2x-edge.sh <east|west|north|south>}"
case "$NEW_DIR" in
    east|west|north|south) ;;
    *) echo "bad direction: $NEW_DIR (use east|west|north|south)" >&2; exit 1 ;;
esac

source ~/runtime.env
LOG_DIR="${LOG_DIR:-$HOME/.cache/x11-logs}"

# Persist for next start-vnc.sh.
if grep -q '^export X2X_DIRECTION=' ~/runtime.env; then
    sed -i "s|^export X2X_DIRECTION=.*|export X2X_DIRECTION=\"$NEW_DIR\"|" ~/runtime.env
fi

# Kill the running x2x.
if [ -f "$LOG_DIR/x2x.pid" ]; then
    PID=$(cat "$LOG_DIR/x2x.pid")
    if kill -0 "$PID" 2>/dev/null; then
        kill "$PID" 2>/dev/null
    fi
    rm -f "$LOG_DIR/x2x.pid"
fi

# Start it again with the new direction.
DISPLAY=":$DISPLAY_NUM" XAUTHORITY="$HOME/.Xauthority" \
    nohup x2x -from ":$DISPLAY_NUM" -to ":$VNC_DISPLAY_NUM" "-$NEW_DIR" \
    >"$LOG_DIR/x2x.log" 2>&1 &
echo $! > "$LOG_DIR/x2x.pid"
echo "[change-x2x-edge] x2x now bridging :$DISPLAY_NUM → :$VNC_DISPLAY_NUM via -$NEW_DIR"
EOF

# Sync the four downstream configs to whatever's currently in
# desktop-look.env. On a fresh deploy, look-env mirrors the I3_DPI / I3_FONT
# defaults and this is a no-op. After a user has tweaked look-env, this is
# where their settings overlay 06's static heredoc values.
if [ -x "$HOME/.local/bin/desktop-apply" ]; then
    log ""
    log "running desktop-apply to sync look from \$HOME/.config/desktop-look.env"
    "$HOME/.local/bin/desktop-apply" || warn "desktop-apply failed (continuing)"
fi

log ""
log "Deployed runtime scripts to \$HOME:"
log "    ~/start-x11.sh                 bring up Termux:X11 + xauth + cookie + bridge + i3"
log "    ~/stop-x11.sh                  tear down i3 + display stack"
log "    ~/sync-x11-cookie.sh           (re)deploy xauth cookie to pubuntu"
log "    ~/runtime.env                  shared config (DISPLAY_NUM, USE_XAUTH, I3_MOD, ...)"
log "    ~/.config/i3/config            i3 keybinds + workspaces (mod=$I3_MOD)"
log "    ~/.local/bin/i3-cheatsheet     \$mod+slash popup of all keybinds"
log "    ~/.config/xfce4/terminal/      no-Alt-menu terminal defaults"
log "    ~/.config/rofi/config.rasi     rofi launcher theme + combi mode"
log "    ~/.local/share/applications/   pubuntu launcher .desktop entries"
log "    ~/.local/bin/rofi-pubuntu      rofi script-mode for running commands in pubuntu"
log "    ~/.config/pubuntu-commands.txt suggestions for the pubuntu mode (user-editable)"
log "    ~/.config/desktop-look.env     **single source of truth** for DPI/font/gaps/palette — edit this!"
log "    ~/.local/bin/desktop-apply     sync look-env → .Xresources, rofi, i3, xfce4-terminal (live)"
log "    ~/.config/desktop-presets/     pre-canned looks (native, vnc-tablet, vnc-desktop)"
log "    ~/.local/bin/desktop-preset    swap to a preset wholesale: 'desktop-preset vnc-tablet'"
log "    vnc-screen NAME                switch second-screen profile (ipad|monitor|none|list)"
log "    ~/.config/vnc-profiles/        per-target profiles (ipad.env, monitor.env, ...)"
log "    ~/start-vnc.sh [profile]       bring up Xvnc + x2x; vnc-screen is the friendlier UI"
log "    ~/stop-vnc.sh                  tear down VNC layer (leaves Pixel :0 untouched)"
log "    ~/change-x2x-edge.sh DIR       restart x2x with a new edge (east|west|north|south)"
log ""
log "First-time GUI run:"
log "    bash ~/start-x11.sh"
log "    # then open the Termux:X11 Android app to see the display"
log "    # launch apps from a Termux shell or via ssh into pubuntu"
log ""
log "First-time iPad second-screen run (requires tailscale up):"
log "    bash ~/start-vnc.sh"
log "    # then in the iPad VNC client, connect to: <pixel-tailscale-ip>:$VNC_PORT"
log "    # the password is printed on first run (regenerate via 'rm ~/.vnc/passwd')"
log ""
log "Useful Termux-X11 app settings (top-left hamburger menu):"
log "    - 'Show additional keys'     keyboard helper bar (Tab, Ctrl, Esc, …)"
log "    - 'Force fullscreen'         hides the Android nav bar"
log "    - 'Pointer capture'          relative mouse for X (gaming/CAD)"
log ""
log "Old proot-based ~/proot.env, ~/start-proot.sh from earlier deploys are"
log "obsolete — safe to delete manually."
