# Pixel 10 AVF Linux — headless SSH setup

Sets up a Debian Linux environment on a Pixel 10 using Android's built-in
**Linux Terminal** (AVF / crosvm), accessed exclusively over SSH from a
laptop, desktop, or Android-side terminal app (Termux, Termius, etc.) via
Tailscale.

No VNC, no GUI, no extended-display nonsense. Just a real Debian box that
happens to live on a phone.

## What you get

- Debian (currently trixie) running in a VM via AVF
- Reachable from any device on your tailnet at `pixel-avf:22`
- Key-only SSH, no inbound LAN exposure, no AVF port forwarding
- Optional non-default user (`create-user.sh`)

## Prerequisites

- Pixel 10 running Android 16
- Developer options enabled (Settings → About phone → tap Build number 7×)
- Tailscale set up on your laptop / iPad / other devices already (so
  there's a tailnet to join). Free tier is fine.

## Step 1 — Enable the Linux Terminal in Android

1. Settings → System → Developer options
2. Find "Linux development environment" (or "Linux terminal") and enable it
3. Open the **Terminal** app that appears in your launcher
4. Tap to boot the VM. First boot downloads the Debian image
   (a few hundred MB).
5. When ready, you'll land at a `droid@localhost:~$` shell.

> **Disk size:** on current Pixel 10 / Android 16 builds the VM's root
> filesystem is generously sized (~200 GB, shared with the phone's
> internal storage) — no pre-boot resize needed. Verify with `df -h`.

## Step 2 — Bootstrap SSH access via Tailscale

The Pixel's on-screen keyboard is only used for this short bootstrap;
everything else runs over SSH. Tailscale handles the networking so you
don't need AVF port forwarding.

> **Heads-up:** the AVF Terminal app on current Pixel 10 builds has **no
> clipboard access** — you can't paste a public key in. The flow below
> avoids paste by using `ssh-copy-id` from your laptop after a one-time
> password-auth window.

### 2a — (Optional) Create your own user

The AVF default user is `droid`. You can keep using it, or create one
matching your preferred username:

```bash
sudo useradd -m -s /bin/bash <username>
sudo usermod -aG sudo <username>
sudo passwd <username>            # set its password
su - <username>                   # switch into it for everything below
```

The new user **must be in the `sudo` group** — the rest of this setup
relies on sudo for apt and systemctl. Root login is left disabled by
design; use `sudo` (or `sudo -i` for an interactive root shell) instead.

Anywhere this README says `<user>`, substitute whichever you're using
(`droid` or the new one).

Once the repo is on the VM (Step 3 onward), you can also use
[`create-user.sh`](create-user.sh) — an interactive wrapper that
validates the username, prompts for sudo membership and shell, and sets
the password.

### 2b — Install sshd, enable password auth temporarily, set a password

```bash
# Set/refresh the password on the current user
passwd

sudo apt update
sudo apt install -y openssh-server curl

# Allow password auth just long enough to copy our key over
sudo sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' \
    /etc/ssh/sshd_config
sudo systemctl enable --now ssh
sudo systemctl restart ssh
```

### 2c — Install Tailscale and join your tailnet

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
```

If the auth URL the command prints isn't tappable in the terminal,
pre-generate an **auth key** at
[login.tailscale.com/admin/settings/keys](https://login.tailscale.com/admin/settings/keys)
and use it instead:

```bash
sudo tailscale up --auth-key=tskey-auth-...
```

Rename the device to `pixel-avf` in the admin console
([login.tailscale.com/admin/machines](https://login.tailscale.com/admin/machines))
so MagicDNS gives you a memorable hostname.

### 2d — From the laptop: copy your key over and verify

Your laptop needs to be on the same tailnet (install Tailscale there too
if you haven't). Then:

```bash
ssh-copy-id <user>@pixel-avf
# Enter the password from step 2b. Pubkey lands in authorized_keys.

ssh <user>@pixel-avf
# Should log in *without* prompting for a password.
```

### 2e — Disable password auth

With key-based login confirmed, lock SSH down to keys only. From your
laptop's SSH session:

```bash
sudo sed -i 's/^PasswordAuthentication.*/PasswordAuthentication no/' \
    /etc/ssh/sshd_config
sudo systemctl restart ssh
exit
ssh <user>@pixel-avf    # reconnect to verify key-only login still works
```

You're done with the phone keyboard.

## Step 3 — Day-to-day

```bash
ssh <user>@pixel-avf
# from here, it's a regular Debian box. apt, systemd, tmux, whatever.
```

A few practical patterns:

- **Persistent sessions** — use `tmux` or `screen` so work survives
  reconnects and intermittent phone connectivity:
  ```bash
  sudo apt install -y tmux
  tmux new -s main
  # later, from anywhere on the tailnet:
  ssh <user>@pixel-avf -t tmux attach -t main
  ```
- **From the Pixel itself** — use Termux or any Android SSH client app
  (Termius, JuiceSSH, ConnectBot). They all reach `pixel-avf:22` over
  the tailnet the same way your laptop does.
- **File transfer** — `scp` or `rsync -avh` work normally. The Android
  shared folder under `/mnt/shared` in the VM bridges to Android's
  `/storage/emulated/0/AVF/` if you need a physical-storage hand-off.

## Step 4 — Install dev tools (sesh + Node)

Single entry point that installs everything in one go:

```bash
ssh <user>@pixel-avf
cd ~/pixel10-avf       # wherever you put this repo
./setup.sh
```

What it does (in order):

1. **git + sesh** via [`install-sesh.sh`](install-sesh.sh)
   - Installs `git` if missing
   - Verifies SSH-to-GitHub works (prints clear setup instructions if
     it doesn't — generate `ssh-keygen -t ed25519` and add to GitHub)
   - Clones `git@github.com:rynobey/sesh.git` to `~/projects/sesh`
     (override with `SESH_DIR` env var)
   - Runs `sesh/install.sh`, which apt-installs `tmux`, `vifm`,
     `ripgrep`, `xclip`, `glow`, etc. — see the sesh README for the
     full list
2. **nvm + latest Node LTS** via [`install-node.sh`](install-node.sh)
   - Installs nvm (pinned version, overridable via `NVM_VERSION`)
   - `nvm install --lts`, set as default; `npm` ships with Node

Re-run safe (`./setup.sh` again pulls sesh latest, re-runs its
installer, and is a no-op for nvm/Node if already current). Pass
`--force` to overwrite user configs (forwarded to sesh's installer).

The two helper scripts can also be run individually if you only want
one half — see their headers for details.

## Notes

### Backups

The AVF VM image lives in the Terminal app's private storage and is
**not accessible from Android** without root. Back up from inside the
VM:

```bash
sudo apt install -y restic rclone
# set up restic with a remote (B2, S3, your NAS over Tailscale, etc.)
# schedule with a systemd timer
```

Clearing the Terminal app's data in Android Settings will destroy the
entire VM with no recovery. Off-device backups aren't optional.

### Termux ↔ AVF

Both can coexist. Termux is good for quick Android-side shell tasks; the
AVF VM is your real Linux environment. Bridge them by putting both on
Tailscale — then from Termux: `ssh <user>@pixel-avf` works the same as
from anywhere else.

### Why headless and not the AVF Display feature

The AVF Terminal app has a built-in graphical Display feature, and we
explored it earlier — it works (Weston + kiosk-shell + Xwayland +
X11-backend-forced) but has rough edges (software rendering only,
compositing bugs, lazy surface allocation). For the headless use case
documented here it's irrelevant; the GUI experiments are kept out of the
default flow for simplicity.

### Resetting the VM

Worst case, if you want a fully clean slate: Android Settings → Apps →
Terminal → **Clear storage**. This destroys the VM image and Tailscale
state. Next launch of the Terminal app re-creates a fresh Debian. Do
backups first.

### Cleanup of earlier VNC / GUI experiments

If you went through an earlier VNC or Input Leap setup on this VM and
want to strip those artifacts without nuking the whole VM, run
[`cleanup-vnc-attempt.sh`](cleanup-vnc-attempt.sh) on the VM. It's
interactive (asks `[y/n]` per category) and covers:

- stopping cursor-bridge / VNC processes
- removing `~/bin/{vnc-start,vnc-stop,orient,route-*,cursor-bridge}`
- cleaning Input Leap source build + `/usr/local/bin` installs
- removing VNC / XFCE / Input Leap dotfiles
- removing stale apt sources from the failed input-leap search
- optionally purging the GUI packages (xfce4, tigervnc-*, lightdm, etc.)
