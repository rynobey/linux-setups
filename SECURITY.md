# Security and secrets policy

How this repo handles secrets. Read this before adding any setup or
content that touches credentials.

## Tiers by sensitivity

### 1. Authentication material — never in the repo

SSH private keys, GPG private keys, age master keys, hardware-token
backups, root CA private keys.

- **Not in this repo. Not encrypted in this repo. Not anywhere in this
  repo.**
- Regenerate per device on restore. New device → `ssh-keygen` → add the
  new pubkey to GitHub, Tailscale, homelab, etc.
- Backing up private auth keys defeats device isolation. If a device is
  lost or stolen, you want one revocation step (remove the key from
  trust stores), not "hope nobody finds my backup."

### 2. Service credentials — in a password manager

API tokens, app passwords, restic repo passphrases, Backblaze B2
application keys, GitHub PATs.

- Store in a password manager (Bitwarden, 1Password, `pass`, etc.).
- Setup scripts prompt for them at restore time, or pull from the
  manager's CLI (`bw get`, `op read`, `pass show`).
- Never hard-code, never check in even encrypted (rotation friction
  outweighs convenience).

### 3. Setup-bound config secrets — encrypted in repo

VNC passwords, low-risk credentials whose value is tied to the
setup and benefits from being versioned with it.

- Encrypted with [`age`](https://age-encryption.org/) using a recipient
  key whose private half lives in your password manager (and ideally on
  a YubiKey).
- Convention: encrypted files end in `.age`. The corresponding setup
  script documents how to decrypt them at restore time.
- The age recipient *pubkey* can be committed to the repo. The
  *private* key absolutely cannot.

## Hygiene checklist

- [`.gitignore`](.gitignore) at the repo root blocks common dangerous
  patterns. Treat as backstop; the tiering above is the actual strategy.
- Run `gitleaks` (or `trufflehog`) as a pre-commit hook so staged
  secrets are caught before they leave your machine:
  ```bash
  pre-commit install
  # with .pre-commit-config.yaml referencing gitleaks
  ```
- On GitHub: enable **secret scanning** and **push protection** at the
  repo level — they block known token formats even if local hooks miss.
- Sign commits:
  ```bash
  git config --global commit.gpgsign true
  # or with SSH signing:
  git config --global gpg.format ssh
  git config --global user.signingkey ~/.ssh/id_ed25519.pub
  ```

## When you slip

If a secret lands in a commit:

1. **Rotate first**, then clean. The moment a secret touches a remote,
   assume it's compromised. History scrubbing without rotation is
   theatre.
2. Purge from history with `git filter-repo` (not `filter-branch`) or
   BFG Repo-Cleaner, then force-push.
3. Notify any service whose credential leaked.
4. Audit access logs where you can.

## Adding a new setup

When writing `<setup>/setup-*.sh`:

- Don't read secrets from files in the repo unless they're `.age` and
  the decryption flow is explicit and documented.
- Prompt the user interactively for credentials, or read from a
  password-manager CLI.
- Document in the per-setup README which secrets the user needs to have
  ready before running.
- If the setup creates a credential (e.g., a VNC password), the script
  should set it via the standard tool (`vncpasswd`) rather than writing
  the secret to disk in a custom location.
