#!/usr/bin/env bash
# Sync Stock Terminal VM backups between the VM (on the Pixel) and
# any external host (laptop, Termux on the Pixel itself, iPad, etc.).
# Pure ssh + scp — no platform-specific dependencies.
#
# Why this exists: AVF's SharedPath feature for /sdcard/ access from
# guest VMs is silently dropped on the current Pixel 10 / Android 16
# build. backup.sh writes to /var/lib/stock-terminal-backups/ inside
# the VM — that survives reboots but lives inside the Stock Terminal
# app sandbox, so it does NOT survive an app uninstall or Stock
# Terminal data wipe. To make backups truly durable, copy them out
# of the VM entirely via scp.
#
# Where to run this:
#   - Your laptop with ssh+scp (any OS)
#   - Termux on the Pixel itself: `pkg install openssh` then run here
#   - iPad with a-Shell or any ssh client app that has scp
#   - Another Pixel, server, NAS — anywhere ssh works
#
# Transport: ssh to the Stock Terminal Debian VM. By default uses
# port 22 (the VM's standard sshd port — no Podroid-style wrapper).
# You need:
#   (a) sshd installed and running inside the Stock Terminal VM
#       (`sudo apt install -y openssh-server`)
#   (b) A way to reach the VM — Tailscale inside the VM is cleanest;
#       otherwise direct IP + Stock Terminal's port-forward setup
#
# Modes:
#   --pull (default)    download VM:$REMOTE_DIR/* → host:$LOCAL_DIR/
#   --push              upload host:$LOCAL_DIR/<file> → VM:$REMOTE_DIR/
#   --list-remote       just list what's on the VM
#   --list-local        just list what's local
#
# Env / flags:
#   --host <name>       SSH target (default: stock-terminal, override via DEV_HOST)
#   --port <n>          SSH port (default: 22, override via DEV_PORT)
#   --user <name>       SSH user (default: droid, override via DEV_USER)
#   --remote <path>     VM-side dir (default: /var/lib/stock-terminal-backups)
#                       override via REMOTE_DIR
#   --local <path>      External host dir (default: ~/stock-terminal-backups)
#                       override via LOCAL_DIR
#   --delete-after      after a successful --pull, remove the remote copy
#
# Examples:
#   ./sync-backups.sh                                   # pull from default Tailscale host
#   ./sync-backups.sh --host 100.83.12.4                # by Tailscale IP
#   ./sync-backups.sh --host phone.local --port 2222    # LAN + custom port
#   ./sync-backups.sh --push --local ~/old-backups      # restore from your stash

set -euo pipefail

DEV_HOST="${DEV_HOST:-stock-terminal}"
DEV_PORT="${DEV_PORT:-22}"
DEV_USER="${DEV_USER:-droid}"
REMOTE_DIR="${REMOTE_DIR:-/var/lib/stock-terminal-backups}"

# Local-side directory varies by context, same logic as the podroid
# sync-backups.sh: Termux uses ~/recovery-bundle (shared with the
# gather/restore flow), other hosts use a script-specific default.
if [ -n "${PREFIX:-}" ] && [ -x "${PREFIX}/bin/pkg" ]; then
    LOCAL_DIR_DEFAULT="$HOME/recovery-bundle"
else
    LOCAL_DIR_DEFAULT="$HOME/stock-terminal-backups"
fi
LOCAL_DIR="${LOCAL_DIR:-$LOCAL_DIR_DEFAULT}"

MODE=pull
DELETE_AFTER=0

while [ $# -gt 0 ]; do
    case "$1" in
        --pull)         MODE=pull; shift ;;
        --push)         MODE=push; shift ;;
        --list-remote)  MODE=list-remote; shift ;;
        --list-local)   MODE=list-local; shift ;;
        --host)         DEV_HOST="$2"; shift 2 ;;
        --port)         DEV_PORT="$2"; shift 2 ;;
        --user)         DEV_USER="$2"; shift 2 ;;
        --remote)       REMOTE_DIR="$2"; shift 2 ;;
        --local)        LOCAL_DIR="$2"; shift 2 ;;
        --delete-after) DELETE_AFTER=1; shift ;;
        -h|--help)      sed -n '2,55p' "$0"; exit 0 ;;
        *)              echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done

