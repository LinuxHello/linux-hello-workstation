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

## Unattended implementer (ADR-0007)

Status: **UNTESTED against a live model and a live user manager.** `local/test-lh-implement-next.sh` tests the loop's logic with fake `gh`, model server and implementer; `shellcheck local/*.sh` is clean.

One tick of `local/lh-implement-next.sh`:
1. takes a lock, so ticks never overlap;
2. skips if the model server has another model loaded or `LH_BUSY_CHECK` reports the GPU busy;
3. picks the oldest open `status:ready` issue that has an `## Implementation brief`;
4. cleans the clone with `lh-reset.sh -y --main`;
5. runs `lh-implement.sh` with `LH_UNATTENDED=1` (no sign-off, no signing requirement) under `LH_RUN_TIMEOUT`;
6. on failure, returns the issue to `status:ready`; after `LH_MAX_ATTEMPTS` failures, sets `status:blocked` and comments the last 40 log lines, with paths, user, host, models and endpoint replaced by placeholders.

`lh-implement.sh` takes the harness from `LH_HARNESS` (`aider` or `claude`). The model's process runs without a GitHub token, gh login or git credential helper.

### Set up (maintainer, once)

1. Create a dedicated user without sudo, and let its user manager run without a login:

   ```sh
   sudo useradd --create-home --shell /bin/bash lh-implementer
   sudo loginctl enable-linger lh-implementer
   ```

2. As that user: clone this repository and `LinuxHello/linux-hello`, set a git identity, and log `gh` in with a fine-grained token limited to `LinuxHello/linux-hello`: contents, pull requests and issues read and write, nothing else. You create the token; no agent sees it.
3. Install Aider (`local/install-aider.sh`) and/or Claude Code, cargo, `cargo-deny`, jq and curl for that user.
4. Copy `local/implementer.env.example` to `~/.config/linux-hello/implementer.env` and fill it in.
5. Install and start the timer:

   ```sh
   mkdir -p ~/.config/systemd/user
   cp local/systemd/lh-implementer.{service,timer} ~/.config/systemd/user/
   systemctl --user daemon-reload
   systemctl --user enable --now lh-implementer.timer
   ```

6. Watch it: `journalctl --user -u lh-implementer.service -f`. Logs of each run are under `~/.local/state/linux-hello-implementer/logs/`.

### Trial briefs (before relying on the loop)

Run each of the three trial briefs through both harnesses on the same model and context, by hand, attended:

```sh
LH_HARNESS=aider  bash local/lh-implement.sh <issue>
LH_HARNESS=claude bash local/lh-implement.sh <issue>
```

Keep the harness that passes `make gates` and the test-name check more often, set it as `LH_HARNESS`, and report the result in ADR-0007 before it is accepted.
