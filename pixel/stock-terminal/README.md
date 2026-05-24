# Stock Terminal — GPU-accelerated GUI host

The graphical half of the hybrid Pixel setup. The Stock Linux Terminal
app is a privileged system component on Android 16 — it talks directly
to the Tensor GPU via the AVF's `virtio-gpu` + Zink/Vulkan pipeline, so
everything rendered inside its Debian VM gets real hardware
acceleration.

Compute lives in [`../podroid/`](../podroid/) — Docker, code, sesh, all
in the Ubuntu LXC. **The Stock Terminal does not run any of that.** Its
only job is to host the GUI: sway (Wayland tiling WM), foot (terminal),
firefox (browser). From inside sway you `ssh user@pixel-dev` over
Tailscale into the LXC for actual work.

## Step 1 — Enable hardware acceleration (one-time)

The Stock Terminal VM only initializes its 3D pipeline if a marker file
exists in Android's shared storage. Without it you get llvmpipe
(software rendering, ~20–30 FPS).

1. Pair ADB. Easiest is wireless, via Termux on the same phone:

   ```sh
   # In Termux:
   pkg update && pkg install android-tools -y
   ```

   Then on the phone: Settings → System → Developer options → **Wireless
   debugging** → tap "Pair device with pairing code" (keep that popup
   visible — Android resets the pairing port if you leave the screen).

   Use Android's split-screen view to keep both Settings and Termux on
   screen at once. In Termux:

   ```sh
   adb pair localhost:<PAIRING_PORT>
   # enter the 6-digit code
   adb connect localhost:<MAIN_PORT>   # different port shown on the main page
   ```

2. Create the marker file:

   ```sh
   adb shell "mkdir -p /sdcard/linux"
   adb shell "touch /sdcard/linux/virglrenderer"
   ```

3. Force-stop both `Android Virtualization Framework` and `Terminal`
   in Settings → Apps → See all apps (enable "Show system" from the
   3-dot menu). Open the Terminal app again.

4. Verify inside the Terminal's Debian shell:

   ```sh
   sudo apt update && sudo apt install -y mesa-utils
   glxinfo | grep "OpenGL renderer"
   ```

   Expected output: **`zink Vulkan 1.3`**. (Older Android builds show
   `VirtIO-GPU` or a `VirGL is enabled` toast — same effect, just an
   older driver path.) If it says `llvmpipe`, the marker file isn't
   being seen; double-check the path, the force-stop, and that no
   `.txt` extension snuck onto the filename.

## Step 2 — Install the GUI

Inside the Stock Terminal's Debian shell:

```sh
curl -fsSL https://raw.githubusercontent.com/rynobey/linux-setups/master/bootstrap-git.sh | bash
cd ~/projects/linux-setups
./pixel/stock-terminal/install-gui.sh
```

What this installs:

- **sway** — Wayland tiling WM, i3-compatible keybinds, native zink path
- **foot** — fast Wayland terminal (smaller and faster than alacritty
  for this use case)
- **firefox** — desktop browser; runs fine on the LXC-side compute
  proxy via SSH socks if you want isolation, or just locally for
  general browsing

A minimal `~/.config/sway/config` is installed if you don't already
have one — it sets `Mod4` (Super) as the modifier, opens foot on
`Mod+Return`, and runs `connect-dev.sh` on `Mod+Shift+Return` (drops
you straight into an SSH session on the LXC).

## Step 3 — Day-to-day

Launch sway from a Stock Terminal shell:

```sh
sway
```

The Stock Terminal window switches to the sway session. Keybinds:

| Key | Action |
|---|---|
| `Mod + Return` | new local foot terminal |
| `Mod + Shift + Return` | new foot terminal already ssh'd into pixel-dev (LXC) |
| `Mod + d` | dmenu (or `Mod + space` depending on default) |
| `Mod + h/v` | next window splits horizontal/vertical |
| `Mod + f` | full-screen current window |
| `Mod + Shift + q` | close current window |
| `Mod + Shift + e` | exit sway (back to Stock Terminal shell) |

For an external monitor: plug your Pixel into HDMI/DisplayPort. Android
16 Desktop Mode picks up the external display automatically. The Stock
Terminal sway window scales to the monitor's resolution.

## `connect-dev.sh` quick reference

```sh
./connect-dev.sh              # opens foot, ssh user@pixel-dev
./connect-dev.sh --host alt   # ssh user@alt instead
DEV_USER=other ./connect-dev.sh
```

Defaults to `$USER@pixel-dev`; override via `DEV_USER` / `DEV_HOST` env
or `--host` flag. Bound to `Mod + Shift + Return` in the shipped sway
config.

## Why not run sway *inside* the LXC and forward to here?

You could `ssh -Y` sway-or-i3 from the LXC and render its X clients on
an X server inside the Stock Terminal — that's what the earlier draft
of this setup proposed. But:

- Sway is Wayland-only; `ssh -Y` is X11. You'd need `waypipe` or fall
  back to i3.
- Even with i3, X11 forwarding adds latency on every paint and loses
  GPU-accelerated compositing.
- It's two display servers to debug instead of one.

Keeping sway on the GPU side (here) and the LXC strictly headless is
the cleaner split. The handful of "I need the GUI to see my server"
cases (e.g. opening `localhost:3000` from a Docker container in the
LXC) are solved with an SSH local-forward inside the foot terminal
session, not by forwarding a display.
