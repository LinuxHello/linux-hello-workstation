## Intent
Answer spike #6: do Firefox and Chromium on Linux call the credentials portal? **Partly**: no stock browser does; only the credentialsd add-on (two demo sites) and an experimental patched Firefox reach credentialsd. Closes #6.

## Affected containers
Docs only: `docs/spikes/`, `docs/architecture/target-architecture.md`.

## Tests
Source read at pinned commits (Firefox `e924f94`, Chromium `1d3439e`, credentialsd `v0.3.1`); nothing run. Lead review spot-checked the key claims.

## Security
Evidence 5: the credentialsd extension passes the origin from the page side; origin must not be trusted from an unprivileged client.

## Rollback
Revert the squash commit.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_01HDRiNrHMgwggETKeGt6Fed
