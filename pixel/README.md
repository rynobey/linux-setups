# Pixel 10 — hybrid dev environment

A real Linux dev box on a Pixel 10 (Android 16), splitting work across
**two AVF-backed VMs** to get both maximum compute power *and*
hardware-accelerated graphics:

| Side | What it does | Where |
|---|---|---|
| **Podroid + Ubuntu LXC** | headless compute — Docker, sesh, dev tools, sshd | [`podroid/`](podroid/) |
| **Stock Linux Terminal** | GPU-accelerated GUI host — sway tiling WM + foot + browser | [`stock-terminal/`](stock-terminal/) |

Both run on the same Pixel via the **Android Virtualization Framework
(AVF / pKVM)** — near-native CPU speed, no software emulation. They
talk to each other (and your laptop) over Tailscale.

## Architecture

```
                                  ┌────────────────────────────┐
                                  │  Laptop (Tailscale)        │
                                  └─────────────┬──────────────┘
                                                │ ssh <user>@pixel-dev (Tailscale MagicDNS)
                                                ▼
 ┌──────────────────────────────────────────────────────────────────────┐
 │                            PIXEL 10                                  │
 │                                                                      │
 │  ┌─────────────────────────┐                ┌──────────────────────┐ │
 │  │ Stock Terminal app      │   ssh (LAN /   │ Podroid app          │ │
 │  │ (Debian VM, has GPU)    │   Tailscale)   │ (Alpine VM, AVF/pKVM)│ │
 │  │                         │ ─────────────► │  └─ privileged LXC   │ │
 │  │ - virglrenderer flag    │                │     'dev' (Ubuntu)   │ │
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

The Stock Terminal does **not** forward X11 from the LXC. The split is
much cleaner than that:

- **All GUI apps run inside the Stock Terminal Debian itself** —
  natively, with full Tensor GPU acceleration via Zink/Vulkan.
- **The LXC stays headless.** You SSH into it from a foot terminal
  inside sway, and do all your compute / Docker / coding there.
- **Sway, foot, firefox** live on the GUI side because they need the
  GPU; **Docker, dev tools, sesh, project code** live on the LXC side
  because that's the persistent dev environment.

## Bootstrap order (fresh device)

1. **Stock Terminal — one-time hardware accel enable.**
   See [`stock-terminal/README.md`](stock-terminal/README.md). Pair
   ADB (or use Termux), `touch /sdcard/linux/virglrenderer`, cold-boot
   the Terminal app, verify with `glxinfo | grep renderer` →
   `zink Vulkan 1.3`.

2. **Podroid — install the APK, enable AVF backend.**
   See [`podroid/README.md`](podroid/README.md) Step 1.

3. **Create the Ubuntu LXC** on the Alpine host inside Podroid:
   `./podroid/01-create-lxc.sh`.

4. **Create a non-root sudo user** inside the LXC. `lxc-attach` lands
   you as root, but everything from here runs as a regular user so
   pubkeys / SSH / git / docker-group land on the right account.
   See [`podroid/README.md`](podroid/README.md) Step 3 for the
   curl-able `create-user.sh` invocation.

5. **Bootstrap SSH access** as that user:
   `curl -fsSL <repo>/bootstrap-ssh.sh | bash`. Your laptop (whose
   pubkey is in `pubkeys/`) can now SSH in.

6. **Bootstrap git** as that user (so the LXC can also clone/push):
   `curl -fsSL <repo>/bootstrap-git.sh | bash` — generates the LXC's
   own key, walks you through adding it to GitHub, clones this repo.
   (Use `bootstrap-git-public.sh` instead if you only need read access.)

7. **Run the LXC orchestrator** from the cloned repo:
   `./podroid/02-bootstrap-lxc.sh` — authorizes the rest of `pubkeys/`,
   installs Docker, sesh, nvm/Node. (Tailscale is intentionally split
   out — see next step.)

8. **Install Tailscale** as the final LXC step:
   `./podroid/03-install-tailscale.sh`. `tailscale up` drops the
   current SSH/lxc-attach session, so it has to be last. Reconnect
   afterwards via `ssh <user>@pixel-dev` (MagicDNS).

9. **GUI side** on the Stock Terminal:
   `./stock-terminal/install-gui.sh` (sway + foot + firefox), then
   `./stock-terminal/connect-dev.sh` to drop into a foot terminal
   pre-SSH'd into the LXC.

## Why this split

| Concern | Decision | Why |
|---|---|---|
| Compute base distro | Ubuntu (in LXC) — glibc | Stock Debian VM is too thin to live in; Ubuntu in LXC gets full glibc + Docker compatibility |
| CPU virtualization | both VMs on AVF (pKVM) | near-native speed; software emulation (QEMU TCG) is 10–100× slower |
| GPU | Stock Terminal only | Podroid (user-space app) can't reach `/dev/mali`; Stock Terminal is a privileged system component that can |
| LXC priv level | **privileged** | Single-user personal box. Saves fighting fuse-overlayfs (Docker) and TUN-passthrough (Tailscale). Container escape lands on Alpine host — itself sandboxed by AVF — so the blast radius is bounded |
| Network | Tailscale **inside the LXC** | One hop, MagicDNS, works on/off Wi-Fi. Laptop reaches `ssh <user>@pixel-dev` directly |
| WM | sway (in Stock Terminal) | Native Wayland; Stock Terminal's display is Wayland-backed by Zink → smoothest path. Avoids any X11/SSH-forwarding fragility |
| Persistence | bind-mount `/mnt/shared/projects/` into LXC | Survives Podroid app wipes; `tar` backups of `/var/lib/lxc/dev/` land on the same shared dir |

## Useful pointers

- [`../bootstrap-ssh.sh`](../bootstrap-ssh.sh) — curl-able SSH bootstrap (any fresh Linux)
- [`../bootstrap-git.sh`](../bootstrap-git.sh) — curl-able git+ssh-key bootstrap (any fresh Linux)
- [`../pubkeys/`](../pubkeys/) — public keys authorized for SSH access; drop a new `.pub`, re-run `bootstrap-ssh.sh` or `podroid/authorize-pubkeys.sh`
- [`../SECURITY.md`](../SECURITY.md) — secrets policy for this repo
