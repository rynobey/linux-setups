#!/usr/bin/env bash
# Back up the ENTIRE Podroid VM (disk image + app settings) to a single
# file on this client. Complements 03-backup-lxc.sh: that one snapshots
# the LXC from inside a RUNNING VM; this one snapshots the whole VM from
# OUTSIDE — Alpine system layer, all containers, podman/docker state,
# port-forward rules — and needs the VM to be STOPPED.
#
# How it works:
#   Everything the guest ever writes lives in ONE file in Podroid's
#   private dir: files/storage.img — a sparse 64 GiB ext4 image used as
#   the overlayfs upper (the squashfs lower ships with the APK and needs
#   no backup). App settings + port-forward rules live in files/datastore/.
#   We reach both via `adb ... run-as` (debug builds only — run-as is
#   refused for non-debuggable apps) and tar them SPARSE-AWARE (tar -S
#   transfers the ~11 GB of real data, not the 64 GiB apparent size),
#   compressing client-side with zstd (multithreaded; toybox gzip on the
#   device would bottleneck).
#
# Run from your CLIENT machine (Termux on the Pixel — fastest, loopback —
# or a Linux laptop with ADB paired+connected).
#
# Prereqs:
#   - ADB connected (`adb devices` shows "device"). From Termux:
#     `adb connect localhost:5555` after `adb tcpip 5555` from a paired
#     client, or the wireless-debugging pair+connect dance.
#   - Podroid VM STOPPED (stop it in the app; the script verifies).
#   - zstd on this client (pkg/apt install zstd); falls back to gzip.
#
# Flags:
#   --plain          unencrypted backup (default encrypts with gpg AES256)
#   --local <dir>    output dir (default: ~/recovery-bundle on Termux,
#                                          ~/podroid-backups elsewhere)
#   --pkg <pkg>      app package (default: com.excp.podroid.debug)
#   --list           show existing VM backups in the local dir
#
# The passphrase is collected ONCE before any data moves; the transfer
# and the end-to-end verification then run unattended. Save it to your
# password manager IMMEDIATELY — without it the backup is unrecoverable.
#
# Restore with: 10-restore-podroid-vm.sh

set -euo pipefail

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helper"
. "$_LIB_DIR/_lib.sh"

PKG="${PODROID_PKG:-com.excp.podroid.debug}"
if [ -n "${PREFIX:-}" ] && [ -x "${PREFIX}/bin/pkg" ]; then
    LOCAL_DIR_DEFAULT="$HOME/recovery-bundle"
else
    LOCAL_DIR_DEFAULT="$HOME/podroid-backups"
fi
LOCAL_DIR="${LOCAL_DIR_DEFAULT}"
ENCRYPT=1
MODE=backup

while [ $# -gt 0 ]; do
    case "$1" in
        --plain)   ENCRYPT=0; shift ;;
        --local)   LOCAL_DIR="$2"; shift 2 ;;
        --pkg)     PKG="$2"; shift 2 ;;
        --list|-l) MODE=list; shift ;;
        -h|--help) sed -n '2,41p' "$0"; exit 0 ;;
        *) err "unknown arg: $1"; exit 1 ;;
    esac
done

# ---- list mode --------------------------------------------------------------
if [ "$MODE" = list ]; then
    log "VM backups in $LOCAL_DIR:"
    found=0
    for f in "$LOCAL_DIR"/podroid-vm-*.tar.*; do
        [ -e "$f" ] || continue
        found=1
        printf '  %-50s  %6s  %s\n' "$(basename "$f")" \
            "$(du -h "$f" | awk '{print $1}')" \
            "$(stat -c '%y' "$f" | cut -d. -f1)"
    done
    [ "$found" -eq 0 ] && log "(none)"
    exit 0
fi

# ---- ADB preflight ----------------------------------------------------------
if ! command -v adb >/dev/null 2>&1; then
    err "adb not found. pkg install -y android-tools (Termux) or apt install adb (Ubuntu)"
    exit 1
fi
if ! adb devices | awk 'NR>1 && $2 == "device" {f=1} END{exit !f}'; then
    err "no authorized ADB device. Connect first (adb connect localhost:5555 from Termux)."
    exit 1
fi

