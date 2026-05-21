# Pixel 10 AVF Linux + Dual-VNC Setup

Sets up a Debian Linux environment on a Pixel 10 using Android's built-in
**Linux Terminal** (AVF / crosvm) with two TigerVNC sessions bridged by
Input Leap, so the Pixel is the primary display and an iPad acts as a
passive secondary display driven by the Pixel's keyboard/mouse.

## What you get

- Debian VM running via AVF, with a real Linux kernel and userspace
- XFCE desktop, lightweight enough for a phone SoC
- TigerVNC session `:1` on port `5901` — the Pixel's display
- TigerVNC session `:2` on port `5902` — the iPad's display
- Input Leap (or Barrier, depending on Debian version) bridging the two
  sessions: cursor crosses the right edge of `:1` into `:2`, keyboard/mouse
  stay attached to the Pixel only
- Two helper commands: `vnc-start` and `vnc-stop`

No audio over the VNC link — that's by design (see notes).

## Prerequisites

- Pixel 10 running Android 16
- ~32 GB of free internal storage you can dedicate to the VM
- Developer options enabled (Settings → About phone → tap Build number 7×)
- A VNC client on each device:
  - **Pixel:** RealVNC Viewer or bVNC from Play Store
  - **iPad:** RealVNC Viewer or Jump Desktop from App Store

## Step 1 — Enable the Linux Terminal in Android

1. Settings → System → Developer options
2. Find "Linux development environment" (or "Linux terminal") and enable it
3. Open the **Terminal** app that appears in your launcher
4. Before first boot, open the app's settings and **set the disk size to 32 GB
   or more**. Resizing later is awkward; size generously now.
5. Tap to boot the VM. First boot downloads the Debian image (a few hundred MB).
6. When ready, you'll land at a `droid@localhost:~$` shell.

## Optional — Bootstrap SSH so you can drive the rest from a laptop

Typing the rest of the install on the Pixel's on-screen keyboard is no fun.
If you'd rather complete everything over SSH from a desktop, do this once on
the phone (small enough to type or paste in):

```bash
sudo apt update
sudo apt install -y openssh-server

mkdir -p ~/.ssh && chmod 700 ~/.ssh
# Paste your laptop's public key (cat ~/.ssh/id_ed25519.pub on the laptop)
# on a single line, save with Ctrl-O, exit with Ctrl-X:
nano ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys

sudo systemctl enable --now ssh
```

Then expose port 22 so your laptop can reach it. Pick one path:

**Easier — Tailscale (works from anywhere, no port forwarding):**

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up           # follow the auth URL on the phone
tailscale ip -4              # note this IP
```

On your laptop (also on the tailnet):
`ssh droid@<tailnet-ip>` — you're in.

**Or — AVF port forward + Termux socat (LAN only):**

1. In the **Terminal** app on Android: Settings → Forward ports, add guest
   `22` → host `2222`.
2. In Termux: `pkg install socat` then
   `socat TCP-LISTEN:2222,fork,reuseaddr TCP:127.0.0.1:2222 &`
3. From laptop: `ssh -p 2222 droid@<pixel-wifi-ip>`

Once SSH works, you can run the rest of the steps from your laptop, and use
`scp` or `git clone` (next step) instead of the shared folder dance.

## Step 2 — Get this folder into the VM

Pick whichever fits how you bootstrapped:

**Via SSH from your laptop** (assumes you did the optional step above):

```bash
# Run from your laptop, in the directory above android-linux-setup/
scp -r android-linux-setup droid@<tailnet-or-wifi-ip>:~/
# Or, if you've pushed it to git:
ssh droid@<host> 'git clone <your-url>'
```

**Via the shared folder** (Pixel-only workflow):

The AVF terminal mounts a folder that maps to an Android directory
(typically `/mnt/shared` inside the VM, backed by `/storage/emulated/0/AVF/`
on Android).

1. Copy this folder onto the Pixel's storage (USB cable, Google Drive, or
   any method you like) so it appears under `/storage/emulated/0/AVF/`.
2. From inside the VM:
   ```bash
   cp -r /mnt/shared/android-linux-setup ~/
   cd ~/android-linux-setup
   ```

## Step 3 — Run the setup script

```bash
bash setup-avf-vnc.sh
```

What it does:

- `apt update && apt install` for XFCE, TigerVNC, Input Leap (or Barrier),
  Firefox ESR, and a handful of supporting packages
- Prompts you to set a VNC password (used for both sessions)
- Writes a VNC `xstartup` that launches XFCE
- Writes an Input Leap / Barrier server config with two screens
  (`pixel` left, `ipad` right)
- Drops `vnc-start` and `vnc-stop` helpers into `~/bin/`
- Appends `~/bin` to your `PATH` in `.bashrc`

Safe to re-run; it skips steps that are already done.

## Step 4 — Forward ports from the VM to Android

In the **Terminal** app on Android:

1. Open the app's settings → **Forward ports** (or equivalent menu)
2. Add:
   - Guest port `5901` → Host port `5901`
   - Guest port `5902` → Host port `5902`
   - Guest port `24800` → Host port `24800` *(only needed if you ever want
     to debug Input Leap from outside the VM; can skip otherwise)*

That makes the VNC servers reachable on the Pixel itself at
`localhost:5901` and `localhost:5902`.

## Step 5 — Make the iPad able to reach the VM

The hard part. The AVF port-forwarding above exposes the VNC servers on
Android's **localhost only**, not on the Wi-Fi interface. There are two
ways to bridge this gap to the iPad:

### Option A — Tailscale (recommended)

Install Tailscale **inside the VM**:

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
```

