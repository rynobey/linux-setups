# Termux helpers for the Pixel Linux setup

Termux serves two purposes in this setup:

1. **Offline recovery bridge.** Termux is the one Linux environment on
   the Pixel that survives a Podroid wipe, since it's a regular Android
   app on `/data/data/com.termux/`-backed storage. A recovery bundle of
   `$PREFIX` + `$HOME` on `/sdcard/Download/` lets you rebuild from a
   freshly-installed Termux with no laptop and no internet.

2. **Self-contained ops console.** The same client/ entry scripts that
   work from a laptop also work from Termux. So everyday workflows
   (backup, restore, deploy, bootstrap, etc.) can be driven from the
   Pixel itself. See [`../client/`](../client/) for the entry scripts.

## What's in this directory

| Script | Purpose |
|---|---|
| [`01-init-termux.sh`](01-init-termux.sh) | One-shot fresh Termux setup: packages, storage, ed25519 key, repo clone, sshd. |
| [`02-snapshot.sh`](02-snapshot.sh) | Create a recovery snapshot: termux-backup of `$PREFIX` + age-encrypted tar of `$HOME` → `/sdcard/Download/`. |
| [`03-restore-snapshot.sh`](03-restore-snapshot.sh) | Restore from a snapshot on a freshly-installed Termux. |
| [`06-deploy-runtime-scripts.sh`](06-deploy-runtime-scripts.sh) | Install Termux-side prereqs (mesa, vulkan loader, virgl, socat, xauth) + deploy `~/start-x11.sh`, `~/stop-x11.sh`, `~/sync-x11-cookie.sh`, `~/runtime.env`. |
| [`setup-desktop.sh`](setup-desktop.sh) | Convenience wrapper around 06. |

**The Podroid / LXC workflows aren't in here** — they're in
[`../client/`](../client/) (cross-context: Termux + laptop). This dir
only holds Termux-specific entry scripts.

## Quick-start flow on a fresh device

```
01-init-termux.sh                       # Termux base (packages, ssh, repo, sshd)
setup-desktop.sh                         # install Termux X11/Mesa/virgl + runtime scripts
~/start-x11.sh                           # bring up Termux:X11 + direct-X bridge for pubuntu
02-snapshot.sh                           # recovery snapshot of $PREFIX + $HOME
```

## First-time setup (fresh Termux)

```sh
# Option A — clone first, then run
pkg install -y git
git clone https://github.com/rynobey/linux-setups ~/linux-setups
bash ~/linux-setups/pixel/termux/01-init-termux.sh

# Option B — direct curl|bash
curl -fsSL https://raw.githubusercontent.com/rynobey/linux-setups/master/pixel/termux/01-init-termux.sh | bash
```

`01-init-termux.sh` will:

- `pkg install` everything we need (git, openssh, android-tools,
  termux-tools, termux-api, curl/wget, tar/xz/age, nano, coreutils)
- Run `termux-setup-storage` so `~/storage/shared/` maps to `/sdcard/`
- Generate an `id_ed25519` SSH key (if missing)
- Clone the linux-setups repo into `~/linux-setups`
- Authorize the repo's `pubkeys/*.pub` into `~/.ssh/authorized_keys`
- Start `sshd` on port 8022 so other devices can SSH into Termux

After it finishes, copy the printed pubkey to GitHub and to the VMs'
`authorized_keys` (Alpine, pubuntu, Stock Terminal) so the client/
scripts can ssh in.

## Recovery snapshot

```sh
~/linux-setups/pixel/termux/02-snapshot.sh
```

Produces three artifacts in `~/storage/shared/Download/`:

1. **`termux-prefix-<date>.tar.xz`** — `termux-backup` of `$PREFIX`
   (all installed Termux packages). Not encrypted (public package
   state only). NOTE: prefix restore is fragile across Termux
   re-installs (SELinux-context mismatch can confuse some apps).
   In cross-install scenarios skip with `--skip-prefix` and reinstall
   packages from scratch after the `$HOME` restore.
2. **`pixel-home-<date>.tar.age`** — full `$HOME` tarball,
   age-encrypted with a passphrase you provide. Contains your SSH
   keys, the linux-setups repo, downloaded APKs, the `~/.Xauthority`
   cookie for direct-X, and any LXC backups in `~/recovery-bundle/`.
3. **`03-restore-snapshot.sh`** — copy of this directory's restore
   script, placed alongside the artifacts so a fresh Termux can find it.

All three sit on Android public storage, so they survive Termux
uninstall and even a factory reset (everything short of formatting
the userdata partition).

⚠ **Test the snapshot decrypts** before relying on it (otherwise a
passphrase typo silently produces an unrecoverable bundle):

```sh
age -d ~/storage/shared/Download/pixel-home-*.tar.age | tar tf - | head
```

## Bare-phone recovery (no laptop, no internet)

```
fresh phone after factory reset / Termux uninstall
    │
    ├─ Sideload Termux APK from F-Droid
    │
    ▼
Install Termux, open it
    │
    ▼
termux-setup-storage   (Allow on the popup)
    │
    ▼
bash ~/storage/shared/Download/03-restore-snapshot.sh
    │  Step 1: termux-restore the PREFIX tar — brings back age + ssh + tools
    │  Step 2: age -d the HOME tar | tar xf -  — brings back ~/.ssh + repo + ...
    │
    ▼
~/linux-setups/pixel/client/01-deploy-podroid.sh   # install Podroid APK
~/linux-setups/pixel/client/04-restore-lxc.sh --latest   # restore LXC from bundled backup
```

End-to-end recovery in ~30–60 minutes, no laptop, no internet (after
the initial Termux APK sideload).

## Periodic refresh

The snapshot is only as good as its newest contents. Schedule it to
whatever cadence matches your tolerance for losing recent state:

```sh
# Termux:
crontab -e
# weekly Sunday 3am:
#   0 3 * * 0  $HOME/linux-setups/pixel/termux/02-snapshot.sh
```

(Cron on Termux needs `pkg install cronie` + `crond` running with a
foreground notification.) Or just run it manually before stopping work.

## Security trade-offs

- `/sdcard/Download/` is readable by any Android app with broad storage
  permission. The HOME tar is age-encrypted, so the SSH private key is
  safe behind your passphrase. The PREFIX tar is not encrypted (just
  package state — no secrets).
- The Podroid APK signature is from your GH Actions keystore. Future
  upgrades require the same keystore — back up `~/.android/debug.keystore`
  separately if losing it would be a problem.
- The LXC backups inside `~/recovery-bundle/` (which the HOME tar
  includes) are *individually* age-encrypted with their own passphrases.
  So the HOME tar passphrase + the LXC backup passphrase are both
  required to actually restore the VM — slight defense in depth.
