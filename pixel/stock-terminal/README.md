# Stock Terminal — GPU-accelerated GUI host

The graphical half of the hybrid Pixel setup. The Stock Linux Terminal
app is a privileged system component on Android 16 — it talks directly
to the Tensor GPU via the AVF's `virtio-gpu` + Zink/Vulkan pipeline, so
everything rendered inside its Debian VM gets real hardware
acceleration.

Compute lives in [`../podroid/`](../podroid/) — Docker, code, sesh, all
in the Ubuntu LXC. **The Stock Terminal does not run any of that.** Its
only job is to host the GUI: sway (Wayland tiling WM), foot (terminal),
firefox (browser). From inside sway you `ssh user@pubuntu` over
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
| `Mod + Shift + Return` | new foot terminal already ssh'd into pubuntu (LXC) |
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
./connect-dev.sh              # opens foot, ssh user@pubuntu
./connect-dev.sh --host alt   # ssh user@alt instead
DEV_USER=other ./connect-dev.sh
```

Defaults to `$USER@pubuntu`; override via `DEV_USER` / `DEV_HOST` env
or `--host` flag. Bound to `Mod + Shift + Return` in the shipped sway
config.

## Backup / restore

The Stock Terminal VM disk image lives in app-private storage
(`/data/user/0/com.android.virtualization.terminal/files/`), unreachable
without root. So unlike `pixel/podroid/backup.sh` (which tars the whole
LXC rootfs from outside), the Stock Terminal scripts run **inside the
VM itself** and tar **selected paths** to a known directory on the
VM's persistent disk. Durability is then handled by pulling those
tarballs out via ssh+scp — `sync-backups.sh` does this from any
external host.

> **⚠ Backups inside the VM are not durable on their own.**
> `/var/lib/stock-terminal-backups/` survives Stock Terminal VM
> reboots, but lives inside the app sandbox — wiped if the Stock
> Terminal app is uninstalled or its data is cleared. The actual
> durability layer is `sync-backups.sh` pulling them onto your
> laptop / iPad / Termux session / wherever.
>
> Earlier versions of these scripts wrote to `/mnt/shared/` on the
> assumption that AVF's SharedPath into `/sdcard/` would expose
> backups to Android directly. On current Pixel 10 / Android 16
> firmware that SharedPath is silently dropped for non-system
> contexts, so the design was simplified: write locally, ship out
> via scp.

### What's preserved

| ✔ Kept | ✘ Lost |
|---|---|
| `$HOME` + `/root` (dotfiles, sway/foot configs, projects) | The rest of the rootfs (system tweaks outside the named paths) |
| `/etc/sway`, `/etc/foot`, `/etc/cloud` | `/var` data (logs, apt cache, etc.) |
| `/usr/local/bin` (the installed `connect-dev`) | Custom systemd units (not in default paths — add to `BACKUP_PATHS`) |
| List of apt-installed packages (replayed on restore) | The packages' on-disk state — only the names are kept |

Tune the paths with the `BACKUP_PATHS` env (space-separated). The
default is `$HOME /root /etc/sway /etc/foot /etc/cloud /usr/local/bin`.

### Make a backup

```sh
# inside the Stock Terminal VM:
./pixel/stock-terminal/backup.sh                # encrypted (age -p), default
./pixel/stock-terminal/backup.sh --plain        # unencrypted .tar.gz
./pixel/stock-terminal/backup.sh --list         # show existing
```

Backups land at `/var/lib/stock-terminal-backups/` as
`stock-terminal-<timestamp>.tar.gz.age`. The `age` package is
installed on demand. Multiple snapshots accumulate; prune manually.

The **`stock-terminal-`** filename prefix is deliberate: if you
collect backups from this VM and from Podroid LXCs onto the same
laptop, the prefixes (`stock-terminal-*` vs `pubuntu-*`) keep them
visually distinct and let `sync-backups.sh --push` filter for
the right kind.

### Restore

```sh
./pixel/stock-terminal/restore.sh                       # interactive picker
./pixel/stock-terminal/restore.sh --latest              # newest, no prompt
./pixel/stock-terminal/restore.sh <path-to-tarball>     # specific file
./pixel/stock-terminal/restore.sh --skip-packages       # untar only, no apt replay
```

Restore does two things:

1. Untars the snapshot into `/`, overwriting current files in the
   backed-up paths.
2. Re-runs `apt-get` to install everything in the saved package list.

Cleanest results on a freshly-installed Stock Terminal VM. Restoring
over a heavily-customised existing VM works but only the explicitly
backed-up paths get overwritten — leftover system changes outside
those paths stay.

Encrypted backups re-prompt for the passphrase used at backup time.

### Durable storage via sync-backups.sh (any external host)

`sync-backups.sh` runs **anywhere ssh+scp is available** — laptop,
Termux on the Pixel itself, iPad with a-Shell, another phone, a
NAS, your friend's machine. It's pure ssh + scp with no
platform-specific dependencies.

Prereqs (one-time):

1. `sudo apt install -y openssh-server` inside the Stock Terminal VM
   so it has sshd listening.
2. Reachability — either install Tailscale inside the VM (`curl -fsSL
   https://tailscale.com/install.sh | sh && sudo tailscale up
   --hostname=stock-terminal`), or set up port-forwarding from
   Android, or be on the same LAN with a known IP.

Then:

```sh
# Default — pull all backups from the Stock Terminal VM to ~/stock-terminal-backups/:
./pixel/stock-terminal/sync-backups.sh

