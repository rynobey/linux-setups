#!/data/data/com.termux/files/usr/bin/bash
# Install Ubuntu 24.04 LTS (Noble) into a proot-distro container and
# create a non-root user with passwordless sudo. After this runs, you
# have a usable proot Linux env; the next step (05-bootstrap-proot-desktop.sh)
# installs i3 + the GUI bits inside it.
#
# Run after 01-init-termux.sh. Idempotent — if the distro is already
# installed and the user already exists, it skips both.
#
# Env overrides:
#   PROOT_DISTRO    default: ubuntu              proot-distro alias
#   PROOT_RELEASE   default: noble               (Ubuntu 24.04 LTS)
#   PROOT_USER      default: ryno                user created inside the rootfs
#   PROOT_USER_UID  default: 1000
#   FORCE_REINSTALL default: 0                   set 1 to nuke + reinstall the rootfs
#
# Why Ubuntu 24.04 specifically: 22.04's GTK4 is too old for modern apps
# (Ghostty, recent GNOME-stack things). 24.04 ships GTK 4.14+, fresh
# Mesa, and stays in LTS support until 2029.

set -euo pipefail

PROOT_DISTRO="${PROOT_DISTRO:-ubuntu}"
PROOT_RELEASE="${PROOT_RELEASE:-noble}"
PROOT_USER="${PROOT_USER:-ryno}"
PROOT_USER_UID="${PROOT_USER_UID:-1000}"
FORCE_REINSTALL="${FORCE_REINSTALL:-0}"

log()  { printf '\033[1;34m[install-proot]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; }

# ---- sanity -----------------------------------------------------------------
if ! command -v pkg >/dev/null 2>&1; then
    err "must run inside Termux"
    exit 1
fi
if [ "$(uname -m)" != "aarch64" ]; then
    warn "expected aarch64, got $(uname -m) — proceeding anyway"
fi

# ---- 1. ensure proot-distro is installed -----------------------------------
log "[1/4] ensuring proot + proot-distro are installed"
pkg install -y proot proot-distro >/dev/null

# ---- 2. (re)install Ubuntu -------------------------------------------------
# proot-distro v4 uses installed-rootfs/<name>/ layout; v5+ uses
# containers/<name>/rootfs/. Probe both for back/forward compat.
ROOTFS_DIR=""
for candidate in \
    "$PREFIX/var/lib/proot-distro/containers/$PROOT_DISTRO/rootfs" \
    "$PREFIX/var/lib/proot-distro/installed-rootfs/$PROOT_DISTRO"; do
    if [ -d "$candidate" ]; then
        ROOTFS_DIR="$candidate"
        break
    fi
done

ALREADY_INSTALLED=0
if proot-distro list 2>/dev/null | grep -qw "$PROOT_DISTRO"; then
    if [ -n "$ROOTFS_DIR" ] && [ -x "$ROOTFS_DIR/usr/bin/bash" ]; then
        ALREADY_INSTALLED=1
    else
        warn "proot-distro thinks $PROOT_DISTRO is installed but rootfs looks empty — will reinstall"
        FORCE_REINSTALL=1
    fi
fi

if [ "$ALREADY_INSTALLED" = "1" ] && [ "$FORCE_REINSTALL" = "0" ]; then
    log "[2/4] $PROOT_DISTRO already installed at $ROOTFS_DIR (skip — set FORCE_REINSTALL=1 to wipe)"
else
    if [ "$FORCE_REINSTALL" = "1" ] && [ "$ALREADY_INSTALLED" = "1" ]; then
        log "[2/4] FORCE_REINSTALL=1 — removing existing $PROOT_DISTRO first"
        proot-distro remove "$PROOT_DISTRO" || true
    fi
    log "[2/4] installing $PROOT_DISTRO ($PROOT_RELEASE) — this downloads ~50 MB and takes a few minutes"
    # 'ubuntu' alias maps to noble (24.04 LTS) on both proot-distro v4 and v5.
    # No --override-alias needed; we install with the default alias.
    proot-distro install "$PROOT_DISTRO" 2>&1 | sed 's/^/    /'

    # Re-probe ROOTFS_DIR after install so the rest of the script picks it up.
    for candidate in \
        "$PREFIX/var/lib/proot-distro/containers/$PROOT_DISTRO/rootfs" \
        "$PREFIX/var/lib/proot-distro/installed-rootfs/$PROOT_DISTRO"; do
        if [ -d "$candidate" ]; then ROOTFS_DIR="$candidate"; break; fi
    done
fi

# ---- 3. quick health check (the bug we hit before would surface here) ------
log "[3/4] sanity-check: running bash inside $PROOT_DISTRO"
if ! proot-distro login "$PROOT_DISTRO" -- bash -c 'echo "PROOT OK uid=$(id -u) os=$(grep ^PRETTY /etc/os-release | cut -d= -f2-)"' 2>&1 | sed 's/^/    /'; then
    err "proot-distro login failed — see project_termux_proot_broken_pixel10 memory; usually fixed by 'Clear Termux app data' then re-running this script"
    exit 1
fi

# ---- 4. create user with passwordless sudo ---------------------------------
log "[4/4] creating user '$PROOT_USER' (uid=$PROOT_USER_UID) with passwordless sudo"
proot-distro login "$PROOT_DISTRO" -- bash <<EOF
set -e
# locale (otherwise tons of apt/perl warnings)
apt-get update >/dev/null
apt-get install -y locales sudo curl ca-certificates >/dev/null
locale-gen en_US.UTF-8 >/dev/null
update-locale LANG=en_US.UTF-8 >/dev/null

# user
if id "$PROOT_USER" >/dev/null 2>&1; then
    echo "    user '$PROOT_USER' already exists, leaving as-is"
else
    useradd -m -u "$PROOT_USER_UID" -s /bin/bash "$PROOT_USER"
    usermod -aG sudo "$PROOT_USER"
    echo "$PROOT_USER ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/90-$PROOT_USER
    chmod 440 /etc/sudoers.d/90-$PROOT_USER
    # passwordless login — to actually require a password, run:
    #   proot-distro login $PROOT_DISTRO -- passwd $PROOT_USER
    passwd -d "$PROOT_USER"
    echo "    user '$PROOT_USER' created, in sudo group, passwordless sudo"
fi
EOF

log ""
log "$PROOT_DISTRO ready. Try:  proot-distro login $PROOT_DISTRO --user $PROOT_USER"
log ""
log "Next: install i3 + GUI apps inside it:"
log "  bash ~/linux-setups/pixel/termux/05-bootstrap-proot-desktop.sh"
