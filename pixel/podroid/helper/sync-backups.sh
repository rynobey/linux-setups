#!/usr/bin/env bash
# Sync Podroid LXC backups between Alpine (on the Pixel) and your
# laptop. RUNS ON THE LAPTOP, not on Alpine.
#
# Why this exists: AVF's SharedPath feature for /sdcard/ access from
# guest VMs is silently dropped on the current Pixel 10 / Android 16
# build, so there's no working Alpine ↔ Android filesystem bridge.
# backup.sh writes to /var/lib/podroid-backups/ on Alpine — that
# survives reboots but lives inside Podroid's app sandbox, so it
# does NOT survive a Podroid uninstall. To make backups truly
# durable, you need to copy them out of Alpine entirely. This script
# does that via scp over Podroid's port-forwarded Alpine sshd.
#
# Transport: the script ssh's to a host that has Alpine's sshd
# reachable on a TCP port. Two ways to make that work:
#   (a) Tailscale — Podroid binds Alpine's port 9922 on the Pixel's
#       interfaces, so 'ssh root@<pixel-tailscale-name> -p 9922'
#       works from anywhere on the tailnet.
#   (b) ADB forward — 'adb forward tcp:9922 tcp:9922' tunnels
#       localhost:9922 to the Pixel; then ssh root@localhost -p 9922.
#
# Modes:
#   --pull (default)    download Alpine:$REMOTE_DIR/* → laptop:$LOCAL_DIR/
#   --push              upload laptop:$LOCAL_DIR/<file> → Alpine:$REMOTE_DIR/
#   --list-remote       just list what's on Alpine
#   --list-local        just list what's local
#
# Env / flags:
#   --host <name>       SSH target (default: 'pixel' off-device, or
#                       'localhost' when running on Termux on the Pixel itself)
#                       or set DEV_HOST=...
#   --port <n>          SSH port (default: 9922 — Podroid's Alpine forward)
#                       or set DEV_PORT=...
#   --user <name>       SSH user on Alpine (default: root)
#                       or set DEV_USER=...
#   --remote <path>     Alpine-side dir (default: /var/lib/podroid-backups)
#                       or set REMOTE_DIR=...
#   --local <path>      Laptop-side dir (default: ~/podroid-backups)
#                       or set LOCAL_DIR=...
#   --delete-after      after a successful --pull, remove the remote copy
#                       (only for files that transferred successfully)
#
# Examples:
#   ./sync-backups.sh                                    # pull from Tailscale-reachable Alpine
#   ./sync-backups.sh --pull --host 100.121.151.88       # by IP
#   adb forward tcp:9922 tcp:9922 && \
#       ./sync-backups.sh --host localhost               # over ADB tunnel
#   ./sync-backups.sh --push --local ~/old-backups       # restore from laptop
#
# scp needs Alpine to either have openssh-sftp-server installed, or
# the laptop's scp to support -O (legacy mode). This script tries the
# default first, and falls back to -O if it detects the sftp error.

set -euo pipefail

# Default host depends on where this script is running:
#   - On Termux on the same Pixel: 'localhost' (Podroid's port forward
#     binds 0.0.0.0:9922 on Android; localhost reaches it; Tailscale
#     hairpin routing to one's own node is unreliable so 'pixel' fails)
#   - On a different machine (laptop, etc.): 'pixel' (the Pixel's
#     Tailscale name, which routes via the tailnet to Podroid's port
#     forward)
# Override via env DEV_HOST or --host flag.
#
# IMPORTANT: don't use 'pubuntu' here — that's the LXC's Tailscale name,
# not Alpine's. The backups live on the Alpine host, NOT inside the LXC.
if [ -n "${PREFIX:-}" ] && [ -x "${PREFIX}/bin/pkg" ]; then
    DEV_HOST_DEFAULT="localhost"
else
    DEV_HOST_DEFAULT="pixel"
fi
DEV_HOST="${DEV_HOST:-$DEV_HOST_DEFAULT}"
DEV_PORT="${DEV_PORT:-9922}"
DEV_USER="${DEV_USER:-root}"
REMOTE_DIR="${REMOTE_DIR:-/var/lib/podroid-backups}"

# Local-side directory varies by context:
#   - On Termux on the Pixel: snapshot.sh pulls into ~/recovery-bundle/,
#     and the recovery flow extracts the bundle into the same path. Default
#     to that so a stand-alone `sync-backups.sh --push` Just Works without
#     needing --local.
#   - Elsewhere (laptop, server): use ~/podroid-backups/ — generic name
#     for the place where the laptop stashes pulled backups.
if [ -n "${PREFIX:-}" ] && [ -x "${PREFIX}/bin/pkg" ]; then
    LOCAL_DIR_DEFAULT="$HOME/recovery-bundle"
else
    LOCAL_DIR_DEFAULT="$HOME/podroid-backups"
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

# Pick the right scp flags. Alpine's openssh package is split:
#   - openssh-sftp-server (provides sftp-server, used by modern scp)
#   - openssh-client (provides scp, used by legacy `scp -O`)
# Neither is installed by default by `apk add openssh`. So we probe:
#   1. If sftp-server is present, use modern scp (no -O needed)
#   2. Else if scp is present on the remote, use -O legacy
#   3. Else, install openssh-sftp-server (apk add) and use modern scp
probe_scp() {
    if "${SSH[@]}" 'test -x /usr/libexec/sftp-server || test -x /usr/lib/ssh/sftp-server || test -x /usr/libexec/openssh/sftp-server' 2>/dev/null; then
        SCP=(scp -P "$DEV_PORT")
        return
    fi
    if "${SSH[@]}" 'command -v scp >/dev/null' 2>/dev/null; then
        log "no sftp-server on Alpine — using legacy SCP protocol (-O)"
        SCP=(scp -O -P "$DEV_PORT")
        return
    fi
    log "neither sftp-server nor scp on Alpine — installing openssh-sftp-server"
    if ! "${SSH[@]}" 'command -v apk >/dev/null && apk add --no-cache openssh-sftp-server' 2>&1; then
        err "failed to install openssh-sftp-server on the remote"
        err "install it manually: ssh ${DEV_USER}@${DEV_HOST} -p ${DEV_PORT} 'apk add openssh-sftp-server'"
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
        # Get the file list first so we can act on it (delete-after etc).
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
            # Skip ones we already have with same size (cheap dedup —
            # doesn't compare hashes, but backup files are immutable
            # once written so size equality is good enough).
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
        # Build list of local backups
        shopt -s nullglob
        locals=("$LOCAL_DIR"/*.tar.gz "$LOCAL_DIR"/*.tar.gz.age)
        shopt -u nullglob
        if [ "${#locals[@]}" -eq 0 ]; then
            warn "no backups in $LOCAL_DIR"
            exit 0
        fi
        log "pushing ${LOCAL_DIR}/ → ${DEV_USER}@${DEV_HOST}:${REMOTE_DIR}/"
        # Make sure remote dir exists
        "${SSH[@]}" "mkdir -p ${REMOTE_DIR}"
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
