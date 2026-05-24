#!/usr/bin/env bash
# Interactive script to create a new user inside the Podroid Ubuntu LXC.
# See README.md in this directory for the broader bootstrap flow.
#
# Prompts for username, sudo membership, and shell. Sets a password via
# the standard `passwd` flow (no plaintext on disk, no echo).
# Safe to re-run; bails cleanly if the chosen username already exists.

set -euo pipefail

log()  { printf '\033[1;34m[create-user]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; }

# --- Need root (or sudo) for useradd/passwd/usermod ---
if [ "$EUID" -ne 0 ]; then
    if ! command -v sudo >/dev/null 2>&1; then
        err "Run as root or install sudo."
        exit 1
    fi
    exec sudo -E bash "$0" "$@"
fi

# --- Username ---
USERNAME=""
while true; do
    read -rp "Username for the new user: " USERNAME

    if [ -z "$USERNAME" ]; then
        warn "Username can't be empty."
        continue
    fi

    # Rough POSIX-ish username rule: start with lowercase letter or _,
    # then [a-z0-9_-], up to 32 chars total.
    if ! [[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
        warn "Invalid username. Use lowercase letters, digits, _ and -, starting with a letter or _."
        continue
    fi

    if id "$USERNAME" >/dev/null 2>&1; then
        warn "User '$USERNAME' already exists."
        read -rp "Pick a different username? [Y/n] " choice
        case "$choice" in
            n|N) err "Aborting."; exit 1 ;;
            *)   continue ;;
        esac
    fi

    break
done

# --- Sudo membership ---
# Recommended: bootstrap-lxc and the per-tool installers all need sudo
# (apt, systemctl, docker/tailscale daemons).
GRANT_SUDO=1
read -rp "Grant sudo privileges? [Y/n] " choice
case "$choice" in
    n|N) GRANT_SUDO=0
         warn "Without sudo, this user can't run 02-bootstrap-lxc.sh."
         ;;
esac

# --- Shell ---
read -rp "Login shell [/bin/bash]: " SHELL_CHOICE
SHELL_CHOICE="${SHELL_CHOICE:-/bin/bash}"
if [ ! -x "$SHELL_CHOICE" ]; then
    warn "Shell '$SHELL_CHOICE' not executable. Falling back to /bin/bash."
    SHELL_CHOICE=/bin/bash
fi

# --- Create the account ---
log "Creating user '$USERNAME' with home directory and shell $SHELL_CHOICE"
useradd -m -s "$SHELL_CHOICE" "$USERNAME"

# --- Set the password (interactive, secure) ---
log "Setting password for '$USERNAME' — enter twice when prompted."
if ! passwd "$USERNAME"; then
    warn "Password not set. The account exists but has no usable password."
    warn "You can set one later with: sudo passwd $USERNAME"
fi

# --- Sudo group ---
if [ "$GRANT_SUDO" -eq 1 ]; then
    log "Adding '$USERNAME' to sudo group"
    usermod -aG sudo "$USERNAME"
fi

# --- Summary ---
SUDO_STATUS=$( [ "$GRANT_SUDO" -eq 1 ] && echo yes || echo no )
cat <<EOF

==============================================================
User '$USERNAME' created.

  Home:   /home/$USERNAME
  Shell:  $SHELL_CHOICE
  Sudo:   $SUDO_STATUS

Switch to this user now with:
  su - $USERNAME

Next: from this user's shell, run bootstrap-ssh.sh then
bootstrap-git.sh to authorize laptop access and set up the
device's own GitHub identity. See the parent README.md.
==============================================================
EOF
