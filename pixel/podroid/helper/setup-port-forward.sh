#!/usr/bin/env bash
# Set up an external→LXC port forward on Podroid. Run ON THE ALPINE HOST
# (typically via pixel/client/helper/alpine-run.sh from a laptop).
#
# Use case: make a service inside an LXC (e.g. pubuntu's sshd) reachable
# from outside the Pixel on a chosen port. Default values:
#
#   <External>:9923 (TCP)  →  pubuntu's sshd on 22
#
# After running this, also enable the matching port in the Podroid app's
# UI (Settings → Port forwarding → Add: TCP <HOST_PORT>) so the Android
# side actually listens on it.
#
# Idempotent — safe to re-run with the same params or with different
# HOST_PORT/CONTAINER_PORT for additional forwards.
#
# ── How Podroid port forwarding actually works ──────────────────────────────
#
# IMPORTANT MENTAL MODEL — not the typical TCP→TCP NAT chain:
#
#   [outside]    ssh -p 9923 user@pixel
#                  │
#                  ▼ (Podroid Android-app TCP listener on 0.0.0.0:9923)
#   [Pixel]     Android TCP:9923
#                  │
#                  ▼ (VsockPortForwarder splices TCP ↔ vsock 1:1 by port)
#   [Alpine]    AF_VSOCK port 9923
#                  │
#                  ▼ (podroid-vsock-agent reads /etc/podroid/forwards.conf)
#   [Alpine]    splice vsock → TCP <host>:<gport> per the conf line
#                  │
#                  ▼
#   [LXC]       <STATIC_IP>:<CONTAINER_PORT>  (e.g. pubuntu sshd at 10.0.3.20:22)
#
# Notes:
#   - Packets arrive at Alpine via AF_VSOCK, NOT via the IP stack. iptables
#     NAT/PREROUTING rules on Alpine never see them. Don't bother with DNAT.
#   - The Podroid Android app maps hostPort ↔ vsockPort 1:1 by convention,
#     so this script uses the same number for both.
#   - The agent reads forwards.conf at startup. Restart it after edits.
#     (kill -HUP TERMINATES the agent — no reload handler. Use rc-service.)
#
# ── Env overrides ────────────────────────────────────────────────────────────
#   LXC_NAME         default: pubuntu
#   STATIC_IP        default: 10.0.3.20      (assigned via netplan in the LXC)
#   GATEWAY          default: 10.0.3.1       (Alpine's lxcbr0)
#   HOST_PORT        default: 9923           (= vsock port on the guest side)
#   CONTAINER_PORT   default: 22
#   SKIP_STATIC_IP   default: 0              set 1 if the LXC already has its IP

set -euo pipefail

LXC_NAME="${LXC_NAME:-pubuntu}"
STATIC_IP="${STATIC_IP:-10.0.3.20}"
GATEWAY="${GATEWAY:-10.0.3.1}"
HOST_PORT="${HOST_PORT:-9923}"
CONTAINER_PORT="${CONTAINER_PORT:-22}"
SKIP_STATIC_IP="${SKIP_STATIC_IP:-0}"
FORWARDS_CONF="/etc/podroid/forwards.conf"

