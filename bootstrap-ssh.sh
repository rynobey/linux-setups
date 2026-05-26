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

# ---- Termux guard ----------------------------------------------------------
# bootstrap-ssh.sh sets up incoming-sshd on a Linux host (Alpine/Ubuntu/
# Debian) via apt/apk + systemctl/rc-service. None of that applies to
# Termux, which has its own sshd flow via `pkg install openssh + sshd`
# and writes authorized_keys to ~/.ssh/ in the user dir. Bail with a
# pointer instead of failing in a confusing way.
if [ -n "${PREFIX:-}" ] && [ -x "${PREFIX}/bin/pkg" ]; then
    err "this script targets Linux hosts (Alpine/Ubuntu/Debian), not Termux."
    err ""
    err "if you want incoming SSH on Termux specifically:"
    err "  pkg install -y openssh"
    err "  sshd                              # starts on port 8022 by default"
    err "  # then drop your laptop's pubkey into ~/.ssh/authorized_keys"
    err ""
    err "if you wanted the linux-setups repo + tools set up on Termux,"
    err "use pixel/termux/init.sh instead — it covers the Termux path."
    exit 1
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

# On Alpine, openssh-server doesn't bundle sftp-server or scp — they
# ship as separate apk packages. Without them, modern scp from a
# laptop fails ("sh: scp: not found") and even the legacy -O fallback
# can't work. Install both proactively on Alpine; on Debian/Ubuntu the
# openssh-server package already includes both, so this is a no-op
# there (apt installs are idempotent).
if [ "$PKG_FAMILY" = apk ]; then
    if ! [ -x /usr/lib/ssh/sftp-server ]; then
        need_install+=(openssh-sftp-server)
    fi
    if ! command -v scp >/dev/null 2>&1; then
        # openssh-client gives Alpine the `scp` and `ssh` commands;
        # the daemon's openssh-server doesn't include them.
        need_install+=(openssh-client)
    fi
fi

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
