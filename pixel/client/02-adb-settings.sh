#!/usr/bin/env bash
# Re-apply the ADB-side config Podroid needs (Phantom Process Killer
# disable, AVF perms, storage perms). Workflow (h) from pixel/README.md.
#
# Run from your CLIENT machine after pairing+connecting ADB. Useful when:
#   - You re-paired ADB and need to re-grant perms
#   - You enabled new AVF permissions and want them re-applied
#   - Just want to verify the config is in place
#
# Thin wrapper around pixel/podroid/helper/adb-setup.sh — that script
# is idempotent so re-running is harmless.
#
# Flags:
#   --include-stock-terminal   also apply Stock Terminal's adb-setup
#                              (touch /sdcard/linux/virglrenderer)

set -euo pipefail

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helper"
. "$_LIB_DIR/_lib.sh"

INCLUDE_STOCK=0
while [ $# -gt 0 ]; do
    case "$1" in
        --include-stock-terminal) INCLUDE_STOCK=1; shift ;;
        -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done

bash "$LSDIR/pixel/podroid/helper/adb-setup.sh"

if [ "$INCLUDE_STOCK" -eq 1 ]; then
    if [ -x "$LSDIR/pixel/stock-terminal/adb-setup.sh" ]; then
        bash "$LSDIR/pixel/stock-terminal/adb-setup.sh"
    else
        warn "stock-terminal/adb-setup.sh not found; skipping"
    fi
fi
