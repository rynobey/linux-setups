#!/data/data/com.termux/files/usr/bin/bash
# One-shot Termux:X11 + direct-X bridge setup. Calls 06 (which installs
# the Termux-side prereq packages and deploys the runtime scripts).
#
# Was historically a 3-step orchestrator covering proot-Ubuntu install,
# i3 bootstrap, and runtime-scripts deploy. The proot layers were
# removed once we settled on Termux-native + pubuntu via SSH/X-forward
# (with direct-X-over-TCP bridging) as the architecture. See
# pixel/docs/pixel-desktop-architecture.md.
#
# Env overrides — see 06-deploy-runtime-scripts.sh.

set -euo pipefail

LSDIR="${LSDIR:-$HOME/linux-setups}"
HERE="$LSDIR/pixel/termux"

log()    { printf '\033[1;32m[setup-desktop]\033[0m %s\n' "$*"; }
err()    { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; }

if [ ! -d "$HERE" ]; then
    err "expected scripts at $HERE — set LSDIR=path-to-linux-setups if non-default"
    exit 1
fi

bash "$HERE/06-deploy-runtime-scripts.sh"

log ""
log "Desktop runtime scripts deployed. To use:"
log "  bash ~/start-x11.sh       # bring up Termux:X11 + direct-X bridge"
log "  bash ~/stop-x11.sh        # tear it down"
log ""
log "Then launch X apps from a Termux shell or via SSH into pubuntu:"
log "  Termux-native:   DISPLAY=:0 firefox &"
log "  Pubuntu:         ssh -p 9923 ryno@localhost"
log "                   export DISPLAY=10.198.187.116:0 ; xeyes &"
log ""
log "Make a recovery snapshot of \$PREFIX + \$HOME:"
log "  bash $HERE/02-snapshot.sh"
