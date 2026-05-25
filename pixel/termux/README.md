# Termux helpers for the Pixel Linux setup

Termux serves two purposes in this setup:

1. **Offline recovery bridge.** When the Pixel is wiped or one of the
   AVF VMs gets clobbered, Termux is the one Linux environment on the
   phone that survives because it's a regular Android app on `/sdcard/`-
   backed storage. Bundling the linux-setups repo + custom Podroid APK
   + latest VM backups + SSH keys into one `termux-backup` tarball
   makes the whole rig recoverable from a blank phone with no laptop
   and no internet.
2. **Self-contained ops console.** All the laptop-side scripts in this
   repo (sync-backups, adb-setup, etc.) are pure ssh+scp / adb — so
   they run identically from Termux on the Pixel itself. Useful when
   you're away from your laptop.

## Scripts

| Script | Runs in | Purpose |
|---|---|---|
| [`init.sh`](init.sh) | Termux | One-shot package install + SSH key + repo clone. Run once on fresh Termux. |
| [`gather-bundle.sh`](gather-bundle.sh) | Termux | Pull latest VM backups + APK + repo state, then `termux-backup` to `/sdcard/`. |
| [`restore-bundle.sh`](restore-bundle.sh) | Termux | Verify a `termux-restore`'d bundle and print the next-step recovery commands. |

## First-time setup (fresh Termux)

```sh
# In Termux, after install:
curl -fsSL https://raw.githubusercontent.com/rynobey/linux-setups/master/pixel/termux/init.sh | bash
```

`init.sh` will:

- `pkg install` everything we need (git, openssh, android-tools,
  termux-tools, termux-api, curl/wget, tar/xz, nano, coreutils)
- Run `termux-setup-storage` so `~/storage/shared/` maps to `/sdcard/`
- Generate an `id_ed25519` SSH key for this Termux (if missing)
- Clone the linux-setups repo into `~/linux-setups`

After it finishes, copy the printed pubkey to GitHub (so this Termux
can `git clone` private repos) and to the VMs' `authorized_keys` (so
the sync/adb scripts can ssh in).

## Making a recovery bundle

```sh
~/linux-setups/pixel/termux/gather-bundle.sh
```

What this does:

1. `git pull` the linux-setups repo
2. Sanity-check the custom Podroid APK is at `~/apks/podroid-debug.apk`
   (downloaded from your GH Actions build — drop it here manually)
3. Pull the latest backups for both VMs into `~/recovery-bundle/`:
   - Podroid LXC via `pixel/podroid/sync-backups.sh --pull`
   - Stock Terminal via `pixel/stock-terminal/sync-backups.sh --pull`
4. Run `termux-backup` to produce a single `tar.xz` at
   `~/storage/shared/termux-recovery-<date>.tar.xz`. This file is on
   Android's public `/sdcard/Download/`, so it survives Termux
   uninstall, Podroid uninstall, Stock Terminal data-wipe, and every
   other app-level event short of a full factory reset.

Useful flags:

```sh
./gather-bundle.sh --skip-sync          # don't try to pull fresh VM backups
./gather-bundle.sh --skip-apk           # don't fail if APK missing
./gather-bundle.sh --dest /sdcard/Foo/bundle.tar.xz  # custom output path
```

Env overrides for the VM connection details:

- `PODROID_HOST` / `PODROID_PORT` / `PODROID_USER`
- `TERMINAL_HOST` / `TERMINAL_PORT` / `TERMINAL_USER`
- `PODROID_APK` (default `~/apks/podroid-debug.apk`)

Defaults match what the per-VM `sync-backups.sh` scripts use.

## Bare-phone recovery (no laptop, no internet)

```
fresh phone after factory reset
    │
    ├─ Sideload Termux APK from F-Droid (or have it on the SD/USB you boot with)
    │
    ▼
Install Termux, open it
    │
    ▼
termux-restore /sdcard/Download/termux-recovery-<date>.tar.xz
    │  (Termux now has linux-setups, APK, VM backups, SSH keys, dotfiles)
    │
    ▼
~/linux-setups/pixel/termux/restore-bundle.sh
    │  (verifies bundle contents, prints next-step commands)
    │
    ▼
Follow the printed steps:
    1. Sideload Podroid APK via termux-open --send ~/apks/podroid-debug.apk
    2. adb pair / adb-setup.sh from this Termux
    3. Push backups + restore each VM via the sync-backups.sh scripts
```

End-to-end recovery in ~30–60 minutes, no laptop, no internet (after
the initial Termux APK sideload). The custom Podroid build is included
in the bundle — no need to wait for GH Actions or hit GitHub.

## Periodic refresh

The bundle is only as good as its newest contents. Schedule a refresh
to whatever cadence matches your tolerance for losing recent state:

```sh
# In Termux:
crontab -e
# add e.g. weekly:
#   0 3 * * 0  $HOME/linux-setups/pixel/termux/gather-bundle.sh
```

(Cron in Termux needs `pkg install cronie` + `crond` running — a
foreground notification keeps it alive.) Or just run it manually
before any meaningful work session ends.

## Security trade-offs

The bundle contains your SSH keys. Treat it accordingly:

- **Where it sits**: `/sdcard/Download/` is readable by any app with
  `READ_EXTERNAL_STORAGE` (= most apps). Don't trust a phone with
  arbitrary installs to keep this private.
- **Encryption**: `termux-backup` produces a plain `tar.xz` —
  *not* encrypted. If you want passphrase encryption, wrap the
  output with `age -p`:
  ```sh
  ./gather-bundle.sh --dest /tmp/bundle.tar.xz
  age -p /tmp/bundle.tar.xz > ~/storage/shared/termux-recovery-$(date +%F).tar.xz.age
  rm /tmp/bundle.tar.xz
  ```
  On recovery: `age -d <file>.age > /tmp/bundle.tar.xz && termux-restore /tmp/bundle.tar.xz`.
- **APK signature**: the custom Podroid APK is signed with whatever
  local keystore your GH Actions runner generated. Android shows
  "from unknown source" on install. If you lose the keystore, future
  upgrades to your fork's APK require uninstall + reinstall.

The VM backups inside the bundle (`pubuntu-*.tar.gz.age`,
`stock-terminal-*.tar.gz.age`) are already age-encrypted with their
own passphrases — so even an unencrypted bundle doesn't expose
the LXC/Terminal data without the per-backup passphrases.
