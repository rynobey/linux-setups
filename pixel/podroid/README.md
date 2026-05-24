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
# this repo onto the Alpine host to access 01-create-lxc.sh):
curl -fsSL https://raw.githubusercontent.com/rynobey/linux-setups/master/bootstrap-ssh.sh | bash
bash <(curl -fsSL https://raw.githubusercontent.com/rynobey/linux-setups/master/bootstrap-git.sh)

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

## Step 3 — Bootstrap inside the LXC

Inside the LXC, the new Ubuntu has nothing. Use the same two curl-able
bootstraps:

```sh
# Authorize laptop SSH access (lets you stop using lxc-attach):
curl -fsSL https://raw.githubusercontent.com/rynobey/linux-setups/master/bootstrap-ssh.sh | bash

# Optionally: ssh in from your laptop now (assuming Tailscale is up on
# the LXC — but it isn't yet, so for now do this over LAN or via
# 'sudo lxc-attach -n dev' from a fresh Podroid terminal session)

# Set up the LXC's own GitHub identity + clone the repo:
bash <(curl -fsSL https://raw.githubusercontent.com/rynobey/linux-setups/master/bootstrap-git.sh)
```

Then run the orchestrator:

```sh
cd ~/projects/linux-setups
./pixel/podroid/02-bootstrap-lxc.sh
```

This walks through six steps:

| Step | Script | What it does | Skip env |
|---|---|---|---|
| 1 | (inline) | apt update + base tools | — |
| 2 | [`authorize-pubkeys.sh`](authorize-pubkeys.sh) | append `pubkeys/*.pub` to `~/.ssh/authorized_keys` | `SKIP_PUBKEYS=1` |
| 3 | [`install-docker.sh`](install-docker.sh) | official get-docker.sh + add `$USER` to docker group | `SKIP_DOCKER=1` |
| 4 | [`install-tailscale.sh`](install-tailscale.sh) | install tailscale, `tailscale up --hostname=pixel-dev` | `SKIP_TAILSCALE=1` |
| 5 | [`install-sesh.sh`](install-sesh.sh) | clone rynobey/sesh, run its installer | `SKIP_SESH=1` |
| 6 | [`install-node.sh`](install-node.sh) | nvm + Node LTS | `SKIP_NODE=1` |

For Tailscale you'll need either an interactive browser to visit the
auth URL or a pre-generated key:

```sh
TS_AUTHKEY=tskey-auth-... ./pixel/podroid/02-bootstrap-lxc.sh
```

(Get one from [the admin console](https://login.tailscale.com/admin/settings/keys).)

After this completes:

- Laptop reaches the LXC at `ssh <user>@pixel-dev` (Tailscale MagicDNS).
- Docker works (`docker run --rm hello-world`).
- `sesh` is on PATH; first run sets up `~/.config/sesh/`.
- `nvm`, `node`, `npm` are on PATH after a new shell.

## Optional helpers

- [`create-user.sh`](create-user.sh) — interactive `useradd` if you
  want a user other than the default `ubuntu`. Run as root before
  switching to that user and re-running the bootstrap.
- [`backup.sh`](backup.sh) — runs on the **Alpine host**, tars
  `/var/lib/lxc/dev/` into `/mnt/shared/dev-backup-<date>.tar.gz`.
  Restore: `sudo tar -xvpzf <backup>.tar.gz -C /var/lib/lxc/`.

## Persistence model

```
Android storage (survives anything)
    /sdcard/Download/Podroid/             (Podroid's shared dir)
        └─ projects/                       (your code lives here)
        └─ dev-backup-2026-05-24.tar.gz    (LXC snapshots land here)
            ▲
            │ Podroid maps this in as
            ▼
Alpine host VM
    /mnt/shared/
        ▲
        │ 01-create-lxc.sh bind-mounts as
        ▼
Ubuntu LXC
    /mnt/shared/projects/                  (project code, persistent)
    /  (everything else is in the LXC rootfs — wiped if Podroid is wiped,
       unless backup.sh was run recently)
```

Keep anything you can't afford to lose under `/mnt/shared/projects/`
(symlink `~/projects` there if you want). Run `backup.sh` from the
Alpine host before risky changes to the LXC itself.

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
