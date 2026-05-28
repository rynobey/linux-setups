#!/data/data/com.termux/files/usr/bin/bash
# Inside the proot Ubuntu rootfs created by 04-install-proot-ubuntu.sh,
# install i3 (tiling WM) + a minimal desktop toolkit, configure i3, and
# drop a starter ~/.xinitrc / ~/.bashrc for the proot user.
#
# Idempotent. Re-running upgrades packages + overwrites configs in
# /home/<user>/.config/i3/config (keeps the previous one as .bak).
#
# Env overrides (must match what 04 used):
#   PROOT_DISTRO    default: ubuntu
#   PROOT_USER      default: ryno
#   I3_MOD          default: Ctrl+Mod1    (Ctrl+Alt — works on every keyboard
#                                          and doesn't collide with bare-Alt
#                                          shortcuts inside terminal apps.
#                                          Use 'Mod4' if you have a Super
#                                          key and prefer the canonical i3
#                                          default. 'Mod1' = Alt-only is
#                                          dangerous if your apps use Alt+letter.)
#   I3_FLOAT_MOD    default: Mod4         (mouse-drag-to-move floating windows;
#                                          must be a single modifier, not a combo.
#                                          Mod4 is inert on keyboards without
#                                          Super — that's fine, mouse-drag won't
#                                          activate, no collision risk.)
#   I3_FONT         default: "DejaVu Sans Mono 10"
#   INSTALL_FIREFOX default: 1            set 0 to skip Firefox (50 MB)

set -euo pipefail

PROOT_DISTRO="${PROOT_DISTRO:-ubuntu}"
PROOT_USER="${PROOT_USER:-ryno}"
I3_MOD="${I3_MOD:-Ctrl+Mod1}"
I3_FLOAT_MOD="${I3_FLOAT_MOD:-Mod4}"
I3_FONT="${I3_FONT:-DejaVu Sans Mono 10}"
INSTALL_FIREFOX="${INSTALL_FIREFOX:-1}"

