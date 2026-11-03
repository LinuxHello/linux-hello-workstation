## Intent
The implementer role (local model) runs through Aider instead of Claude Code. Claude Code's context window cannot be set below 100k tokens; the local model has 32k, and the first run lost its instructions to prompt truncation. Aider sends only the files the brief lists.

## Affected containers
Docs only: `AGENTS.md`, `docs/adr/0004-agent-roles.md` (amended).

## Tests
Docs only. The implementer script itself is workstation tooling outside this repository; it was dry-run against a copy of this repository with a stand-in model: a run missing six of the brief's seven tests was refused after two repair rounds, and a complete run passed every gate and produced a signed, signed-off commit.

## Rollback
Revert the squash commit.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_01HDRiNrHMgwggETKeGt6Fed
