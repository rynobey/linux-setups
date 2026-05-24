#!/usr/bin/env bash
# Authorize every *.pub in ../../pubkeys/ for SSH access as the
# invoking user. Used by 02-bootstrap-lxc.sh; safe to re-run any time
# after adding a new key to the repo.
#
# Counterpart to ../../bootstrap-ssh.sh — that one fetches pubkeys from
# the public repo over the network (curl-able for fresh machines).
# This one reads from the local cloned repo (no network needed).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PUBKEYS_DIR="${PUBKEYS_DIR:-$REPO_ROOT/pubkeys}"

log()  { printf '\033[1;34m[authorize-pubkeys]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; }

if [ ! -d "$PUBKEYS_DIR" ]; then
    err "pubkeys dir not found at $PUBKEYS_DIR"
    exit 1
fi

shopt -s nullglob
pubs=("$PUBKEYS_DIR"/*.pub)
shopt -u nullglob
if [ "${#pubs[@]}" -eq 0 ]; then
    err "no .pub files in $PUBKEYS_DIR"
    exit 1
fi

mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
auth_file="$HOME/.ssh/authorized_keys"
touch "$auth_file"
chmod 600 "$auth_file"

added=0
for pub in "${pubs[@]}"; do
    # Match on type+key only (comment field varies and isn't authoritative).
    key_core=$(awk '{print $1" "$2}' "$pub")
    if grep -qF "$key_core" "$auth_file"; then
        log "$(basename "$pub") already authorized"
    else
        cat "$pub" >> "$auth_file"
        log "added $(basename "$pub")"
        added=$((added + 1))
    fi
done

log "done — $added new key(s) added to $auth_file"
