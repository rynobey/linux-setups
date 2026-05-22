# linux-setups

Personal collection of reproducible Linux setups across devices — quick
deploy from a fresh install, quick recover after a wipe.

## Setups

| Setup | Target | What it does |
|---|---|---|
| [pixel10-avf/](pixel10-avf/) | Pixel 10, Android 16, AVF Linux Terminal | Headless Debian VM accessed over SSH via Tailscale |

## Conventions

Each setup lives in its own subdirectory and is self-contained:

```
<setup-name>/
├── README.md          # prerequisites + step-by-step
├── setup-*.sh         # one or more idempotent install scripts
└── (optional config files, dotfiles, systemd units, etc.)
```

Naming: `<device-or-platform>-<distinguishing-tag>`, lowercase, kebab-case.
Examples: `pixel10-avf`, `laptop-arch`, `pc-ubuntu`, `homeserver-debian`.

Scripts should be:

- **Idempotent** — safe to re-run after partial completion
- **Non-interactive where possible** — prompts only for things that genuinely
  need a human (passwords, key pastes)
- **Self-documenting at the top** — header comment that names the target and
  links back to the per-setup README

The per-setup README is the source of truth for what to do and in what
order. This top-level README is just the index.

## Secrets

Before adding anything that touches credentials, read [SECURITY.md](SECURITY.md).
Short version: auth keys never in the repo, service credentials in a
password manager, setup-bound config secrets encrypted with `age`. The
root [`.gitignore`](.gitignore) is a backstop, not the strategy.
