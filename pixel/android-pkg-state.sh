#!/usr/bin/env bash
# Enable/disable Android system packages we've found worth toggling
# for memory headroom (mainly: AiCore + TTS).
#
# Runs on any host with ADB connected to the Pixel.
#
# Subcommands:
#   status            show whether each tracked package is enabled/disabled
#   disable [pkg...]  disable all tracked, or just the named one(s)
#   enable  [pkg...]  enable all tracked, or just the named one(s)
#   list              list the tracked packages with their descriptions
#
# Examples:
#   ./android-pkg-state.sh status
#   ./android-pkg-state.sh disable          # disables everything in TRACKED
#   ./android-pkg-state.sh enable           # re-enables everything in TRACKED
#   ./android-pkg-state.sh disable com.google.android.aicore
#
# The disable state survives reboots. Re-running 'enable' restores normal
# behaviour with no data loss.
#
# Memory deltas are reported before/after so you can see the impact.
# See android-disabled-packages.md in this dir for the full notes on what
# each package controls and what features you lose when it's disabled.

set -euo pipefail

# Tracked packages — extend this list as you find more worth toggling.
# Format: "package|short-desc"
TRACKED=(
    "com.google.android.aicore|Gemini Nano on-device AI; ~3 GB when active, ~130 MB idle. Disable = no Magic Compose / Smart Reply / Now Brief."
    "com.google.android.tts|Google Text-to-Speech engine; ~130 MB. Disable = no TalkBack voice / Maps voice prompts."
    # Add more here as needed, e.g.:
    # "com.facebook.katana|Facebook app; ~170 MB resident. Disable if you don't use it."
)

log()  { printf '\033[1;34m[android-pkg-state]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; }

# ---- prereq: ADB ----------------------------------------------------------
if ! command -v adb >/dev/null 2>&1; then
    err "adb not found. apt install adb (Ubuntu) or pkg install android-tools (Termux)"
    exit 1
fi

require_device() {
    if ! adb devices | awk 'NR>1 && $2 == "device" {found=1} END {exit !found}'; then
        err "no authorized ADB device. pair first:"
        err "  Settings → Developer options → Wireless debugging → Pair device with pairing code"
        err "  adb pair <ip>:<port>  (enter 6-digit code)"
        err "  adb connect <ip>:<port>"
        exit 1
    fi
}

# ---- helpers --------------------------------------------------------------
# Resolve a package name (or short alias) against the TRACKED list.
# Aliases supported: short name (e.g. "aicore" matches "com.google.android.aicore").
resolve_pkg() {
    local q="$1"
    # Exact match first
    for entry in "${TRACKED[@]}"; do
        local pkg="${entry%%|*}"
        [ "$pkg" = "$q" ] && { echo "$pkg"; return 0; }
    done
    # Suffix match (e.g. "aicore" matches anything ending in .aicore)
    for entry in "${TRACKED[@]}"; do
        local pkg="${entry%%|*}"
        case "$pkg" in *."$q"|*"$q") echo "$pkg"; return 0 ;; esac
    done
    # Not tracked but might be a real package — accept verbatim if it looks like one
    case "$q" in
        *.*.*) echo "$q"; return 0 ;;
    esac
    return 1
}

pkg_is_disabled() {
    # Returns 0 (true) if the package is currently in 'disabled-user' state.
    # `pm list packages -d` lists disabled packages.
    adb shell "pm list packages -d 2>/dev/null | grep -q '^package:$1\$'"
}

pkg_exists() {
    adb shell "pm list packages 2>/dev/null | grep -q '^package:$1\$'"
}

snapshot_mem() {
    adb shell cat /proc/meminfo 2>/dev/null | awk '
        /MemFree:/      { f = $2 }
        /MemAvailable:/ { a = $2 }
        END { printf "free=%4dM available=%4dM", f/1024, a/1024 }'
}

# ---- subcommands ----------------------------------------------------------
cmd_list() {
    log "tracked packages:"
    for entry in "${TRACKED[@]}"; do
        local pkg="${entry%%|*}"
        local desc="${entry#*|}"
        printf '  %-40s  %s\n' "$pkg" "$desc"
    done
}

cmd_status() {
    require_device
    log "state of tracked packages on $(adb devices | awk 'NR>1 && $2=="device"{print $1}'):"
    for entry in "${TRACKED[@]}"; do
        local pkg="${entry%%|*}"
        local state
        if ! pkg_exists "$pkg"; then
            state='not installed'
        elif pkg_is_disabled "$pkg"; then
            state='disabled  ✗'
        else
            state='enabled   ✓'
        fi
        printf '  %-40s  %s\n' "$pkg" "$state"
    done
    log ""
    log "memory now: $(snapshot_mem)"
}

cmd_disable() {
    require_device
    local -a targets=()
    if [ "$#" -eq 0 ]; then
        for entry in "${TRACKED[@]}"; do targets+=("${entry%%|*}"); done
    else
        for arg in "$@"; do
            local resolved
            resolved=$(resolve_pkg "$arg") || { err "unknown package '$arg'"; exit 1; }
            targets+=("$resolved")
        done
    fi

    log "memory before: $(snapshot_mem)"
    for pkg in "${targets[@]}"; do
        if ! pkg_exists "$pkg"; then
            warn "$pkg: not installed, skipping"
            continue
        fi
        if pkg_is_disabled "$pkg"; then
            log "$pkg: already disabled"
            continue
        fi
        log "disabling $pkg"
        adb shell pm disable-user --user 0 "$pkg" >/dev/null
    done
    sleep 3
    log "memory after:  $(snapshot_mem)"
}

cmd_enable() {
    require_device
    local -a targets=()
    if [ "$#" -eq 0 ]; then
        for entry in "${TRACKED[@]}"; do targets+=("${entry%%|*}"); done
    else
        for arg in "$@"; do
            local resolved
            resolved=$(resolve_pkg "$arg") || { err "unknown package '$arg'"; exit 1; }
            targets+=("$resolved")
        done
    fi

    log "memory before: $(snapshot_mem)"
    for pkg in "${targets[@]}"; do
        if ! pkg_exists "$pkg"; then
            warn "$pkg: not installed, skipping"
            continue
        fi
        if ! pkg_is_disabled "$pkg"; then
            log "$pkg: already enabled"
            continue
        fi
        log "enabling $pkg"
        adb shell pm enable "$pkg" >/dev/null
    done
    sleep 3
    log "memory after:  $(snapshot_mem)"
}

cmd_help() {
    sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
}

# ---- dispatch -------------------------------------------------------------
sub="${1:-status}"
shift || true
case "$sub" in
    status)   cmd_status "$@" ;;
    disable)  cmd_disable "$@" ;;
    enable)   cmd_enable "$@" ;;
    list)     cmd_list "$@" ;;
    help|-h|--help) cmd_help ;;
    *)
        err "unknown subcommand: $sub"
        cmd_help
        exit 1
        ;;
esac
