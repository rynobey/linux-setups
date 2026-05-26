# Pixel 10 — hybrid dev environment

A real Linux dev box on a Pixel 10 (Android 16), splitting work across
**two AVF-backed VMs** to get both maximum compute power *and*
hardware-accelerated graphics:

| Side | What it does | Where |
|---|---|---|
| **Podroid + Ubuntu LXC** | headless compute — Docker, sesh, dev tools, sshd | [`podroid/`](podroid/), [`lxc/`](lxc/) |
| **Stock Linux Terminal** | GPU-accelerated GUI host — sway tiling WM + foot + browser | [`stock-terminal/`](stock-terminal/) |

Both run on the same Pixel via the **Android Virtualization Framework
(AVF / pKVM)** — near-native CPU speed, no software emulation. They
talk to each other (and your laptop) over Tailscale.

## Repo layout

```
pixel/
├── client/                # ★ Entry scripts you run from your CLIENT machine
│   │                        (Termux on the Pixel, or any Linux laptop with
│   │                         ADB + SSH to the device).
│   ├── 01-deploy-podroid.sh        # Install/replace Podroid APK + ADB config
│   ├── 02-adb-settings.sh          # Re-apply PPK + AVF + storage perms
│   ├── 03-backup-lxc.sh            # Create + pull LXC backup
│   ├── 04-restore-lxc.sh           # Push + restore backup (auto-creates LXC)
│   ├── 05-setup-lxc-fresh.sh       # Full fresh LXC + user + ssh + deps + Tailscale
│   ├── 06-bootstrap-ssh-lxc.sh     # Just SSH bootstrap (key gen + sshd + pubkeys)
│   ├── 07-bootstrap-deps-lxc.sh    # Just deps (Docker, toolchains, sesh, Node)
│   ├── 08-install-tailscale-lxc.sh # Just Tailscale install + auth
│   └── helper/
│       ├── alpine-run.sh           # Stream a script to Alpine via SSH
│       ├── lxc-run.sh              # Stream a script to pubuntu via SSH + lxc-attach
│       └── _lib.sh                 # Shared bash functions
│
├── termux/                # Termux-ONLY (only run from inside Termux on the Pixel)
│   ├── 01-init-termux.sh           # Fresh Termux setup (packages, sshd, key, clone)
│   ├── 02-snapshot.sh              # Recovery snapshot (PREFIX + HOME → /sdcard)
│   └── 03-restore-snapshot.sh      # Restore from snapshot on a fresh Termux
│
├── podroid/               # Scripts that RUN on Alpine (called via client/helper/alpine-run.sh)
│   └── helper/
│       ├── create-lxc.sh           # Bootstrap Alpine + create the LXC shell
│       ├── backup.sh               # Snapshot the LXC into a .tar.gz.age
│       ├── restore.sh              # Restore a backup into the LXC
│       ├── sync-backups.sh         # scp backups between Alpine and a client
│       └── adb-setup.sh            # ADB-side Podroid config (PPK + AVF perms)
│
├── lxc/                   # Scripts that RUN inside pubuntu (called via client/helper/lxc-run.sh)
│   └── helper/
│       ├── create-user.sh          # Interactive user creation
│       ├── bootstrap-ssh.sh        # sshd + key gen + authorize-pubkeys
│       ├── bootstrap-deps.sh       # Orchestrator: docker + toolchains + sesh + node
│       ├── install-tailscale.sh    # Tailscale up
│       ├── install-docker.sh
│       ├── install-sesh.sh
│       ├── install-node.sh
│       ├── install-toolchains.sh
│       └── authorize-pubkeys.sh
│
├── stock-terminal/        # Stock Linux Terminal scripts (GUI side, unchanged scope)
│   ├── 01-...
│   └── helper/...
│
├── README.md (this file)
├── android-pkg-state.sh   # Enable/disable Android packages (AiCore, TTS, ...)
└── android-disabled-packages.md
```

**The rule of thumb:** if you're invoking a script, look in `client/` or
`termux/`. Everything in `*/helper/` is called from those entry scripts
(via `alpine-run.sh` or `lxc-run.sh`) — you don't run them directly.

## Workflows

### From a CLIENT machine (Termux on Pixel, or any Linux laptop)

These work identically from either context. Prerequisites:
- ADB paired+connected to the Pixel (for ADB-using scripts)
- SSH access to Alpine on `localhost:9922` (Termux) or `pixel:9922` (laptop via Tailscale)
- This client's pubkey in Alpine's `/root/.ssh/authorized_keys`

| Workflow | Command |
|---|---|
| **a.** Create + sync LXC backup | `bash client/03-backup-lxc.sh` |
| **b.** Restore an LXC backup (auto-creates LXC if needed) | `bash client/04-restore-lxc.sh` |
| **c.** Install/replace Podroid + apply ADB config | `bash client/01-deploy-podroid.sh` |
| **d.** Initial fresh LXC setup (no restore) | `bash client/05-setup-lxc-fresh.sh` |
| **e.** SSH bootstrap on LXC (incl. key gen if absent) | `bash client/06-bootstrap-ssh-lxc.sh` |
| **f.** Deps bootstrap on LXC | `bash client/07-bootstrap-deps-lxc.sh` |
| **g.** Tailscale install + up | `bash client/08-install-tailscale-lxc.sh` |
| **h.** Additional ADB settings post pair+connect | `bash client/02-adb-settings.sh` |

