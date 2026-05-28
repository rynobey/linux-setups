#!/data/data/com.termux/files/usr/bin/bash
# One-shot orchestrator that runs 04 + 05 + 06 in sequence — the
# DroidDesk-equivalent for this fork:
#
#   04   install Ubuntu 24.04 proot + user with sudo
#   05   apt-install i3 + GUI toolkit + Firefox inside it; write i3 config
#   06   deploy ~/start-x11.sh, ~/start-proot.sh, ~/stop-x11.sh in Termux $HOME
#
# Idempotent — each sub-script is. Safe to re-run.
#
# Run after 01-init-termux.sh. Designed to work both on-device and over
# SSH (it doesn't need a tty or foreground; the GUI only fires when you
# explicitly call ~/start-x11.sh later).
#
# Env overrides flow through to the sub-scripts. Common ones:
#   PROOT_USER       default: ryno
#   PROOT_DISTRO     default: ubuntu (Noble 24.04 LTS)
#   I3_MOD           default: Mod4   (Super; set Mod1 for Alt-only keyboards)
#   INSTALL_FIREFOX  default: 1
#   FORCE_REINSTALL  default: 0      set 1 to nuke + reinstall the rootfs

set -euo pipefail

LSDIR="${LSDIR:-$HOME/linux-setups}"
HERE="$LSDIR/pixel/termux"

log()   { printf '\033[1;32m[setup-desktop]\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
err()   { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; }
banner(){
    local n="$1" total="$2" name="$3"
    local bar; bar=$(printf '%*s' 60 '' | tr ' ' '=')
    printf '\n\033[1;36m%s\n  STEP %d/%d  %s\n%s\033[0m\n\n' "$bar" "$n" "$total" "$name" "$bar"
}

if [ ! -d "$HERE" ]; then
    err "expected scripts at $HERE — set LSDIR=path-to-linux-setups if non-default"
    exit 1
fi

TOTAL=3

banner 1 $TOTAL "Install proot Ubuntu 24.04 + user"
bash "$HERE/04-install-proot-ubuntu.sh"

banner 2 $TOTAL "Bootstrap i3 + GUI toolkit inside proot Ubuntu"
bash "$HERE/05-bootstrap-proot-desktop.sh"

banner 3 $TOTAL "Deploy ~/start-x11.sh, ~/start-proot.sh, ~/stop-x11.sh"
bash "$HERE/06-deploy-runtime-scripts.sh"

log ""
log "Desktop setup complete. To use:"
log "  bash ~/start-x11.sh       # bring up the Termux:X11 + i3 desktop"
log "  bash ~/start-proot.sh     # plain proot Ubuntu shell (no GUI)"
log "  bash ~/stop-x11.sh        # tear down the desktop"
log ""
log "Make a recovery snapshot (now includes the proot rootfs):"
log "  bash $HERE/02-snapshot.sh"
