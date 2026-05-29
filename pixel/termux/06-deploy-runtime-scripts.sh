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
#   I3_FONT          default: DejaVu Sans Mono 10

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

TERMUX_PKGS="termux-x11-nightly mesa vulkan-loader-android mesa-vulkan-icd-swrast virglrenderer-android xorg-xrandr socat xorg-xauth"
# Window manager + GUI toolkit (Termux-native, replaces the old proot-i3 desktop)
TERMUX_PKGS="$TERMUX_PKGS i3 i3status rofi xfce4-terminal dbus"
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
    [ -f "$path" ] && cp "$path" "$path.bak"
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
EOF

# ---- 1b. i3 config + cheatsheet + xfce4-terminal config -------------------
# Same keybinds and layout we had in the proot-Ubuntu setup, now installed in
# Termux's own $HOME. Re-runs idempotent — each file gets a .bak copy.
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
bindsym \$mod+d      exec rofi -show drun

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
exec --no-startup-id xset s off
exec --no-startup-id xset -dpms
exec --no-startup-id dbus-update-activation-environment --systemd DISPLAY XAUTHORITY 2>/dev/null || true
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

log "[1b/4] writing ~/.config/xfce4/terminal/terminalrc"
mkdir -p "$HOME/.config/xfce4/terminal"
write_with_backup "$HOME/.config/xfce4/terminal/terminalrc" <<'EOF'
[Configuration]
# Stop Alt+letter from triggering the menu bar (which would eat Alt+T → tmux
# prefix, etc.). Also hide the menu bar by default — right-click → "Show
# Menubar" to bring it back temporarily.
MiscMenubarDefault=FALSE
ShortcutsNoMnemonics=TRUE
ShortcutsNoMenukey=FALSE
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
write_with_backup "$HOME/.config/rofi/config.rasi" <<'EOF'
configuration {
    modi:        "drun,run,window,docker:~/.local/bin/rofi-pubuntu-docker";
    combi-modi:  "drun,window,docker:~/.local/bin/rofi-pubuntu-docker";
    show-icons:   true;
    icon-theme:  "Adwaita";
    display-drun:   " Apps";
    display-run:    " Run";
    display-window: " Windows";
    display-docker: "🐳 Docker (pubuntu)";
    display-combi:  " All";
    /* On-screen-keyboard users often miss arrows — Tab cycles too. */
    kb-row-down:    "Down,Control+j,Control+n,Tab";
    kb-row-up:      "Up,Control+k,Control+p,ISO_Left_Tab";
}

/* Pick a built-in theme. List with `ls $PREFIX/share/rofi/themes/` and
 * substitute below, or run `rofi-theme-selector` to browse interactively. */
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

log "[1c/4] writing ~/.local/bin/rofi-pubuntu-docker (custom rofi mode)"
mkdir -p "$HOME/.local/bin"
write_with_backup "$HOME/.local/bin/rofi-pubuntu-docker" <<EOF
#!/data/data/com.termux/files/usr/bin/bash
# rofi script-mode for pubuntu Docker.
# - Called with no args: emit one menu entry per running container.
# - Called with a selected entry as \$1: open a shell into that container
#   via an xfce4-terminal popup.
set -uo pipefail
SSH_TARGET="${PUBUNTU_SSH_USER}@localhost"
SSH_PORT=${PUBUNTU_SSH_PORT}

if [ -z "\${1:-}" ]; then
    # List running containers (name + image)
    ssh -p "\$SSH_PORT" -o ConnectTimeout=3 "\$SSH_TARGET" \\
        'docker ps --format "{{.Names}} ({{.Image}})"' 2>/dev/null
else
    # User picked one — open a shell. xfce4-terminal so it has a proper TTY.
    NAME=\$(echo "\$1" | awk '{print \$1}')
    if [ -n "\$NAME" ]; then
        xfce4-terminal -T "docker: \$NAME" -e \\
            "ssh -t -p \$SSH_PORT \$SSH_TARGET 'docker exec -it \$NAME bash'" &
        disown
    fi
fi
EOF
chmod +x "$HOME/.local/bin/rofi-pubuntu-docker"

# Add a $mod+Tab keybind to the i3 config for the combi mode (full launcher).
# Append rather than rewriting so any custom edits the user makes survive.
if ! grep -q "rofi -show combi" "$HOME/.config/i3/config"; then
    cat >> "$HOME/.config/i3/config" <<'EOF'

# Combi launcher (apps + windows + pubuntu docker) — added by 06.
bindsym $mod+Tab exec --no-startup-id rofi -show combi
EOF
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
    if [ ! -s "$XAUTH_FILE" ] || ! xauth -f "$XAUTH_FILE" list 2>/dev/null \
            | grep -q "MIT-MAGIC-COOKIE-1"; then
        echo "[start-x11] generating new xauth cookie → $XAUTH_FILE"
        COOKIE=$(openssl rand -hex 16 2>/dev/null || \
                 dd if=/dev/urandom bs=16 count=1 2>/dev/null | xxd -p -c 32)
        rm -f "$XAUTH_FILE"
        touch "$XAUTH_FILE"
        chmod 600 "$XAUTH_FILE"
        # Add an entry per address the X server can be reached at:
        # - local Unix socket (Termux processes)
        # - AVF TAP IP (pubuntu/Alpine connecting via socat)
        xauth -f "$XAUTH_FILE" add ":$DISPLAY_NUM"          . "$COOKIE"
        if [ -n "$AVF_TAP_IP" ]; then
            xauth -f "$XAUTH_FILE" add "$AVF_TAP_IP:$DISPLAY_NUM" . "$COOKIE"
        fi
    else
        echo "[start-x11] reusing existing xauth cookie in $XAUTH_FILE"
    fi
    X11_AUTH_FLAGS="-auth $XAUTH_FILE"
