## Intent
Make the routing policy implementable and testable before any code: exact schema, defaults, merge and fail-closed rules, and the security properties with their test names. Pin the toolchain so the local model, cloud agents and CI build with the same Rust. Closes #20.

## Affected containers
Docs, workspace: `docs/architecture/policy-semantics.md` (new), `docs/security/README.md`, `docs/index.md`, `README.md`, `Cargo.toml` (`rust-version` 1.85), `rust-toolchain.toml` (new).

## Decision needed
The note proposes two things for the maintainer to confirm:
1. **Defaults and ranges** (PIN min 6, lockout after 5 attempts for 15 minutes, biometrics allowed, IR required for face, hardware TPM required).
2. **The user layer only tightens**: a user can make a default stricter, never looser; only an admin can loosen. The target architecture's wording allowed any user value an admin had not locked.

Merging this PR confirms both; the four "Policy n/4" issues then start.

## Tests
No code. Gates on this branch with the pinned toolchain (rustc 1.99.1): fmt, clippy `-D warnings`, test, `cargo deny check`, `unsafe-policy`: pass. A throwaway prototype confirmed `toml` 1.1.8 with `deny_unknown_fields` rejects unknown keys on Rust 1.85 and 1.99.1, and that serde and toml pass `cargo deny`.

## Rollback
Revert the squash commit.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_01HDRiNrHMgwggETKeGt6Fed