log()  { printf '\033[1;34m[sync-backups]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; }

SSH=(ssh -p "$DEV_PORT" -o ConnectTimeout=10 "${DEV_USER}@${DEV_HOST}")

# Pick the right scp flags. On Debian, sftp-server ships as part of
# openssh-server (path /usr/lib/openssh/sftp-server). If for some
# reason it's not there, we fall back to -O (legacy SCP), which needs
# `scp` on the remote. If neither is present, install openssh-server
# (which bundles both) and retry.
probe_scp() {
    if "${SSH[@]}" 'test -x /usr/libexec/sftp-server || test -x /usr/lib/sftp-server || test -x /usr/lib/openssh/sftp-server' 2>/dev/null; then
        SCP=(scp -P "$DEV_PORT")
        return
    fi
    if "${SSH[@]}" 'command -v scp >/dev/null' 2>/dev/null; then
        log "no sftp-server on VM — using legacy SCP protocol (-O)"
        SCP=(scp -O -P "$DEV_PORT")
        return
    fi
    log "neither sftp-server nor scp on VM — installing openssh-server"
    if ! "${SSH[@]}" 'command -v apt-get >/dev/null && sudo apt-get install -y openssh-server' 2>&1; then
        err "failed to install openssh-server on the remote"
        err "install it manually: ssh ${DEV_USER}@${DEV_HOST} -p ${DEV_PORT} 'sudo apt install -y openssh-server'"
        exit 1
    fi
    SCP=(scp -P "$DEV_PORT")
}

case "$MODE" in
    list-remote)
        log "listing $REMOTE_DIR on ${DEV_USER}@${DEV_HOST}:${DEV_PORT}"
        "${SSH[@]}" "ls -lah ${REMOTE_DIR}/ 2>/dev/null || echo '(empty or missing)'"
        ;;
    list-local)
        log "listing $LOCAL_DIR"
        ls -lah "$LOCAL_DIR/" 2>/dev/null || echo "(empty or missing)"
        ;;
    pull)
        mkdir -p "$LOCAL_DIR"
        probe_scp
        log "pulling from ${DEV_USER}@${DEV_HOST}:${REMOTE_DIR}/ → ${LOCAL_DIR}/"
        remote_files=$("${SSH[@]}" "ls -1 ${REMOTE_DIR}/*.tar.gz ${REMOTE_DIR}/*.tar.gz.age 2>/dev/null") || true
        if [ -z "$remote_files" ]; then
            warn "no backups found at ${DEV_USER}@${DEV_HOST}:${REMOTE_DIR}/"
            exit 0
        fi
        pulled=0
        failed=0
        while IFS= read -r remote; do
            [ -z "$remote" ] && continue
            base="$(basename "$remote")"
            local_path="${LOCAL_DIR}/${base}"
            if [ -f "$local_path" ]; then
                local_size=$(stat -c '%s' "$local_path" 2>/dev/null)
                remote_size=$("${SSH[@]}" "stat -c '%s' ${remote}" 2>/dev/null || echo "0")
                if [ "$local_size" = "$remote_size" ]; then
                    log "skip: $base (already have it, same size)"
                    pulled=$((pulled + 1))
                    continue
                fi
            fi
            log "fetch: $base"
            # No output redirection — let scp's native progress meter
            # (percent / bytes / speed / ETA) reach the terminal.
            if "${SCP[@]}" "${DEV_USER}@${DEV_HOST}:${remote}" "$LOCAL_DIR/"; then
                pulled=$((pulled + 1))
                if [ "$DELETE_AFTER" -eq 1 ]; then
                    "${SSH[@]}" "rm -f ${remote}"
                    log "    deleted remote copy"
                fi
            else
                warn "    failed to fetch $base"
                failed=$((failed + 1))
            fi
        done <<< "$remote_files"
        log "done — $pulled local, $failed failed"
        ;;
    push)
        if [ ! -d "$LOCAL_DIR" ]; then
            err "$LOCAL_DIR doesn't exist"
            exit 1
        fi
        probe_scp
        shopt -s nullglob
        # Only push files that look like stock-terminal backups — avoids
        # accidentally uploading e.g. pubuntu-* from a mixed-backup dir.
        locals=("$LOCAL_DIR"/stock-terminal-*.tar.gz "$LOCAL_DIR"/stock-terminal-*.tar.gz.age)
        shopt -u nullglob
        if [ "${#locals[@]}" -eq 0 ]; then
            warn "no stock-terminal-*.tar.gz[.age] files in $LOCAL_DIR"
            warn "(podroid backups are skipped — they're prefixed differently)"
            exit 0
        fi
        log "pushing ${LOCAL_DIR}/stock-terminal-* → ${DEV_USER}@${DEV_HOST}:${REMOTE_DIR}/"
        "${SSH[@]}" "sudo mkdir -p ${REMOTE_DIR} && sudo chown ${DEV_USER}: ${REMOTE_DIR}"
        pushed=0
        failed=0
        for f in "${locals[@]}"; do
            base="$(basename "$f")"
            log "send: $base"
            # No output redirection — see corresponding comment in pull.
            if "${SCP[@]}" "$f" "${DEV_USER}@${DEV_HOST}:${REMOTE_DIR}/"; then
                pushed=$((pushed + 1))
            else
                warn "    failed to push $base"
                failed=$((failed + 1))
            fi
        done
        log "done — $pushed remote, $failed failed"
        ;;
esac