else
    X11_AUTH_FLAGS="-ac"
fi

# Start the X server (clean any stale socket first — Termux:X11 doesn't tidy
# up its Unix socket when killed by Android, so a re-run after Android killed
# the previous server fails with "Cannot establish any listening sockets". The
# stale lock/socket needs removing before the new server can bind.)
X_SOCK_FILE="$PREFIX/tmp/.X11-unix/X${DISPLAY_NUM}"
X_LOCK_FILE="$PREFIX/tmp/.X${DISPLAY_NUM}-lock"
if pgrep -f "termux-x11 :$DISPLAY_NUM" >/dev/null 2>&1; then
    echo "[start-x11] X server already running on :$DISPLAY_NUM"
else
    # No process — purge any stale socket / lock from a prior session
    [ -e "$X_SOCK_FILE" ] && { echo "[start-x11] removing stale $X_SOCK_FILE"; rm -f "$X_SOCK_FILE"; }
    [ -e "$X_LOCK_FILE" ] && { echo "[start-x11] removing stale $X_LOCK_FILE"; rm -f "$X_LOCK_FILE"; }
    echo "[start-x11] starting Termux:X11 on :$DISPLAY_NUM ($X11_AUTH_FLAGS)"
    nohup termux-x11 ":$DISPLAY_NUM" $X11_AUTH_FLAGS \
        >"$LOG_DIR/termux-x11.log" 2>&1 &
    sleep 1
    # Verify it actually came up — termux-x11 exits silently on socket
    # binding failure, so check by looking for the listening process.
    if ! pgrep -f "termux-x11 :$DISPLAY_NUM" >/dev/null 2>&1; then
        echo "[start-x11] WARNING: termux-x11 didn't start. Check $LOG_DIR/termux-x11.log"
        tail -5 "$LOG_DIR/termux-x11.log" 2>/dev/null | sed 's/^/[start-x11]   /'
    fi
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

# 5. direct-X-over-TCP bridge (for pubuntu / Alpine to bypass slow ssh -Y)
# Only useful when Podroid AVF VM is up (so the avf_tap_fixed interface exists).
# Bind specifically to that interface so the port is reachable from inside
# the VM only — NOT from LAN, Tailscale, cellular, or other Android apps.
X_SOCK="$PREFIX/tmp/.X11-unix/X${DISPLAY_NUM}"
if [ -n "$AVF_TAP_IP" ] && [ -S "$X_SOCK" ] && command -v socat >/dev/null 2>&1; then
    if pgrep -f "socat TCP-LISTEN:6000" >/dev/null 2>&1; then
        echo "[start-x11] direct-X bridge already running on $AVF_TAP_IP:6000"
    else
        echo "[start-x11] starting direct-X bridge on $AVF_TAP_IP:6000 → $X_SOCK"
        nohup socat TCP-LISTEN:6000,fork,reuseaddr,bind=$AVF_TAP_IP \
                    UNIX-CONNECT:$X_SOCK \
            </dev/null >>"$LOG_DIR/socat_x11.log" 2>&1 &
        disown $!
        echo "[start-x11]   from pubuntu/Alpine, set:  export DISPLAY=$AVF_TAP_IP:0"
    fi
elif [ -z "$AVF_TAP_IP" ]; then
    echo "[start-x11] no avf_tap_fixed interface (Podroid VM not running) — skipping direct-X bridge"
elif ! command -v socat >/dev/null 2>&1; then
    echo "[start-x11] socat not installed — skipping direct-X bridge ('pkg install socat' to enable)"
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
echo "[stop-x11] stopping Termux:X11 listener on :$DISPLAY_NUM"
pkill -f "termux-x11 :$DISPLAY_NUM" 2>/dev/null || true

# 4. (optional) stop pulseaudio
if [ "$START_PULSE" = "1" ] && pgrep -x pulseaudio >/dev/null 2>&1; then
    pulseaudio -k 2>/dev/null || true
fi

echo "[stop-x11] done."
EOF

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
log "    ~/.local/bin/rofi-pubuntu-docker  rofi script-mode for docker ps in pubuntu"
log ""
log "First-time GUI run:"
log "    bash ~/start-x11.sh"
log "    # then open the Termux:X11 Android app to see the display"
log "    # launch apps from a Termux shell or via ssh into pubuntu"
log ""
log "Useful Termux-X11 app settings (top-left hamburger menu):"
log "    - 'Show additional keys'     keyboard helper bar (Tab, Ctrl, Esc, …)"
log "    - 'Force fullscreen'         hides the Android nav bar"
log "    - 'Pointer capture'          relative mouse for X (gaming/CAD)"
log ""
log "Old proot-based ~/proot.env, ~/start-proot.sh from earlier deploys are"
log "obsolete — safe to delete manually."
