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

1. Install Podroid from its
   [GitHub releases](https://github.com/ExTV/Podroid) (sideload the APK).
2. Open the app. Pick **Settings → Advanced → Backend → AVF (KVM)** so
   it uses your Pixel's hardware virtualization. If prompted, grant
   the `pm grant` ADB command shown in-app.
3. Allocate RAM: 8 GB is a reasonable default on a 12 GB Pixel 10 —
   leaves headroom for Android, browser, etc.
4. Confirm persistence: settings should map a shared Android dir
   (typically `/sdcard/Download/Podroid/`) into the Alpine VM at
   `/mnt/shared/`. Files written there survive app wipes.
5. Open Podroid's terminal — you'll land at the Alpine host shell.

## Step 2 — Create the LXC

On the Alpine host (Podroid's terminal):

```sh
# Bootstrap the curl-able SSH access + git first (so we can clone
# this repo onto the Alpine host to access 01-create-lxc.sh).
# We use bootstrap-git-public.sh here — the Alpine host only needs
# to read the repo, not push, so no SSH key / GitHub setup needed:
curl -fsSL https://raw.githubusercontent.com/rynobey/linux-setups/master/bootstrap-ssh.sh | bash
curl -fsSL https://raw.githubusercontent.com/rynobey/linux-setups/master/bootstrap-git-public.sh | bash

# Then create + start the dev LXC:
cd ~/projects/linux-setups
./pixel/podroid/01-create-lxc.sh
```

What this does (see the script header for details):
- Installs `lxc`, `lxc-templates`, `lxc-download` on Alpine if missing
- Creates `dev` LXC from the Ubuntu Noble arm64 download template
- Patches `/var/lib/lxc/dev/config` for: privileged mode, all
  capabilities, all devices, `/dev/net/tun` for Tailscale, bind-mount
  of `/mnt/shared/` for persistence
- Starts the container

Then attach: `sudo lxc-attach -n dev`. You're inside Ubuntu.

## Step 3 — Create a non-root user

`lxc-attach -n dev` lands you as root. Don't run the rest of the
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
# 'sudo lxc-attach -n dev' from a fresh Podroid terminal session)

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

This walks through five sub-steps:

| Step | Script | What it does | Skip env |
|---|---|---|---|
| 1 | (inline) | apt update + base tools | — |
| 2 | [`authorize-pubkeys.sh`](authorize-pubkeys.sh) | append `pubkeys/*.pub` to `~/.ssh/authorized_keys` | `SKIP_PUBKEYS=1` |
| 3 | [`install-docker.sh`](install-docker.sh) | official get-docker.sh + add `$USER` to docker group | `SKIP_DOCKER=1` |
| 4 | [`install-sesh.sh`](install-sesh.sh) | clone rynobey/sesh, run its installer | `SKIP_SESH=1` |
| 5 | [`install-node.sh`](install-node.sh) | nvm + Node LTS | `SKIP_NODE=1` |

After this completes:

- Docker works (`docker run --rm hello-world`).
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
- `TS_HOSTNAME` — node name on the tailnet (default: `pixel-dev`)
- `TS_AUTHKEY` — pre-generated auth key (default: interactive)

After `tailscale up` succeeds your session drops. Reconnect via
MagicDNS:

```sh
ssh <user>@pixel-dev
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
`lxc-start -n dev` needed.

To stop the auto-start: edit `/var/lib/lxc/dev/config` and remove
(or set to 0) the `lxc.start.auto` line.

## Backup / restore

Both scripts run on the **Alpine host** (inside Podroid's terminal), not
inside the LXC. Backups land under `/mnt/shared/podroid-backups/`,
which Podroid maps to `/sdcard/Download/Podroid/podroid-backups/` on
Android — outside the app sandbox, so they survive a Podroid app data
wipe or full uninstall (and a re-install of your patched APK, etc).

### Making backups

```sh
./pixel/podroid/backup.sh                     # default: encrypted with `age -p`
./pixel/podroid/backup.sh --plain             # unencrypted .tar.gz
./pixel/podroid/backup.sh --list              # show existing backups
```

Encrypted backups use [`age`](https://github.com/FiloSottile/age) with
passphrase mode (scrypt KDF, ChaCha20-Poly1305). The script prompts
you for a passphrase and writes a `dev-<timestamp>.tar.gz.age` file.
Remember the passphrase — there's no way to recover the backup
without it. The script auto-installs `age` on Alpine via `apk add`
if it's missing.

Each invocation creates a new timestamped file, so multiple snapshots
accumulate. Prune the directory manually when you want to reclaim
space.

### Restoring

```sh
./pixel/podroid/restore.sh                    # interactive picker
./pixel/podroid/restore.sh --latest           # newest backup, no prompt
./pixel/podroid/restore.sh <path>             # specific file
./pixel/podroid/restore.sh --list             # same as backup.sh --list
```

By default the existing `dev` LXC is renamed to `dev-prev-<timestamp>`
(not deleted) before unpacking, so you can roll back if the restore
went sideways. Once you've verified the restore worked, clean up the
preserved copy with `sudo rm -rf /var/lib/lxc/dev-prev-*`. Pass
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

## Persistence model

```
Android storage (survives anything)
    /sdcard/Download/Podroid/                       (Podroid's shared dir)
        ├─ podroid-backups/
        │   ├─ dev-2026-05-25-1530.tar.gz.age       (encrypted snapshots)
        │   └─ dev-2026-05-26-0945.tar.gz.age
        └─ (your project code if you put it here)
            ▲
            │ Podroid maps this in as
            ▼
Alpine host VM
    /mnt/shared/
        ├─ podroid-backups/                          (what backup.sh writes to)
        └─ ...
        ▲
        │ 01-create-lxc.sh bind-mounts as
        ▼
Ubuntu LXC
    /mnt/shared/                                     (whatever's here, persistent)
    /  (everything else is in the LXC rootfs — wiped if Podroid is wiped,
       unless a backup.sh snapshot exists in /mnt/shared/podroid-backups/)
```

Keep project source code under `/mnt/shared/` (symlink `~/projects`
there if you want) for redundancy — it survives even without a
backup. Run `backup.sh` before risky changes to the LXC itself
(big apt upgrades, restructuring users, etc.), or on a schedule.

## Troubleshooting

- **`docker info` errors / iptables noise**: check that `01-create-lxc.sh`'s
  config additions made it into `/var/lib/lxc/dev/config` and the
  container was restarted after. The `lxc.apparmor.profile = unconfined`
  + `lxc.cap.drop =` lines are load-bearing.
- **`tailscale up` says "tun device not available"**: same root cause —
  `/dev/net/tun` isn't bound in. See `install-tailscale.sh`'s error
  output for the exact config lines.
- **`02-bootstrap-lxc.sh` fails mid-way**: each step is idempotent.
  Set the appropriate `SKIP_*=1` envs for steps that already
  succeeded and re-run.
