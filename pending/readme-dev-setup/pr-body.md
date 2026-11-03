## Intent
A new contributor can install the toolchain and run every CI gate locally from the README.

## Affected containers
Docs only: `README.md`.

## Tests
None (docs). The apt and rustup commands were run by the maintainer on Kubuntu; `cargo install --locked cargo-deny cargo-audit` is untested here.

## Rollback
Revert the squash commit.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_01HDRiNrHMgwggETKeGt6Fed
