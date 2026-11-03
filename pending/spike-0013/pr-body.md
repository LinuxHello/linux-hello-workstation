## Intent
Answer spike #13 and align the licence policy with it. **Yes**: every upstream component fits C2 (link only LGPL or permissive) and C3 (GPL only across a process boundary). Closes #13.

## Affected containers
Workspace: `deny.toml`, `.github/workflows/dependency-review.yml`, `docs/spikes/`, `docs/architecture/target-architecture.md`.

## Tests
- Licence files read at libwebauthn v0.9.0, KeePassXC 2.8.0, fprintd `main` (`5731b9a`), Howdy v2.6.1 and `master`, dlib-models README: **tested** by reading.
- `cargo deny check licenses bans sources` with the new allow-list: pass (cargo-deny 0.20.2, rustc 1.97.0).

## Security
Licence policy only. No GPL licence is added to either allow-list, so CI still rejects a linked GPL crate.

## Rollback
Revert the squash commit.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_01HDRiNrHMgwggETKeGt6Fed
