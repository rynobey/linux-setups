# Podroid + Ubuntu LXC — headless compute side

The compute half of the hybrid Pixel setup. Podroid hosts an Alpine VM
on AVF; inside it we run a privileged **Ubuntu Noble LXC** (`pubuntu`)
which is where all the actual work happens — Docker, sesh, nvim, the
project codebase, sshd reachable over Tailscale.

GUI / GPU stuff lives in the Stock Terminal — see
[`../stock-terminal/`](../stock-terminal/). The two never share state.

## What's in this directory

`pixel/podroid/helper/` holds the scripts that **run on the Alpine
host** (called from your client machine via
`pixel/client/helper/alpine-run.sh`):

- `create-lxc.sh` — bootstrap Alpine + create the `pubuntu` LXC
- `backup.sh` — snapshot the LXC into an age-encrypted `.tar.gz.age`
- `restore.sh` — restore a backup into the LXC (rolls back gracefully)
- `sync-backups.sh` — scp backups between Alpine and a client
- `adb-setup.sh` — ADB-side Podroid config (PPK disable + AVF perms + storage)

**You don't run these directly.** Use the `client/` entry scripts from
this repo's root — see [`../README.md`](../README.md) for the workflow
→ command table.

The actual deployment workflow lives at:

```
pixel/client/01-deploy-podroid.sh        # Install/replace Podroid APK + ADB
pixel/client/05-setup-lxc-fresh.sh       # Fresh LXC + user + ssh + deps + Tailscale
pixel/client/04-restore-lxc.sh           # Push + restore an LXC backup
pixel/client/03-backup-lxc.sh            # Create + pull an LXC backup
```

The `lxc/helper/*.sh` scripts (one dir up at `pixel/lxc/helper/`) run
**inside the pubuntu LXC** for user creation, SSH bootstrap, deps,
Tailscale. They get streamed in via `pixel/client/helper/lxc-run.sh`.

## Why this layout

- **Podroid for the host VM**, not the Stock Terminal: Podroid gives
  us a clean Alpine + LXC ecosystem with built-in persistence and port
  forwarding, *and* uses AVF/pKVM for near-native performance.
- **Ubuntu (in LXC), not Alpine**: glibc means every Docker image, every
  pre-built Node/Python wheel, every Go ARM64 binary just runs. Alpine's
  musl breaks a non-trivial slice of the ecosystem.
- **Privileged LXC**, not unprivileged: single-user box, simpler
  Docker (overlay2) and Tailscale (TUN passthrough) setup. The blast
  radius is bounded — escape lands you on Alpine, itself sandboxed by AVF.

## Podroid app setup (one-time)

After `pixel/client/01-deploy-podroid.sh` installs the APK, open
the Podroid app and:

- **Backend**: AVF (the only option on Pixel 10 with AVF/pKVM)
- **VM RAM**: start at **4 GB**, can push to 6 GB after AiCore is disabled
  and you've verified ballooning is engaged
- **Port forwarding**: ensure `9922 → 22` is enabled (sshd into Alpine)
- **Storage access**: ON (for `/mnt/downloads` ↔ `/sdcard/Download` share —
  ⚠ silently broken on current Pixel 10 / Android 16 firmware; backups
  go to `/var/lib/podroid-backups/` on Alpine instead and you `sync-backups.sh`
  them off the device)

### Verifying AVF is actually in use

Without AVF, Podroid falls back to QEMU TCG software emulation — 10-100×
slower. Confirm AVF is engaged from inside Alpine after the VM boots:

```sh
ssh root@localhost -p 9922 'dmesg | grep -iE "hyperv|kvm|cpuid"'
# Look for: pKVM / Booting Linux on physical CPU 0x0 / no QEMU TCG mentions
```

Or via Podroid's own log:

```sh
adb logcat -d | grep -i 'AvfEngine\|protectedVm'
# Look for: AvfEngine: protectedVm=false (device supports non-protected VMs)
```

If you see TCG anywhere, the AVF permissions weren't granted to Podroid.
Re-run `pixel/client/02-adb-settings.sh`.

### Memory tuning — disable Android services that compete with the VM

**Required for stable 6 / 8 GB allocation.** Skip if you're staying on 2-3 GB.

Pixel's on-device AI service (`com.google.android.aicore`) holds up to
**3.8 GB of Tensor / DMA-BUF memory** when running inference (Magic
Compose, Smart Reply, Now Brief). The spike triggers Low-Memory-Killer
kills of Podroid whenever AiCore happens to be inferring during a
memory-heavy VM operation. Empirically confirmed.

```sh
bash ../android-pkg-state.sh status      # see current state + memory
bash ../android-pkg-state.sh disable     # disable AiCore + TTS (default tracked list)
bash ../android-pkg-state.sh enable      # restore them later if you want
```

Measured impact on a Pixel 10 / 12 GB / Android 16, after `disable`:

