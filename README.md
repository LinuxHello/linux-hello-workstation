# LinuxHello organisation and monorepo bootstrap

Status: **UNTESTED against the GitHub API.** Shell scripts pass shellcheck; the repo template passes `cargo fmt --check`, `cargo clippy -D warnings` and `cargo test` (Rust 1.99.1). `cargo-deny`, `cargo-audit` and the CI workflow have not been run.

## Prerequisites (one-time, by you)

1. `gh auth login` then `gh auth refresh -s admin:org,repo,workflow`. The token stays in your keyring; never paste it anywhere.
2. Require 2FA for the organisation (web UI only): https://github.com/organizations/LinuxHello/settings/security
3. The two architecture files present in `ARCH_SRC` (default: the Drive-synced vault's `Architecture/`).

## Run

```sh
make preflight   # read-only; fails closed on any missing prerequisite
make all         # preflight → org → repo → seed → protect → verify
make verify      # read-only state dump, any time
```

| Target | Changes | Idempotent |
| :-- | :-- | :-- |
| `org` | Org description, base permission read, members cannot create or fork repos, web commit sign-off, Actions allow-list, read-only workflow token | Yes |
| `repo` | Creates `LinuxHello/linux-hello` (public), squash-only, secret scanning and push protection, Dependabot, private vulnerability reporting | Yes |
| `seed` | Copies `repo/` (including the `docs/` Obsidian vault and Claude Project instructions) and the sanitised architecture docs to `CLONE_DIR`, first signed-off commit, push to `main` | Skips if `main` exists |
| `protect` | Ruleset on `main` (PR required, signed and linear history, required checks), labels, milestone M0 | Yes |

Rollback: everything is reversible in the web UI; the repo can be deleted from Settings → Danger Zone (needs your confirmation there).