# run-as only works on debuggable builds — fail early with a clear message.
if ! adb shell run-as "$PKG" ls files >/dev/null 2>&1; then
    err "run-as $PKG failed. Either the package isn't installed, or it's a"
    err "non-debuggable (release) build — this backup method needs the debug APK."
    exit 1
fi

# ---- VM must be stopped -----------------------------------------------------
# PodroidService is a foreground service that exists exactly while the VM
# runs (both QEMU and AVF backends). A live ServiceRecord ⇒ live ext4 ⇒
# a torn, unusable image — refuse to continue.
if adb shell dumpsys activity services "$PKG" 2>/dev/null | grep -q ServiceRecord; then
    err "Podroid VM appears to be RUNNING. Stop it in the app first"
    err "(Home → Stop), wait for it to fully stop, then re-run."
    exit 1
fi

# ---- Phantom Process Killer preflight ----------------------------------------
# The device-side `run-as <pkg> tar` runs under Podroid's UID — to Android
# that's a "phantom process" of a not-running app doing minutes of heavy
# I/O, a prime PPK kill target. A mid-stream kill produces a silently
# truncated backup (observed: 1.8 GiB of an 11.5 GiB stream). PPK settings
# also re-sync from Google's Phenotype service unless sync is disabled —
# so check every time, don't assume 02-adb-settings.sh from last month
# still holds.
ppk=$(adb shell settings get global settings_enable_monitor_phantom_procs | tr -d '\r')
if [ "$ppk" != "false" ]; then
    err "Phantom Process Killer monitoring is ACTIVE (settings_enable_monitor_phantom_procs=$ppk)."
    err "It can kill the device-side tar mid-stream → silently truncated backup."
    err "Re-apply the PPK disable first:"
    err "  bash $LSDIR/pixel/client/02-adb-settings.sh"
    exit 1
fi

# ---- encryption / compression tooling ---------------------------------------
# gpg symmetric (not age, unlike the repo's other backups): age refuses a
# passphrase from anywhere but the tty, which fights pv's progress bar and
# forces a SECOND prompt for the verification pass. gpg's loopback pinentry
# lets us collect the passphrase ONCE, up front, before any data moves.
if [ "$ENCRYPT" -eq 1 ] && ! command -v gpg >/dev/null 2>&1; then
    if [ -n "${PREFIX:-}" ] && [ -x "${PREFIX}/bin/pkg" ]; then
        log "installing gnupg (pkg install gnupg)"
        pkg install -y gnupg
    else
        err "gpg not found (apt install gnupg), or re-run with --plain"
        exit 1
    fi
fi
if command -v zstd >/dev/null 2>&1; then
    COMPRESS=(zstd -T0 -3 -q)
    EXT="tar.zst"
else
    warn "zstd not found — falling back to single-threaded gzip (slower)."
    warn "  pkg/apt install zstd for multi-core compression."
    COMPRESS=(gzip -c)
    EXT="tar.gz"
fi

# Expected stream size ≈ the image's allocated data — feeds the pv progress
# bar. NOTE: tar streams somewhat LESS than this (it hole-skips allocated-
# but-zero blocks, e.g. lazy inode tables), so the bar tops out around
# 90-95%, not 100. That's normal. Verification is structural, not size-based.
src_kb=$(adb shell run-as "$PKG" du -sk files/storage.img files/datastore \
    | awk '{s+=$1} END{print s}' | tr -d '\r')
expected_bytes=$(( src_kb * 1024 ))
# Apparent size of the image — the tar header must carry this exactly;
# it's also what the app's size check demands on restore.
img_bytes=$(adb shell run-as "$PKG" stat -c %s files/storage.img | tr -d '\r')

# Progress bar: pv sits between adb and the compressor so it can show
# % + ETA, not just a counter.
PV=(cat)
if command -v pv >/dev/null 2>&1; then
    PV=(pv -s "$expected_bytes")
else
    warn "pv not found — no progress bar. pkg/apt install pv to get one."
fi

# ---- collect the passphrase BEFORE anything moves ----------------------------
# One prompt pair, then the pipeline and the verification both run
# unattended — start the backup, walk away.
gpg_seal()   { gpg --batch --yes --pinentry-mode loopback --passphrase-fd 3 \
                   --symmetric --cipher-algo AES256 -o "$1" 3< <(printf '%s' "$PASSPHRASE"); }