Authenticate, then on the iPad install the Tailscale app and join the same
tailnet. The iPad can now reach the VM directly at its tailnet IP
(`100.x.y.z:5902`). No port forwarding, no LAN gymnastics, and it works
from anywhere — not just at home.

### Option B — socat bridge via Termux

If you have Termux installed and don't want Tailscale:

```bash
pkg install socat
socat TCP-LISTEN:5902,fork,reuseaddr TCP:127.0.0.1:5902 &
```

That rebroadcasts the forwarded port on the Pixel's Wi-Fi interface so the
iPad can hit `<pixel-wifi-ip>:5902`.

## Step 6 — Connect the clients

1. On the Pixel, run inside the VM:
   ```bash
   vnc-start
   ```
2. Open RealVNC Viewer on the Pixel → connect to `localhost:5901` → enter
   the VNC password. You should see the XFCE desktop on `:1`.
3. Open RealVNC Viewer on the iPad → connect to either the tailnet IP or
   the Wi-Fi IP on `:5902`. **Set the iPad viewer to view-only mode** so
   stray taps don't generate input.
4. Move your cursor off the right edge of the Pixel screen. It should
   appear on the iPad. Drag a window across to confirm.

## Step 7 — Day-to-day

```bash
vnc-start    # start both sessions + Input Leap
vnc-stop     # stop everything cleanly
```

The sessions persist across client disconnects — close the viewer, come
back later, your desktop is exactly where you left it. The sessions
themselves only need restarting if you reboot the VM or run `vnc-stop`.

## Customising

Edit `~/bin/vnc-start` to change:

- `PIXEL_GEOMETRY` — defaults to `1920x1080`
- `IPAD_GEOMETRY` — defaults to `2048x1536`. Match to your iPad model for
  best results (iPad Pro 12.9" is `2732x2048`; standard iPad is `2160x1620`)
- Input Leap layout (left/right) — edit `~/.config/barrier/barrier.conf` or
  `~/.config/input-leap/input-leap.conf`

## Notes

### Audio

VNC carries no audio. For media playback, either play in an Android-side
app (browser, music apps) with Bluetooth headphones paired to the Pixel,
or set up Sunshine + Moonlight on a separate port for those specific
moments. Not included in this script.

### Backups

This script does not configure backups. The AVF VM image lives in the
Terminal app's private storage and is **not directly accessible from
Android** without root, so back up from inside the VM. Suggested:

```bash
sudo apt install restic rclone
# Set up restic with a remote target (B2, S3, your NAS over Tailscale, etc.)
# Schedule with a systemd timer
```

Clearing the Terminal app's data in Android Settings will destroy the
entire VM with no recovery — off-device backups are mandatory, not
optional.

### Termux ↔ AVF

Both can coexist. Termux is good for quick Android-side shell tasks; the
AVF VM is your real Linux environment. Bridge them with SSH (Termux sshd
on port 8022, AVF sshd on port 22 forwarded to Android 2222), or put both
on Tailscale and forget about the NAT.

### Why no Sunshine for the main setup

Sunshine would give smoother motion and audio, but inside the AVF VM it
likely falls back to software H.264 encoding (no reliable hardware-encoder
passthrough on Pixel 10 yet). Software encoding burns Pixel battery and
risks thermal throttling. TigerVNC is lightweight and pixel-perfect for
the terminal-heavy workload this setup targets.
