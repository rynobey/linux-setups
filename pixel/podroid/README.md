# Podroid + Ubuntu LXC — headless compute side

The compute half of the hybrid Pixel setup. Podroid hosts an Alpine VM
on AVF; inside it we run a privileged **Ubuntu Noble LXC** ('dev')
which is where all the actual work happens — Docker, sesh, nvim, the
project codebase, sshd reachable over Tailscale.

The Stock Terminal side handles GUI / GPU stuff — see
[`../stock-terminal/`](../stock-terminal/). The two never share state.

## Why this layout

- **Podroid for the host VM**, not the Stock Terminal: Podroid gives
  us a clean Alpine + LXC ecosystem with built-in persistence and port
  forwarding, *and* uses AVF/pKVM for near-native performance.
- **Ubuntu (in LXC), not Alpine**: glibc means every Docker image, every
  pre-built Node/Python wheel, every Go ARM64 binary just runs. Alpine's
  musl breaks a non-trivial slice of the ecosystem.
- **Privileged LXC**, not unprivileged: single-user box, simpler
  Docker (overlay2) and Tailscale (TUN passthrough) setup. The blast
  radius of escape is bounded by AVF/pKVM anyway.

## Step 1 — Podroid app, one-time

1. Install Podroid:
   - **Stock build**: from [GitHub releases](https://github.com/ExTV/Podroid)
     (sideload the APK). Installs as `com.excp.podroid`.
   - **Custom build with 6/8 GB RAM tiers**: from the
     [rynobey/Podroid fork's GH Actions](https://github.com/rynobey/Podroid/actions)
     — download the `app-debug-*` artifact, unzip, `adb install -r app-debug.apk`.
     Installs as `com.excp.podroid.debug` *alongside* the stock one (different
     package, two icons in the launcher).

2. **Pair ADB.** Required so the next step can run. Use either:
   - **USB cable** — Settings → Developer options → USB debugging → ON;
     allow the RSA prompt on the phone when you first `adb devices`.
   - **Wireless** — Settings → Developer options → Wireless debugging
     → Pair device with pairing code (keep the popup open). Then on
     your laptop: `adb pair <ip>:<pair-port>` (enter the 6-digit
     code), then `adb connect <ip>:<conn-port>`. If you don't have
     a laptop, [Termux](https://termux.dev) on the phone itself can
     do this (`pkg install android-tools`, then `adb pair` as above
     but in a split-screen view).

3. **Run `pixel/podroid/adb-setup.sh`** to apply the device-side
   Podroid config in one go:

   ```sh
   cd ~/projects/linux-setups
   ./pixel/podroid/adb-setup.sh
   ```

   Idempotent. Does:
   - Phantom Process Killer disable (system-wide, with the persistent
     sync-disable flag so Phenotype doesn't quietly revert it)
   - Podroid AVF permission grants (`MANAGE_VIRTUAL_MACHINE` +
     `USE_CUSTOM_VIRTUAL_MACHINE`) for both `com.excp.podroid` and
     `com.excp.podroid.debug` — whichever are installed
   - Podroid storage `appops` at both package and UID levels

   Re-run after any Podroid reinstall (the `pm grant` permissions
   are dropped on uninstall, the script silently re-applies them).
   The Stock Terminal's separate ADB step (hardware acceleration)
   lives in [`../stock-terminal/adb-setup.sh`](../stock-terminal/adb-setup.sh).

   <details>
   <summary>Manual fallback commands (if you'd rather not run the script)</summary>

   ```sh
   # AVF gate permissions (replace .debug with no suffix for the stock build):
   adb shell pm grant com.excp.podroid.debug android.permission.MANAGE_VIRTUAL_MACHINE
   adb shell pm grant com.excp.podroid.debug android.permission.USE_CUSTOM_VIRTUAL_MACHINE

   # Storage appops:
   adb shell appops set com.excp.podroid.debug MANAGE_EXTERNAL_STORAGE allow

   # Phantom Process Killer:
   adb shell device_config set_sync_disabled_for_tests persistent
   adb shell device_config put activity_manager max_phantom_processes 2147483647
   adb shell settings put global settings_enable_monitor_phantom_procs false
   ```
   </details>

4. Open the app. Pick **Settings → Advanced → Backend → AVF (KVM)** so
   it uses the Pixel's hardware virtualization layer. If AVF doesn't
   show in the picker, re-check step 3 (perms not granted or wrong
   package).

5. Allocate RAM. On a 12 GB Pixel 10, the safe allocation depends on
   what's running on the Android side — Pixel's AI/system services
   easily consume 4-5 GB of "always on" memory. **Empirically validated
   on Pixel 10 / Android 16:**

   | Allocation | Safe if… | Notes |
   |---|---|---|
   | **2 GB** | Always | Bulletproof; backups always work; fine for daily dev (LXC working set fits easily) |
   | **4 GB** | Default Android baseline | Works for daily dev; backups risky without page-cache mitigation |
   | **6 GB** | AiCore + TTS disabled (see *Memory tuning* below) | Works for backups + heavy ops once Android baseline is trimmed |
   | **8 GB** | Most user apps + AiCore + TTS disabled | Possible but tight; one runaway app from LMK kill |

   The 6 / 8 GB tiers exist only in the custom debug build; stock Podroid
   caps at 4 GB.

6. Settings → **Storage access** → ON. (Note: the AVF SharedPath into
   `/sdcard/` is silently dropped on current Pixel 10 / Android 16
   firmware regardless of this toggle and `MANAGE_EXTERNAL_STORAGE` —
   leaving it on doesn't hurt, and lets things work if a future OS
   update fixes the underlying AVF bug.)

7. Open Podroid's terminal — you'll land at the Alpine host shell.

### Verifying AVF is actually in use

After starting the VM:

```sh
adb shell pm list features | grep virtualization_framework        # feature present?
adb shell getprop ro.boot.hypervisor.vm.supported                 # pKVM exposed?
adb shell pm dump com.excp.podroid.debug | grep -A2 'granted=true' | grep -E 'VIRTUAL|MANAGE'
```

All three should be non-empty. Per the Podroid `docs/guide/backends.html`:
when backend is set to Auto, Podroid checks (1) the
`virtualization_framework` feature is present, (2) `MANAGE_VIRTUAL_MACHINE`
is granted, (3) `USE_CUSTOM_VIRTUAL_MACHINE` is granted, (4) the device
advertises non-protected VM support. All four must pass or it falls back
to TCG silently. The explicit AVF (KVM) backend toggle is your safety
net to avoid the fallback.

### Memory tuning — disable Android services that compete with the VM

Skip this section if you're staying on a small (2 GB) VM allocation.
**Required for stable 6 / 8 GB allocation.**

Pixel's on-device AI service (`com.google.android.aicore`) holds up to
**3.8 GB of Tensor / DMA-BUF memory** when actively running inference
(Magic Compose, Smart Reply, Now Brief, etc.). It's only ~130 MB at
idle, but **the spike triggers Low-Memory-Killer kills of Podroid**
whenever AiCore happens to be inferring during a memory-heavy VM
operation (backup, big build). That's not theoretical — it's exactly
how the 6 GB VM was reproducibly killed before AiCore was disabled,
and reproducibly successful afterwards.

The fix: `pm disable-user` the packages that cost more than they're
worth to you. Reversible any time. See
[`../android-disabled-packages.md`](../android-disabled-packages.md)
for what each one controls and how to re-enable.

Quick start, via the helper:

```sh
cd ~/projects/linux-setups
./pixel/android-pkg-state.sh status      # see current state + memory
./pixel/android-pkg-state.sh disable     # disable AiCore + TTS (default tracked list)
./pixel/android-pkg-state.sh enable      # restore them later if you want
```

Measured impact on a Pixel 10 / 12 GB / Android 16, after running
`disable`:

- MemAvailable: 764 MB → **4.31 GB**
- ZRAM swapped: 4.5 GB → 3.1 GB (apps that were paged out got revived)
- DMA-BUF heap: 4.2 GB → **425 MB** (AiCore's Tensor memory released)

That's enough headroom to run a 6 GB VM allocation through a full
backup without LMK firing. Empirically reproduced after the change;
not before.

**What you lose** (full list in
[`android-disabled-packages.md`](../android-disabled-packages.md)):

- Magic Compose in Gboard, Smart Reply in Messages, Now Brief, Recorder Summarize
- Google Text-to-Speech (TalkBack voice, Maps voice prompts)

What's kept regardless: Google Assistant (cloud), voice typing,
camera AI features (Best Take, Magic Eraser), all non-AI Android.

Other apps in your top-RSS list (Facebook, Telegram, WhatsApp, YouTube,
Digital Wellbeing) can be added to the script's `TRACKED` array if
you want more headroom. See the script for the format.

## Step 2 — Create the LXC

On the Alpine host (Podroid's terminal):

```sh
# Bootstrap the curl-able SSH access + git first (so we can clone
# this repo onto the Alpine host to access 01-create-lxc.sh).
# We use bootstrap-git-public.sh here — the Alpine host only needs
# to read the repo, not push, so no SSH key / GitHub setup needed:
curl -fsSL https://raw.githubusercontent.com/rynobey/linux-setups/master/bootstrap-ssh.sh | bash
curl -fsSL https://raw.githubusercontent.com/rynobey/linux-setups/master/bootstrap-git-public.sh | bash

# Then create + start the pubuntu LXC:
cd ~/projects/linux-setups
./pixel/podroid/01-create-lxc.sh
```

What this does (see the script header for details):
- Installs `lxc`, `lxc-templates`, `lxc-download` on Alpine if missing
- Creates `dev` LXC from the Ubuntu Noble arm64 download template
- Patches `/var/lib/lxc/pubuntu/config` for: privileged mode, all
  capabilities, all devices, `/dev/net/tun` for Tailscale, bind-mount
  of `/mnt/shared/` for persistence
- Starts the container

Then attach: `sudo lxc-attach -n pubuntu`. You're inside Ubuntu.

## Step 3 — Create a non-root user

`lxc-attach -n pubuntu` lands you as root. Don't run the rest of the
bootstrap as root — your laptop's pubkey would end up in root's
`authorized_keys`, and SSH into the LXC would target root by default.
Create a sudo-capable user first.

The repo isn't on disk yet, so curl `create-user.sh` standalone:

```sh
apt update && apt install -y curl
curl -fsSL https://raw.githubusercontent.com/rynobey/linux-setups/master/pixel/podroid/create-user.sh -o create-user.sh
bash create-user.sh        # interactive: username, password, sudo, shell
su - <username>
```

Or if you'd rather skip the wrapper:

```sh
apt update && apt install -y sudo
adduser <username>         # prompts for password
usermod -aG sudo <username>
su - <username>
```

All subsequent steps run as this user, not as root.

## Step 4 — Authorize SSH access and clone the repo

As the user from Step 3, use the same two curl-able bootstraps:

```sh
# Authorize laptop SSH access (lets you stop using lxc-attach):
curl -fsSL https://raw.githubusercontent.com/rynobey/linux-setups/master/bootstrap-ssh.sh | bash

# Optionally: ssh in from your laptop now (assuming Tailscale is up on
# the LXC — but it isn't yet, so for now do this over LAN or via
# 'sudo lxc-attach -n pubuntu' from a fresh Podroid terminal session)

# Set up the LXC's own GitHub identity + clone the repo. Use the full
# bootstrap-git.sh here (not -public) so this LXC can also push:
curl -fsSL https://raw.githubusercontent.com/rynobey/linux-setups/master/bootstrap-git.sh | bash
```

## Step 5 — Run the orchestrator

With the repo cloned, run:

```sh
cd ~/projects/linux-setups
./pixel/podroid/02-bootstrap-lxc.sh
```

This walks through six sub-steps:

| Step | Script | What it does | Skip env |
|---|---|---|---|
| 1 | (inline) | apt update + base tools | — |
| 2 | [`authorize-pubkeys.sh`](authorize-pubkeys.sh) | append `pubkeys/*.pub` to `~/.ssh/authorized_keys` | `SKIP_PUBKEYS=1` |
| 3 | [`install-docker.sh`](install-docker.sh) | official get-docker.sh + add `$USER` to docker group | `SKIP_DOCKER=1` |
| 4 | [`install-toolchains.sh`](install-toolchains.sh) | `build-essential` (gcc/g++/make), `golang-go`, `pkg-config` | `SKIP_TOOLCHAINS=1` |
| 5 | [`install-sesh.sh`](install-sesh.sh) | clone rynobey/sesh, run its installer | `SKIP_SESH=1` |
| 6 | [`install-node.sh`](install-node.sh) | nvm + Node LTS | `SKIP_NODE=1` |

After this completes:

- Docker works (`docker run --rm hello-world`).
- `gcc`, `make`, `go`, `pkg-config` are on PATH (build anything that
  compiles natively or via cgo).
- `sesh` is on PATH; first run sets up `~/.config/sesh/`.
- `nvm`, `node`, `npm` are on PATH after a new shell.

## Step 6 — Set up Tailscale (drops your SSH session)

Tailscale is split out from the orchestrator because `tailscale up`
reshuffles routing and disconnects the SSH/lxc-attach session you're
running from. Run it as the **last** step so nothing else is queued
behind the drop:

```sh
./pixel/podroid/03-install-tailscale.sh
```

Interactive: opens an auth URL. To skip the prompt, pre-generate a key
in the [admin console](https://login.tailscale.com/admin/settings/keys)
and pass it as env:

```sh
TS_AUTHKEY=tskey-auth-... ./pixel/podroid/03-install-tailscale.sh
```

Env overrides:
- `TS_HOSTNAME` — node name on the tailnet (default: `pubuntu`)
- `TS_AUTHKEY` — pre-generated auth key (default: interactive)

After `tailscale up` succeeds your session drops. Reconnect via
MagicDNS:

```sh
ssh <user>@pubuntu
```

Works from any tailnet device, on or off Wi-Fi, no port forwarding.

## Optional helpers

- [`create-user.sh`](create-user.sh) — interactive `useradd` if you
  want a user other than the default `ubuntu`. Run as root before
  switching to that user and re-running the bootstrap.
- [`backup.sh`](backup.sh) — encrypted LXC snapshot, see next section.
- [`restore.sh`](restore.sh) — counterpart to `backup.sh`.

## Auto-start on Alpine boot

`01-create-lxc.sh` adds `lxc.start.auto = 1` to the LXC config and
enables Alpine's `lxc` service in the default runlevel. So whenever
Podroid's Alpine VM boots (which happens often — every time you launch
the app cold), the `dev` LXC comes up unattended. No manual
`lxc-start -n pubuntu` needed.

To stop the auto-start: edit `/var/lib/lxc/pubuntu/config` and remove
(or set to 0) the `lxc.start.auto` line.

## Backup / restore

`backup.sh` and `restore.sh` run on the **Alpine host** inside Podroid's
terminal (not inside the LXC). Backups land at
`/var/lib/podroid-backups/` — a regular directory on Alpine's
persistent disk.

> **⚠ Backups are NOT durable on their own.** That directory lives
> inside Podroid's app sandbox on Android. It survives Alpine reboots,
> Podroid restarts, VM rebuilds — but **not** a Podroid app-data wipe
> or app uninstall. For real durability, pull the backups onto your
> laptop with [`sync-backups.sh`](sync-backups.sh) on a schedule. See
> the *Durable storage via sync-backups.sh* section below.
>
> Earlier versions of these scripts targeted `/mnt/downloads/` on
> the assumption that AVF's SharedPath feature would expose Android's
> `/sdcard/Download/` inside the VM. On current Pixel 10 / Android 16
> firmware the AVF service silently drops external-storage SharedPaths
> for non-system apps, so the VM never actually sees `/sdcard/`. The
> design has been simplified: backups go to a known Alpine path,
> durability is the user's laptop pulling them out via scp.
>
> **Migration if you have backups from older script versions:** they
> were likely written to `/mnt/shared/podroid-backups/` (the LXC bind-mount
> source). Move them to the new location:
>
> ```sh
> # In the Alpine host terminal:
> if [ -d /mnt/shared/podroid-backups ]; then
>     sudo mkdir -p /var/lib/podroid-backups
>     sudo mv /mnt/shared/podroid-backups/* /var/lib/podroid-backups/
> fi
> ```

### Making backups

```sh
./pixel/podroid/backup.sh                     # default: encrypted with `age -p`
./pixel/podroid/backup.sh --plain             # unencrypted .tar.gz
./pixel/podroid/backup.sh --list              # show existing backups
```

Encrypted backups use [`age`](https://github.com/FiloSottile/age) with
passphrase mode (scrypt KDF, ChaCha20-Poly1305). The script prompts
you for a passphrase and writes a `pubuntu-<timestamp>.tar.gz.age` file.
Remember the passphrase — there's no way to recover the backup
without it. The script auto-installs `age` on Alpine via `apk add`
if it's missing.

Each invocation creates a new timestamped file, so multiple snapshots
accumulate. Prune the directory manually when you want to reclaim
space.

### Running backups/restores safely (Android can kill them)

Long backup/restore operations have an awkward failure mode on
Podroid: while Podroid is backgrounded (you switch apps, lock the
phone), Android's Low-Memory Killer can decide the multi-GB
allocation pressure of the age-decrypt + tar-extract makes Podroid
expendable. When it gets reaped, the whole Alpine VM goes with it —
your tmux session, your SSH session, your in-flight restore. The
symptom matches reality: the SSH client disconnects, Tailscale on
Android might crash, and sometimes the Pixel even briefly shows
"no network" on the lock screen.

Mitigations (apply all of them for restore; for small backups, just
the first one is usually enough):

1. **Wrap the command in tmux** on the Alpine host:
   ```sh
   tmux new -s restore './pixel/podroid/restore.sh --latest'
   ```
   `tmux` is installed by `01-create-lxc.sh`. The script also warns
   if you're running outside tmux and prompts before proceeding;
   set `SKIP_TMUX_CHECK=1` to silence it.

2. **Run from Podroid's own terminal app on the phone**, not via
   SSH from your laptop. Removes the SSH-disconnect failure mode
   entirely — if Android kills Podroid you can just relaunch and
   `tmux attach -t restore` (the session survives Podroid restarts
   as long as the Alpine VM image itself stays intact).

3. **Keep the screen on and plug in to charge.** Lock screen makes
   Android more aggressive about reclaiming background apps.
   *Settings → System → Developer options → Stay awake* keeps the
   display alive while charging.

4. **Mark Podroid as battery-unrestricted.** *Settings → Apps →
   Podroid → Battery → Unrestricted*. Also turn off "Pause app
   activity if unused" on the same screen.

5. **Close other heavy apps** (Chrome, Maps, browsers in general)
   before kicking off the restore. Less foreground RAM = less LMK
   pressure on background apps.

6. **Disable Android's phantom-process killer** (once, persists):
   ```sh
   adb shell device_config put activity_manager max_phantom_processes 2147483647
   adb shell settings put global settings_enable_monitor_phantom_procs false
   ```

If a restore *still* gets killed, peek at LMK activity with
`adb shell dumpsys activity processes | grep -A3 podroid` — climbing
`oom_adj` values right before the kill confirm Android did it.

### Restoring

```sh
./pixel/podroid/restore.sh                    # interactive picker
./pixel/podroid/restore.sh --latest           # newest backup, no prompt
./pixel/podroid/restore.sh <path>             # specific file
./pixel/podroid/restore.sh --list             # same as backup.sh --list
```

By default the existing `pubuntu` LXC is renamed to `pubuntu-prev-<timestamp>`
(not deleted) before unpacking, so you can roll back if the restore
went sideways. Once you've verified the restore worked, clean up the
preserved copy with `sudo rm -rf /var/lib/lxc/pubuntu-prev-*`. Pass
`--no-keep-prev` to delete in place instead.

Restoring an encrypted backup re-prompts for the same passphrase used
when it was made.

### What's preserved across a backup/restore

The whole LXC rootfs is included. That means:

- Your user account, home dir, shell history, dotfiles
- All apt-installed packages (Docker, Tailscale, sesh, etc.)
- **Tailscale identity** — `/var/lib/tailscale/tailscaled.state`
  rides along, so the restored LXC rejoins your tailnet as the same
  node with the same MagicDNS name; no `tailscale up` reauth needed
- Docker images, containers, and volumes (`/var/lib/docker/`)
- LXC's own networking config (any tweaks to `lxc.net.*`)

What's not preserved: anything in the Alpine host layer outside the
LXC (sshd host keys, host apk packages, etc.) — but our setup doesn't
put anything important there. Re-running `01-create-lxc.sh` on the
host before the restore gives you a clean Alpine baseline.

### Durable storage via sync-backups.sh

Run [`sync-backups.sh`](sync-backups.sh) **on your laptop** (not on
Alpine) to copy backups out of Podroid onto your laptop's filesystem.
This is the actual durability layer — the only thing that survives
a Podroid uninstall or full Android factory reset.

```sh
# Default — pull all backups from Alpine to ~/podroid-backups/ on the laptop:
./pixel/podroid/sync-backups.sh

# List what's on Alpine without downloading:
./pixel/podroid/sync-backups.sh --list-remote

# Push backups back from your laptop to Alpine (for restore):
./pixel/podroid/sync-backups.sh --push --local ~/podroid-backups

# Use ADB-forwarded port instead of Tailscale:
adb forward tcp:9922 tcp:9922
./pixel/podroid/sync-backups.sh --host localhost

# After pulling, also delete the remote copy (free space on Alpine):
./pixel/podroid/sync-backups.sh --delete-after
```

Defaults:

- Target: `root@pubuntu` (Tailscale-resolved) on port 9922 (Podroid's
  Alpine sshd forward). Override with `--host`, `--port`, `--user` or
  the corresponding `DEV_HOST` / `DEV_PORT` / `DEV_USER` env vars.
- Remote dir: `/var/lib/podroid-backups/` on Alpine. Override with
  `--remote` or `REMOTE_DIR`.
- Local dir: `~/podroid-backups/`. Override with `--local` or
  `LOCAL_DIR`.

The script auto-detects whether Alpine has `openssh-sftp-server`
installed; if not, it falls back to `scp -O` (legacy protocol),
which works against Alpine's default openssh package. Install
`openssh-sftp-server` on Alpine for a cleaner experience:

```sh
ssh root@pubuntu -p 9922 'apk add openssh-sftp-server'
```

Recommended workflow:

- After every meaningful `backup.sh`, run `sync-backups.sh` once on
  your laptop. Two-step but reliable.
- Or stick it in your laptop's crontab to run every few hours.

## Persistence model

```
Laptop (truly durable)
    ~/podroid-backups/
        ├─ pubuntu-2026-05-25-1530.tar.gz.age       (encrypted snapshots)
        └─ pubuntu-2026-05-26-0945.tar.gz.age
        ▲
        │ pulled via sync-backups.sh (scp -O over Tailscale
        │ or ADB-forwarded port 9922 → Podroid → Alpine sshd)
        │
Alpine host VM (lives inside Podroid app sandbox)
    /var/lib/podroid-backups/                        (what backup.sh writes to)
        ├─ pubuntu-2026-05-25-1530.tar.gz.age
        └─ ...
    /mnt/downloads/                                  (AVF virtio-9p share from
                                                      /sdcard/Download/ on Android —
                                                      ⚠ silently dropped on current
                                                      Pixel 10 / Android 16 firmware)
        ▲
        │ 01-create-lxc.sh bind-mounts as
        ▼
Ubuntu LXC
    /mnt/shared/                                     (alias for /mnt/downloads on Alpine)
    /                                                (everything else is in the LXC rootfs;
                                                      backup.sh tars it)
```

Survival matrix:

| Event | LXC rootfs | Alpine /var/lib/podroid-backups | Laptop ~/podroid-backups |
|---|---|---|---|
| LXC destroyed + recreated | ❌ lost (without backup) | ✅ kept | ✅ kept |
| Alpine VM rebooted | ✅ kept | ✅ kept | ✅ kept |
| Podroid app restarted | ✅ kept | ✅ kept | ✅ kept |
| Podroid app-data cleared | ❌ wiped | ❌ wiped | ✅ kept |
| Podroid uninstalled | ❌ wiped | ❌ wiped | ✅ kept |
| Android factory reset | ❌ wiped | ❌ wiped | ✅ kept |
| Laptop disk fails | ❌ wiped | (irrelevant) | ❌ wiped |

So: take backups frequently on Alpine, sync them out to your laptop
on a meaningful cadence (after each backup, daily, whatever fits),
and keep your laptop backed up too. The Pixel-side `/var/lib/podroid-backups`
is a transit zone, not durable storage.

## Troubleshooting

- **`docker info` errors / iptables noise**: check that `01-create-lxc.sh`'s
  config additions made it into `/var/lib/lxc/pubuntu/config` and the
  container was restarted after. The `lxc.apparmor.profile = unconfined`
  + `lxc.cap.drop =` lines are load-bearing.
- **`tailscale up` says "tun device not available"**: same root cause —
  `/dev/net/tun` isn't bound in. See `install-tailscale.sh`'s error
  output for the exact config lines.
- **`02-bootstrap-lxc.sh` fails mid-way**: each step is idempotent.
  Set the appropriate `SKIP_*=1` envs for steps that already
  succeeded and re-run.