Each script auto-detects the username (via `/etc/podroid-last-user` written
by `create-user.sh`), so steps **e**, **f**, **g** can be re-run without
re-typing the username.

### From Termux on the Pixel (only)

| Workflow | Command |
|---|---|
| Fresh Termux setup (packages, sshd, key, clone repo) | `bash termux/01-init-termux.sh` |
| Make a recovery snapshot (PREFIX + HOME, encrypted) | `bash termux/02-snapshot.sh` |
| Restore from a snapshot on a fresh Termux | `bash termux/03-restore-snapshot.sh` |

Termux snapshots go to `~/storage/shared/Download/` (i.e. `/sdcard/Download/`)
so they survive Termux uninstall and even a factory reset.

### From any Linux machine (e.g. ryno-hp)

Same as the Termux table above for **client/**, except the Termux-specific
snapshot scripts in **termux/** don't apply.

## Memory tuning

The `12 GB` Pixel is tight when the VM runs at 6 GB. Before serious work:

```sh
# Disable AiCore + TTS — ~3.5 GB Android-side memory back. Persists across reboots.
# (Re-check after OTAs; OTA can re-enable disabled packages.)
bash pixel/android-pkg-state.sh disable
```

Without this, AiCore inference triggers ~3.8 GB DMA-BUF spikes that
trigger Android's LMK to kill the Podroid app — taking the VM down.
See [`android-disabled-packages.md`](android-disabled-packages.md) and
[`podroid/README.md`](podroid/README.md) "Memory tuning" section.

## Architecture

```
                                  ┌────────────────────────────┐
                                  │  Laptop (Tailscale)        │
                                  └─────────────┬──────────────┘
                                                │ ssh <user>@pubuntu (Tailscale MagicDNS)
                                                ▼
 ┌──────────────────────────────────────────────────────────────────────┐
 │                            PIXEL 10                                  │
 │                                                                      │
 │  ┌─────────────────────────┐                ┌──────────────────────┐ │
 │  │ Stock Terminal app      │   ssh (LAN /   │ Podroid app          │ │
 │  │ (Debian VM, has GPU)    │   Tailscale)   │ (Alpine VM, AVF/pKVM)│ │
 │  │                         │ ─────────────► │  └─ privileged LXC   │ │
 │  │ - virglrenderer flag    │                │     'pubuntu' (Ubuntu)│ │
 │  │   (zink Vulkan 1.3) ✔   │                │     ├─ sshd          │ │
 │  │ - sway + foot + firefox │                │     ├─ Docker        │ │
 │  │ - external monitor      │                │     ├─ sesh + nvim   │ │
 │  │   via Android 16        │                │     ├─ nvm + Node    │ │
 │  │   Desktop Mode          │                │     ├─ Tailscale     │ │
 │  └─────────────────────────┘                │     └─ authorized    │ │
 │                                             │        pubkeys/      │ │
 │                                             └──────────────────────┘ │
 └──────────────────────────────────────────────────────────────────────┘
```

The Stock Terminal does **not** forward X11 from the LXC. The split:

- **All GUI apps run inside the Stock Terminal Debian itself** —
  natively, with full Tensor GPU acceleration via Zink/Vulkan.
- **The LXC stays headless.** You SSH into it from a foot terminal
  inside sway, and do all your compute / Docker / coding there.
- **Sway, foot, firefox** live on the GUI side because they need the
  GPU; **Docker, dev tools, sesh, project code** live on the LXC side
  because that's the persistent dev environment.

## Why this split

| Concern | Decision | Why |
|---|---|---|
| Compute base distro | Ubuntu (in LXC) — glibc | Stock Debian VM is too thin to live in; Ubuntu in LXC gets full glibc + Docker compatibility |
| CPU virtualization | both VMs on AVF (pKVM) | near-native speed; software emulation (QEMU TCG) is 10–100× slower |
| GPU | Stock Terminal only | Podroid (user-space app) can't reach `/dev/mali`; Stock Terminal is a privileged system component that can |
| LXC priv level | **privileged** | Single-user personal box. Saves fighting fuse-overlayfs (Docker) and TUN-passthrough (Tailscale). Container escape lands on Alpine host — itself sandboxed by AVF — so the blast radius is bounded |
| Network | Tailscale **inside the LXC** | One hop, MagicDNS, works on/off Wi-Fi. Laptop reaches `ssh <user>@pubuntu` directly |
| WM | sway (in Stock Terminal) | Native Wayland; Stock Terminal's display is Wayland-backed by Zink → smoothest path. Avoids any X11/SSH-forwarding fragility |
| Persistence | bind-mount `/mnt/shared/projects/` into LXC | Survives Podroid app wipes; `tar` backups of `/var/lib/lxc/pubuntu/` land on the same shared dir |

## Curl-able fresh-machine bootstraps

- [`../bootstrap-ssh.sh`](../bootstrap-ssh.sh) — sshd + key gen + authorize repo pubkeys (any fresh Linux)
- [`../bootstrap-git.sh`](../bootstrap-git.sh) — git install + GitHub key-paste flow + clone (assumes ssh key already exists; run bootstrap-ssh.sh first)
- [`../pubkeys/`](../pubkeys/) — public keys authorized for SSH access; drop a new `.pub`, re-run the appropriate bootstrap-ssh
- [`../SECURITY.md`](../SECURITY.md) — secrets policy for this repo
