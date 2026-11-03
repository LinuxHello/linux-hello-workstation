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

## Local Claude Code (attended)

Start Claude Code on the workstation only through `local/claude-local.sh`. It points every model slot (main, Opus, Sonnet, Haiku, subagents) at Ollama on loopback, sets `CLAUDE_CODE_MAX_CONTEXT_TOKENS` to the served window, and refuses to start if the model is missing or its `num_ctx` differs. A bare `claude`, or the Claude desktop app, uses the Anthropic account and is billed.

```sh
ln -sf ~/projects/LinuxHello/linux-hello-workstation/local/claude-local.sh ~/.local/bin/claude-local
claude-local --remote-control
```

Defaults: `OLLAMA_MODEL=gemma4-26b-64k`, `LH_NUM_CTX=65536`, `LH_BG_MODEL` = the main model. A separate background model (for example `LH_BG_MODEL=ornith:9b`) does not fit in VRAM beside gemma and makes Ollama evict or offload one of them.

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

Run each trial brief once per harness, from the same `main` commit, each on its own branch so the two runs do not mix. Clean the clone between the runs (`bash local/lh-reset.sh -y --main`):

```sh
LH_HARNESS=aider  LH_BRANCH=issue-<n>-aider  bash local/lh-implement.sh <n>
LH_HARNESS=claude LH_BRANCH=issue-<n>-claude bash local/lh-implement.sh <n>
```

Each run opens its own draft pull request. Record the results in the trials tracking issue of the public repository. A run succeeds only if the gates pass **and** the lead's conformance review finds the brief implemented; the gates alone did not catch Policy 1/4 implementing a different schema. Set the winning harness as `LH_HARNESS` in `implementer.env`.