gpg_unseal() { gpg --batch --quiet --pinentry-mode loopback --passphrase-fd 3 \
                   -d "$1" 3< <(printf '%s' "$PASSPHRASE"); }
if [ "$ENCRYPT" -eq 1 ]; then
    log "choose a backup passphrase — save it to your password manager NOW;"
    log "without it the backup is unrecoverable"
    while :; do
        read -rs -p "  passphrase: " PASSPHRASE < /dev/tty; echo
        read -rs -p "  confirm:    " confirm < /dev/tty; echo
        if [ -z "$PASSPHRASE" ]; then warn "empty passphrase — try again"
        elif [ "$PASSPHRASE" != "$confirm" ]; then warn "mismatch — try again"
        else break; fi
    done
    unset confirm
fi

# ---- backup -----------------------------------------------------------------
mkdir -p "$LOCAL_DIR"
real_size=$(adb shell run-as "$PKG" du -h files/storage.img | awk '{print $1}')
stamp="$(date +%F-%H%M)"
out="$LOCAL_DIR/podroid-vm-${stamp}.${EXT}"
[ "$ENCRYPT" -eq 1 ] && out="${out}.gpg"

log "streaming storage.img (${real_size} real data) + datastore from $PKG"
log "→ $out"
# `adb shell -T` (not exec-out): the v2 shell protocol keeps stdout
# binary-safe AND propagates the device-side exit code, so a tar that
# dies mid-stream fails the pipeline instead of sealing a truncated
# backup. exec-out's raw exec service always exits 0 locally.
#
# `< /dev/null` matters: adb shell forwards local stdin to the remote,
# which would otherwise eat keyboard input meant for the terminal.
if [ "$ENCRYPT" -eq 1 ]; then
    adb shell -T run-as "$PKG" tar -cS -C files storage.img datastore </dev/null \
        | "${PV[@]}" | "${COMPRESS[@]}" | gpg_seal "$out"
    chmod 600 "$out"
else
    log "(UNENCRYPTED — contains everything inside your VM)"
    adb shell -T run-as "$PKG" tar -cS -C files storage.img datastore </dev/null \
        | "${PV[@]}" | "${COMPRESS[@]}" > "$out"
fi

# ---- end-to-end verification ------------------------------------------------
# Decrypt + decompress the sealed file and PARSE the inner tar to its
# end-of-archive marker. A stream truncated by Android reaping the
# device-side tar (phantom-process / memory-pressure kills) fails the
# parse with "unexpected EOF"; a complete one lists every member. We
# additionally assert storage.img carries its full apparent size — the
# exact length the app's size check demands on restore. Byte-count
# comparison against du is deliberately NOT used: tar legitimately
# hole-skips allocated-but-zero blocks, so streamed size < du size on
# every healthy backup. Runs unattended (passphrase already in hand).
case "$EXT" in
    tar.zst) DECOMP=(zstd -dc) ;;
    tar.gz)  DECOMP=(gzip -dc) ;;
esac
log ""
log "verifying backup end-to-end (structural tar parse)"
vfail=0
if [ "$ENCRYPT" -eq 1 ]; then
    listing=$(gpg_unseal "$out" | "${DECOMP[@]}" | tar -tvf -) || vfail=$?
else
    listing=$("${DECOMP[@]}" "$out" | tar -tvf -) || vfail=$?
fi
if [ "$vfail" -ne 0 ]; then
    err "✗ VERIFICATION FAILED: the inner tar stream doesn't parse to its"
    err "  end-of-archive marker — the backup is TRUNCATED (device-side tar"
    err "  was likely killed mid-stream). Delete this file and re-run."
    exit 1
fi
if ! printf '%s\n' "$listing" | grep -q "storage\.img" \
   || ! printf '%s\n' "$listing" | grep -q "[^0-9]${img_bytes}[^0-9]"; then
    err "✗ VERIFICATION FAILED: storage.img missing or wrong apparent size."
    err "  Expected ${img_bytes} bytes. Archive listing:"
    printf '%s\n' "$listing" >&2
    exit 1
fi
log "✓ verified — archive parses cleanly, storage.img carries its full ${img_bytes}-byte size"

log "done — $(du -h "$out" | awk '{print $1}')"
log ""
log "restore with:  bash $CLIENT_DIR/10-restore-podroid-vm.sh $out"