# List what's on the VM without downloading:
./pixel/stock-terminal/sync-backups.sh --list-remote

# Push backups back to the VM (for restore):
./pixel/stock-terminal/sync-backups.sh --push --local ~/stock-terminal-backups

# Different host (Tailscale IP, custom port):
./pixel/stock-terminal/sync-backups.sh --host 100.83.12.4
./pixel/stock-terminal/sync-backups.sh --host phone.local --port 2222

# After pulling, free space on the VM:
./pixel/stock-terminal/sync-backups.sh --delete-after
```

Defaults: `droid@stock-terminal` on port 22, remote
`/var/lib/stock-terminal-backups`, local `~/stock-terminal-backups`.
Override via flags or `DEV_HOST` / `DEV_PORT` / `DEV_USER` /
`REMOTE_DIR` / `LOCAL_DIR` env vars.

### Running from Termux on the Pixel itself

A nice property of the pure-ssh design: when no laptop is handy,
you can pull backups *to the Pixel's own storage* (outside the Stock
Terminal app sandbox) right from the phone:

```sh
# in Termux on the Pixel:
pkg install openssh
git clone https://github.com/rynobey/linux-setups.git
cd linux-setups
LOCAL_DIR=~/storage/downloads/stock-terminal-backups \
    ./pixel/stock-terminal/sync-backups.sh --host stock-terminal
```

Termux's `~/storage/downloads/` maps to Android's `/sdcard/Download/`,
which is public Android storage — survives Stock Terminal app
uninstall. From there you can pull to a laptop later via `adb pull`,
upload to a cloud service, whatever.

### Survival matrix

| Event | VM rootfs | VM /var/lib/stock-terminal-backups | Laptop ~/stock-terminal-backups |
|---|---|---|---|
| VM rebooted | ✅ kept | ✅ kept | ✅ kept |
| Stock Terminal app restarted | ✅ kept | ✅ kept | ✅ kept |
| Stock Terminal "Clear data" | ❌ wiped | ❌ wiped | ✅ kept |
| Stock Terminal uninstalled | ❌ wiped | ❌ wiped | ✅ kept |
| Android factory reset | ❌ wiped | ❌ wiped | ✅ kept |
| Laptop disk fails | ❌ wiped | (irrelevant) | ❌ wiped |

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
