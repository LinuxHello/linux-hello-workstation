Define the routing policy semantics; pin the Rust toolchain

docs/architecture/policy-semantics.md makes the policy section of the
target architecture implementable: schema with ranges, built-in
defaults, restrictiveness per key, layering (admin wins; the user can
tighten defaults but not loosen them), fail-closed PIN-only state,
and the query API. docs/security lists the policy properties with the
test names the implementation must add.

rust-toolchain.toml pins Rust 1.99.1 with clippy, rustfmt and
llvm-tools for every build; rust-version rises to 1.85, the minimum
for toml 1.x. README prerequisites updated.

Closes #20

Assisted-by: Claude Code (claude-opus-5-5)
Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01HDRiNrHMgwggETKeGt6Fed