- MemAvailable: 764 MB → **4.31 GB**
- ZRAM swapped: 4.5 GB → 3.1 GB (apps that were paged out got revived)
- DMA-BUF heap: 4.2 GB → **425 MB** (AiCore's Tensor memory released)

**What you lose:** Magic Compose in Gboard, Smart Reply in Messages,
Now Brief, Google TTS. **What's kept:** Google Assistant (cloud), voice
typing, camera AI features.

Full list + re-enable steps in [`../android-disabled-packages.md`](../android-disabled-packages.md).

## Backup / restore

The recommended workflow runs **entirely from your client machine**:

```sh
# Create + pull an encrypted backup
bash ../client/03-backup-lxc.sh

# Restore (push backup back + extract inside LXC, auto-creates LXC if needed)
bash ../client/04-restore-lxc.sh --latest
```

⚠ **Test that backups decrypt** before doing anything destructive
(uninstalling Podroid, factory reset, etc.):

```sh
age -d ~/recovery-bundle/pubuntu-*.tar.gz.age | head -c 1024 > /dev/null && echo OK
```

A passphrase typo at create time silently produces an unreadable backup
(`age -p` confirms by retyping but a consistent typo passes both
checks). Lost backups have no recovery path.

### Persistence model

```
Client (laptop / iPad / fresh Termux)  ← actually durable
    ~/recovery-bundle/
    or ~/podroid-backups/
        ├─ pubuntu-2026-05-25-1530.tar.gz.age       (encrypted snapshots)
        └─ pubuntu-2026-05-26-0945.tar.gz.age
        ▲
        │ pulled via sync-backups.sh (scp over Tailscale or
        │ Podroid's port forward 9922 from Termux on the Pixel)
        │
Alpine host VM (inside Podroid app sandbox)
    /var/lib/podroid-backups/                       (what backup.sh writes to)
        ├─ pubuntu-2026-05-25-1530.tar.gz.age
        └─ ...
        ▲
        │ create-lxc.sh bind-mounts /mnt/downloads → /sdcard/Download
        │ (currently broken on Pixel 10 / Android 16, so backups stay
        │  on Alpine until sync-backups.sh moves them off)
        ▼
Ubuntu LXC
    /  (everything in the LXC rootfs; backup.sh tars it)
```

| Event | LXC rootfs | Alpine /var/lib/podroid-backups | Client copies |
|---|---|---|---|
| LXC destroyed + recreated | ❌ lost | ✅ kept | ✅ kept |
| Alpine VM rebooted | ✅ | ✅ | ✅ |
| Podroid app restarted | ✅ | ✅ | ✅ |
| Podroid app-data cleared | ❌ | ❌ | ✅ |
| Podroid uninstalled | ❌ | ❌ | ✅ |
| Android factory reset | ❌ | ❌ | ✅ |

So: take backups frequently, `sync-backups.sh --pull` them off Alpine
on a meaningful cadence (built into `client/03-backup-lxc.sh`), and
keep your client backed up too.

### Running backups/restores safely

Long backup/restore operations can be killed by Android's LMK if
the VM is large and AiCore is enabled — see Memory tuning above.
The Alpine-side scripts will warn if you're not running in tmux.

Recommended mitigations (apply all of them for restore):

1. **Disable AiCore** (see Memory tuning).
2. **Drop VM RAM** to 2-3 GB for the duration of the heavy IO step.
3. **Plug in to charge + Stay awake on**: Settings → Developer options.
4. **Mark Podroid as battery-unrestricted**: Settings → Apps → Podroid → Battery.
5. **Close heavy Android apps** before kicking off (Chrome, Maps, etc).
6. **Run via tmux on the Alpine side** (the `restore.sh` script warns
   if you're not). Survives SSH disconnect mid-flight.

If a backup *still* gets killed, peek at LMK activity with
`adb shell dumpsys activity processes | grep -A3 podroid` — climbing
`oom_adj` values right before the kill confirm Android did it.

### What's preserved across a backup/restore

The whole LXC rootfs:

- Your user account, home dir, shell history, dotfiles
- All apt-installed packages (Docker, Tailscale, sesh, etc.)
- **Tailscale identity** (`/var/lib/tailscale/tailscaled.state`) — the
  restored LXC rejoins the tailnet as the same node, no reauth needed
- Docker images, containers, volumes
- LXC's own networking config

Not preserved: anything in the Alpine host outside the LXC (sshd host
keys, host apk packages). Nothing important lives there in this setup.

## Troubleshooting

- **`docker info` errors / iptables noise**: check `create-lxc.sh`'s
  config additions made it into `/var/lib/lxc/pubuntu/config` and the
  container was restarted after. The `lxc.apparmor.profile = unconfined`
  + `lxc.cap.drop =` lines are load-bearing.
- **`tailscale up` says "tun device not available"**: same root cause —
  `/dev/net/tun` isn't bound in. See `lxc/helper/install-tailscale.sh`'s
  error output for the exact config lines.
- **Deps bootstrap fails mid-way**: each step is idempotent. Set
  `SKIP_DOCKER=1 / SKIP_TOOLCHAINS=1 / SKIP_SESH=1 / SKIP_NODE=1` for
  steps that already succeeded and re-run `client/07-bootstrap-deps-lxc.sh`.
- **`pixel/client/04-restore-lxc.sh` says "incorrect passphrase"**: the
  passphrase doesn't match the file. There's no recovery — `age -p`
  confirms by retyping but consistent typos pass both checks. Try
  decrypting locally first: `age -d <file>.tar.gz.age | head -c 1024 > /dev/null`.
