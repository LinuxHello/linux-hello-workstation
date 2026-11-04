# linux-hello-workstation

Private tooling for the Linux Hello maintainer's workstation: the backlog and board commands, the local implementer and its unattended loop, and the scripts that set up the `LinuxHello` organisation. It names local models and paths, so it stays private (invariant 8); everything a contributor needs is in the public `LinuxHello/linux-hello`.

## Start here

```sh
make          # every task, grouped: Daily, Implementer, Checks, Once
make next     # what to pick up now
```

[RUNBOOK.md](RUNBOOK.md) says when to run which task and in which order.

## Layout

| Path | What |
| :-- | :-- |
| `Makefile` | The only entry point |
| `scripts/` | GitHub-side tasks: triage, board, labels, sign-off, organisation setup |
| `local/` | Workstation-side tasks: local Claude Code, implementer, loop, reset, systemd units |
| `issues/triage.tsv` | Status, priority and blocked-by for each open issue, applied by `make triage` |
| `common.sh` | Shared defaults (`ORG`, `REPO`, `CLONE_DIR`) |

## Local Claude Code

Start Claude Code on the workstation only through `make claude` (`local/claude-local.sh`). It points every model slot (main, Opus, Sonnet, Haiku, subagents) at Ollama on loopback, sets `CLAUDE_CODE_MAX_CONTEXT_TOKENS` to the served window, and refuses to start if the model is missing or its `num_ctx` differs. A bare `claude`, or the Claude desktop app, uses the Anthropic account and is billed.

Defaults: `OLLAMA_MODEL=gemma4-26b-64k`, `LH_NUM_CTX=65536`, `LH_BG_MODEL` = the main model. A separate background model (for example `LH_BG_MODEL=ornith:9b`) does not fit in VRAM beside gemma and makes Ollama evict or offload one of them. To pass flags, run the script directly: `local/claude-local.sh --remote-control`.

## Changing this repository

By pull request, like the monorepo: the lead opens it, the maintainer certifies and merges. `make test` must pass.
