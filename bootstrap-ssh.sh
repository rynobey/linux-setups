#!/usr/bin/env bash
# Bootstrap SSH access on this device using public keys from the
# rynobey/linux-setups public repo.
#
# After running this, any machine whose private key matches a pubkey in
# this repo's pubkeys/*.pub can SSH into this device as $USER.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/rynobey/linux-setups/master/bootstrap-ssh.sh | bash
#
# Idempotent: re-running adds any new keys, skips ones already authorized.
# Doesn't touch sshd_config — distros default to key-friendly. Lock down
# PasswordAuthentication separately if desired (see pixel/podroid/README.md).

# nvm-style scripts need `-u` off; this one is self-contained so the full
# strict mode is safe.
set -euo pipefail

REPO_OWNER="${REPO_OWNER:-rynobey}"
REPO_NAME="${REPO_NAME:-linux-setups}"
REPO_BRANCH="${REPO_BRANCH:-master}"

log()  { printf '\033[1;34m[bootstrap-ssh]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; }

if [ "$(id -u)" -eq 0 ]; then
    warn "running as root — authorized_keys will land in /root/.ssh/."
    warn "if you meant to authorize a regular user, ctrl-c and re-run as them."
fi

# ---- package manager detection ---------------------------------------------
if command -v apt-get >/dev/null 2>&1; then
    PKG_FAMILY=apt
elif command -v apk >/dev/null 2>&1; then
    PKG_FAMILY=apk
else
    err "no supported package manager (apt-get or apk). Edit script to add."
    exit 1
fi

pkg_install() {
    case "$PKG_FAMILY" in
        apt) sudo apt-get update -y && sudo apt-get install -y "$@" ;;
        apk) sudo apk add --no-cache "$@" ;;
    esac
}

# ---- sshd + tools ----------------------------------------------------------
need_install=()
command -v sshd >/dev/null 2>&1 || need_install+=(openssh-server)
command -v curl >/dev/null 2>&1 || need_install+=(curl)
command -v tar  >/dev/null 2>&1 || need_install+=(tar)
if [ "${#need_install[@]}" -gt 0 ]; then
    log "installing: ${need_install[*]}"
    pkg_install "${need_install[@]}"
fi

# ---- start sshd ------------------------------------------------------------
if command -v systemctl >/dev/null 2>&1; then
    # ssh.service on Debian/Ubuntu, sshd.service on RHEL-likes
    sudo systemctl enable --now ssh 2>/dev/null \
        || sudo systemctl enable --now sshd
elif command -v rc-service >/dev/null 2>&1; then
    # Alpine / OpenRC
    sudo rc-update add sshd default >/dev/null 2>&1 || true
    sudo rc-service sshd start
else
    sudo service ssh start 2>/dev/null || sudo service sshd start
fi
log "sshd running"

# ---- fetch pubkeys from the public repo tarball ----------------------------
log "fetching pubkeys/ from ${REPO_OWNER}/${REPO_NAME}@${REPO_BRANCH}"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
tarball_url="https://codeload.github.com/${REPO_OWNER}/${REPO_NAME}/tar.gz/refs/heads/${REPO_BRANCH}"
curl -fsSL "$tarball_url" | tar -xz -C "$tmp"

pubkey_dir=$(find "$tmp" -maxdepth 3 -type d -name pubkeys | head -1)
if [ -z "$pubkey_dir" ]; then
    err "pubkeys/ dir not found in repo tarball"
    exit 1
fi
shopt -s nullglob
pubs=("$pubkey_dir"/*.pub)
shopt -u nullglob
if [ "${#pubs[@]}" -eq 0 ]; then
    err "no .pub files in pubkeys/"
    exit 1
fi

# ---- append to authorized_keys (deduped) -----------------------------------
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
auth_file="$HOME/.ssh/authorized_keys"
touch "$auth_file"
chmod 600 "$auth_file"

added=0
for pub in "${pubs[@]}"; do
    # Match on the type+key fields only; the trailing comment varies.
    key_core=$(awk '{print $1" "$2}' "$pub")
    if grep -qF "$key_core" "$auth_file"; then
        log "$(basename "$pub") already authorized"
    else
        cat "$pub" >> "$auth_file"
        log "added $(basename "$pub")"
        added=$((added + 1))
    fi
done

log "done — $added new key(s) authorized in $auth_file"
log "user: $USER  /  home: $HOME"
log "test from another machine: ssh $USER@<this-host>"