log()  { printf '\033[1;34m[bootstrap-desktop]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; }

if ! command -v proot-distro >/dev/null 2>&1; then
    err "proot-distro not found — run 04-install-proot-ubuntu.sh first"
    exit 1
fi
# Check the actual rootfs path (v4: installed-rootfs/<name>/, v5+: containers/<name>/rootfs/).
# `proot-distro list`'s output format varies across versions, so don't rely on parsing it.
ROOTFS_BASH=""
for candidate in \
    "$PREFIX/var/lib/proot-distro/containers/$PROOT_DISTRO/rootfs/usr/bin/bash" \
    "$PREFIX/var/lib/proot-distro/installed-rootfs/$PROOT_DISTRO/usr/bin/bash"; do
    if [ -x "$candidate" ]; then ROOTFS_BASH="$candidate"; break; fi
done
if [ -z "$ROOTFS_BASH" ]; then
    err "$PROOT_DISTRO rootfs not found at either:"
    err "    $PREFIX/var/lib/proot-distro/containers/$PROOT_DISTRO/rootfs/      (v5+)"
    err "    $PREFIX/var/lib/proot-distro/installed-rootfs/$PROOT_DISTRO/        (v4)"
    err "  run 04-install-proot-ubuntu.sh first"
    exit 1
fi

# ---- 1. apt install -------------------------------------------------------
log "[1/4] installing i3 + desktop toolkit inside $PROOT_DISTRO (this is the big step)"
proot-distro login "$PROOT_DISTRO" -- bash <<'BOOTSTRAP'
set -e
export DEBIAN_FRONTEND=noninteractive

apt-get update

# Core tiling-WM stack + practical utilities
apt-get install -y --no-install-recommends \
    i3 i3status i3blocks \
    dmenu rofi \
    xfce4-terminal \
    xterm \
    feh \
    xclip xsel \
    fonts-dejavu fonts-noto-core fonts-firacode \
    dbus-x11 \
    libnotify-bin \
    xdg-utils \
    x11-xserver-utils \
    x11-utils

# Mesa + Vulkan tools (software path on PowerVR for now; will pick up
# hardware via Vortek bridge if that ever lands)
apt-get install -y --no-install-recommends \
    mesa-utils vulkan-tools libgl1-mesa-dri libegl-mesa0

# CLI essentials so the proot env is actually usable
apt-get install -y --no-install-recommends \
    git vim htop curl wget less tmux \
    python3 python3-pip \
    build-essential \
    ca-certificates

apt-get clean

# Initialize /etc/machine-id — proot-distro doesn't run systemd-machine-id-setup
# during bootstrap, so dbus-launch chokes on empty ID at first GUI session.
# Idempotent: dbus-uuidgen --ensure only writes if missing/empty.
rm -f /var/lib/dbus/machine-id
dbus-uuidgen --ensure=/etc/machine-id
ln -sf /etc/machine-id /var/lib/dbus/machine-id
BOOTSTRAP

# ---- 2. Firefox (optional, separate because it's big) ---------------------
if [ "$INSTALL_FIREFOX" = "1" ]; then
    log "[2/4] installing Firefox"
    proot-distro login "$PROOT_DISTRO" -- bash <<'FIREFOX'
set -e
export DEBIAN_FRONTEND=noninteractive
# On Ubuntu 24.04 the 'firefox' apt package is a stub that pulls snap.
# Use the official Mozilla .deb repo so we get a real .deb, no snap.
if [ ! -f /etc/apt/sources.list.d/mozilla.sources ]; then
    install -d /etc/apt/keyrings
    curl -fsSL https://packages.mozilla.org/apt/repo-signing-key.gpg \
        -o /etc/apt/keyrings/packages.mozilla.org.gpg.asc
    cat > /etc/apt/sources.list.d/mozilla.sources <<EOF
Types: deb
URIs: https://packages.mozilla.org/apt
Suites: mozilla
Components: main
Signed-By: /etc/apt/keyrings/packages.mozilla.org.gpg.asc
EOF
    cat > /etc/apt/preferences.d/mozilla <<EOF
Package: *
Pin: origin packages.mozilla.org
Pin-Priority: 1000
EOF
    apt-get update
fi
apt-get install -y --no-install-recommends firefox
apt-get clean
FIREFOX
else
    log "[2/4] skipping Firefox (INSTALL_FIREFOX=0)"
fi

# ---- 3. i3 config for the user --------------------------------------------
log "[3/4] writing i3 config for user '$PROOT_USER'"
# The substitutions happen in Termux side, then we pipe into proot.
I3_CONFIG=$(cat <<EOF
# i3 config — Pixel 10 + Termux:X11 + proot Ubuntu
# Modifier: $I3_MOD (default Ctrl+Mod1 = Ctrl+Alt; override with I3_MOD env var.
#                    Ctrl+Alt was chosen because Termux:X11 + on-screen / external
#                    keyboards often lack a usable Super key, and bare Alt
#                    collides with terminal-app shortcuts. Ctrl+Alt+letter is
#                    safe across most other apps.)
#
# Cheat sheet (with \$mod = Ctrl+Alt):
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

# Use Mouse+<floating_modifier> to drag floating windows (single-modifier only;
# can't be the same compound-modifier as \$mod when \$mod is e.g. Ctrl+Mod1).
floating_modifier $I3_FLOAT_MOD

# Disable XKB's Ctrl+Alt+F1..F12 → XF86Switch_VT_* grab so those keysyms reach
# i3 unchanged. Without this, any \$mod=Ctrl+Alt user can't bind F-keys (they
# get rewritten to XF86Switch_VT_N at the X server layer). exec_always re-runs
# on i3 reload, so a wrong layout / Termux:X11 restart heals itself.
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

# Workspaces (named)
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

# Cheatsheet — pop the keybindings in a floating terminal. Bound to mod+slash
# (Ctrl+Alt+/) because Termux:X11's XKB keymap rewrites Ctrl+Alt+F1..F12 to
# XF86Switch_VT_* regardless of srvrkeys:none, making F-keys unusable as i3
# bindings when \$mod includes Ctrl+Alt. The actual command is in a wrapper
# script (see below — generated alongside this config); i3's exec parser
# struggles with nested quotes + line-continuation, so keep the bindsym tiny.
bindsym \$mod+slash exec --no-startup-id ~/.local/bin/i3-cheatsheet
for_window [title="i3 cheatsheet"] floating enable, resize set width 800 px height 600 px

# Resize mode (presets: small/medium/large via shift, plus hjkl nudge)
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
# Make dialogs and the rofi launcher float
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
)

proot-distro login "$PROOT_DISTRO" --user "$PROOT_USER" -- bash <<EOF
set -e
mkdir -p ~/.config/i3
if [ -f ~/.config/i3/config ]; then cp ~/.config/i3/config ~/.config/i3/config.bak; fi
cat > ~/.config/i3/config <<'CFG_EOF'
$I3_CONFIG
CFG_EOF
chmod 644 ~/.config/i3/config
echo "    wrote ~/.config/i3/config (\$(wc -l < ~/.config/i3/config) lines)"

# A simple .xinitrc — start i3 directly.
cat > ~/.xinitrc <<'XIN'
#!/bin/sh
# Hand off to i3 when xinit or startx is used. The proot start-x11
# wrapper sources this so the entry is uniform.
xrdb -merge ~/.Xresources 2>/dev/null || true
exec dbus-launch --exit-with-session i3
XIN
chmod +x ~/.xinitrc

# xfce4-terminal: stop Alt+letter from triggering the menu bar (it eats
# Alt+T → tmux prefix, etc.). Also hide the menu bar by default — right-click
# → "Show Menubar" to bring it back temporarily.
mkdir -p ~/.config/xfce4/terminal
cat > ~/.config/xfce4/terminal/terminalrc <<'TRC'
[Configuration]
MiscMenubarDefault=FALSE
ShortcutsNoMnemonics=TRUE
ShortcutsNoMenukey=FALSE
TRC

# Cheatsheet helper — bound to \$mod+slash by the i3 config. Lives in its own
# script so the i3 bindsym stays a single short line (i3's exec parser is
# fragile with nested quotes + line continuations).
mkdir -p ~/.local/bin
cat > ~/.local/bin/i3-cheatsheet <<'CHEAT'
#!/bin/sh
exec xfce4-terminal -T "i3 cheatsheet" -e \
    "sh -c 'grep -E \"^bindsym \" \"$HOME/.config/i3/config\" | sed \"s/^bindsym //; s/exec //\" | less'"
CHEAT
chmod +x ~/.local/bin/i3-cheatsheet

# Friendly default bashrc additions
grep -q 'PROOT_UBUNTU_PROMPT' ~/.bashrc 2>/dev/null || cat >> ~/.bashrc <<'BRC'

# --- added by pixel/termux/05-bootstrap-proot-desktop.sh ---
export PROOT_UBUNTU_PROMPT=1
export EDITOR=vim
export LANG=en_US.UTF-8
PS1='\[\033[01;32m\]\u@proot-ubuntu\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ '
# --- end ---
BRC
EOF

# ---- 4. wrap up -----------------------------------------------------------
log "[4/4] done"
log ""
log "  i3 + rofi + xfce4-terminal + Firefox installed inside $PROOT_DISTRO"
log "  config at /home/$PROOT_USER/.config/i3/config (in the proot rootfs)"
log "  start the desktop:"
log "    bash ~/linux-setups/pixel/termux/06-deploy-runtime-scripts.sh   # writes ~/start-x11.sh etc"
log "    bash ~/start-x11.sh"