log()  { printf '\033[1;34m[port-forward]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; }

# ── sanity ──────────────────────────────────────────────────────────────────
if [ ! -d "/var/lib/lxc/$LXC_NAME" ]; then
    err "LXC '$LXC_NAME' doesn't exist on this Alpine host"
    err "(/var/lib/lxc/$LXC_NAME not found)"
    exit 1
fi
if [ ! -f "$FORWARDS_CONF" ]; then
    err "$FORWARDS_CONF not found — is podroid-vsock-agent installed?"
    exit 1
fi

# ── 1. Static IP for the LXC via netplan ────────────────────────────────────
# We deploy a netplan file into the LXC's rootfs from outside (Alpine has
# direct access to the rootfs). Then run `netplan apply` inside the LXC.
#
# Why not DHCP reservation in dnsmasq? Tried it, doesn't work — Ubuntu noble's
# systemd-networkd sends DHCP option 81 (FQDN) but not option 12 (hostname),
# while `dhcp-host=name,IP` matches option 12. So hostname-based reservation
# silently doesn't take effect on the recent Ubuntu releases. MAC-based works
# but breaks on every LXC rebuild (new MAC). Netplan inside the LXC is the
# only robust option that survives backup/restore (the file is part of the
# rootfs tarball).
ROOTFS="/var/lib/lxc/$LXC_NAME/rootfs"
NETPLAN_FILE="$ROOTFS/etc/netplan/99-static-podroid.yaml"
DESIRED_NETPLAN=$(cat <<EOF
# Managed by pixel/podroid/helper/setup-port-forward.sh
# Re-running the script overwrites this file.
network:
  version: 2
  ethernets:
    eth0:
      dhcp4: false
      addresses: [$STATIC_IP/24]
      routes:
        - to: default
          via: $GATEWAY
      nameservers:
        addresses: [$GATEWAY, 1.1.1.1]
EOF
)

if [ "$SKIP_STATIC_IP" = "1" ]; then
    log "[1/3] SKIP_STATIC_IP=1 — leaving the LXC's IP untouched"
elif [ -f "$NETPLAN_FILE" ] && [ "$(sudo cat "$NETPLAN_FILE")" = "$DESIRED_NETPLAN" ]; then
    log "[1/3] netplan static IP ($STATIC_IP) already in place — skipping"
else
    log "[1/3] writing netplan static IP $STATIC_IP into $LXC_NAME"
    sudo mkdir -p "$(dirname "$NETPLAN_FILE")"
    printf '%s\n' "$DESIRED_NETPLAN" | sudo tee "$NETPLAN_FILE" >/dev/null
    sudo chmod 600 "$NETPLAN_FILE"
    log "      applying netplan inside the LXC"
    sudo lxc-attach -n "$LXC_NAME" -- netplan apply 2>&1 | sed 's/^/      /' || \
        warn "      netplan apply reported errors — check above"
    sleep 2
    sudo lxc-attach -n "$LXC_NAME" -- ip -4 -o addr show eth0 | sed 's/^/      /'
fi

# ── 2. Add the forwards.conf entry for this port ────────────────────────────
DESIRED_LINE="$HOST_PORT tcp $STATIC_IP $CONTAINER_PORT"
log "[2/3] forwards.conf entry: $DESIRED_LINE"

if sudo grep -qxF "$DESIRED_LINE" "$FORWARDS_CONF"; then
    log "      already present — no change"
elif sudo grep -qE "^${HOST_PORT}[[:space:]]+" "$FORWARDS_CONF"; then
    # An older/different line for this port exists; replace it.
    OLD_LINE=$(sudo grep -E "^${HOST_PORT}[[:space:]]+" "$FORWARDS_CONF")
    log "      replacing existing line for port $HOST_PORT"
    log "        was: $OLD_LINE"
    log "        now: $DESIRED_LINE"
    sudo sed -i "s|^${HOST_PORT}[[:space:]].*|${DESIRED_LINE}|" "$FORWARDS_CONF"
else
    log "      appending new line"
    echo "$DESIRED_LINE" | sudo tee -a "$FORWARDS_CONF" >/dev/null
fi

# ── 3. Restart podroid-vsock so the agent reads the new forwards.conf ───────
#
# WARNING — if you're running this via SSH that's relayed through the agent
# (e.g. the standard `ssh -p 9922 root@<pixel>` path which goes through the
# agent for vsock 9922 → 22), THIS RESTART WILL DROP YOUR SESSION. The agent
# will come back up (OpenRC supervises it) and you can SSH again, but the
# current shell will reset.
#
# When invoked via alpine-run.sh from a client, that's exactly the path it's
# using, so the script's final logs may not make it back. The change DOES
# take effect — confirm from the laptop with a fresh SSH after.
log "[3/3] restarting podroid-vsock (your SSH session may drop here)"
sudo rc-service podroid-vsock restart >/dev/null 2>&1 || \
    warn "      rc-service restart failed — agent may not be controlled by OpenRC"

sleep 2

# If we still have the shell, dump status.
log "      agent processes after restart:"
pgrep -af podroid-vsock-agent | head -8 | sed 's/^/        /' || true

# ── Final banner ────────────────────────────────────────────────────────────
cat <<EOF

==============================================================
Vsock forward configured:
   <Pixel>:$HOST_PORT (TCP)  →  vsock:$HOST_PORT (Alpine)
                            →  $STATIC_IP:$CONTAINER_PORT (LXC '$LXC_NAME')

▶ ONE-TIME: enable the matching forward in the Podroid app:
   Settings → Port forwarding → Add: TCP $HOST_PORT
   (Without this, the Android side won't listen on $HOST_PORT and
    nothing outside the Pixel can reach the new forward.)

Test from any LAN machine:
  ssh -p $HOST_PORT ryno@<pixel-lan-ip>

Test from Termux on the phone (loopback to the Podroid listener):
  ssh -p $HOST_PORT ryno@localhost

To revert later:
  sudo sed -i "/^$HOST_PORT[[:space:]]/d" $FORWARDS_CONF
  sudo rc-service podroid-vsock restart
  # Remove static IP (optional — only if no other forward needs it):
  sudo rm $NETPLAN_FILE
  sudo lxc-attach -n $LXC_NAME -- netplan apply
==============================================================
EOF
