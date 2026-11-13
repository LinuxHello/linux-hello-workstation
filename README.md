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

Start Claude Code on the workstation only through `make claude-gpu` (`local/claude-local-gpu.sh`, the GPU Ollama on :11434) or `make claude-cpu` (`local/claude-local-cpu.sh`, the CPU-only Ollama on :11435). Both share `local/claude-local-lib.sh`. They point every model slot (main, Opus, Sonnet, Haiku, subagents) at Ollama on loopback, set `CLAUDE_CODE_MAX_CONTEXT_TOKENS` to the served window, and refuse to start if the model is missing or its `num_ctx` differs. A bare `claude`, or the Claude desktop app, uses the Anthropic account and is billed.

Defaults: GPU `OLLAMA_MODEL=gemma4-26b-64k`, `LH_NUM_CTX=65536`; CPU `OLLAMA_MODEL=gemma4-26b-128k`, `LH_NUM_CTX=131072` (about 40 tokens/s prompt processing and 4 tokens/s generation, so slow). `LH_BG_MODEL` is the main model. A separate background model (for example `LH_BG_MODEL=ornith:9b`) does not fit in VRAM beside gemma and makes Ollama evict or offload one of them. The sessions start lean (no MCP servers, user plugins or skills, which would add many tokens to every prompt); `LH_LEAN=0` loads everything. To pass flags, run the script directly: `local/claude-local-gpu.sh --remote-control`.

## Shared memory ([ADR-0019](https://github.com/LinuxHello/architecture/blob/main/adr/0019-shared-agent-memory.md))

A LanceDB index of the repositories, their issues and briefs, and your private notes, plus a log of what agents concluded. It returns evidence with its kind, source, date and status, never a verdict, and marks what an agent must not trust: hits that disagree (`CONFLICT`), agent-written rows nobody verified (`UNVERIFIED`), names a note cites that the repository does not contain (`NOT IN REPOSITORY`), and notes that changed since they were read.

| Path | What |
| :-- | :-- |
| `local/lhmem/` | The library: `core.py` (tiers, ranking, conflicts, the checks), `indexer.py`, `stores.py` (LanceDB, plus a JSON-lines store for tests), `embed.py` |
| `local/lh-memory.py` | The harness-side CLI: `index`, `query`, `remember`, `promote`, `expire`, `stats` |
| `local/lh-memory.sh` | `lh_memory_recall`, which `lh-draft.sh` uses |
| `local/memory.env.example` | Settings: where the database is, the embedding model, what to index |

- **Two tiers, two directories.** Rows live in `<dir>/public` or `<dir>/private`. A public-tier caller never opens the private one, and `lh-draft.sh` is always public-tier: it writes public artefacts, so `LH_MEMORY_TIER` in the environment or in `memory.env` cannot change that. Make `<dir>/private` readable by you only, so an agent run as another user cannot open it whatever its tier says. Notes are always private; a repository is public only when `memory.env` says `public:`.
- **Indexing** is incremental and read-only: a repository is read as committed at `HEAD`, a note is skipped when its hash is unchanged, rows of vanished sources are removed, agent rows are never touched. Media and the vault's `.obsidian`, `.trash` and `Claude outputs` folders are skipped.
- **Setup:** `make memory-venv` (downloads `lancedb`), copy `local/memory.env.example` to `~/.config/linux-hello/memory.env`, check that the CPU Ollama on :11435 has the embedding model, then `make memory-index`.
- Not yet: a loopback service (the CLI is the interface for now), automatic writes of agent conclusions, and calling the memory from the implementer.

## Changing this repository

By pull request, like the monorepo: the lead opens it, the maintainer certifies and merges. `make test` must pass.

Which model runs which role is set in `~/.config/linux-hello/models.env` (`local/models.env.example`; defaults: the implementer on `gemma4-26b-64k`, drafting on `qwen38-27b-text-32k`). `make implement`, `make draft-brief` and `make draft-adr` make their model the only one loaded and unload it when they end (`local/lh-model.sh`), so the GPU is free for the next job. They refuse to unload a model that an interactive `make claude-gpu` session uses, unless `LH_EVICT=1`.
