#!/usr/bin/env bash
# One-off: branch, commit (signed, signed-off) and open the hygiene PR in LinuxHello/linux-hello.
# Idempotent up to the push: re-running on the branch only re-stages and amends nothing that is already committed.
set -euo pipefail
: "${CLONE_DIR:=$HOME/projects/LinuxHello/linux-hello}"
: "${BRANCH:=chore/repo-hygiene-security-md}"
PENDING="$(cd "$(dirname "$0")" && pwd)"
log() { printf '\033[1m==> %s\033[0m\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

command -v gh >/dev/null || die "gh not installed"
gh auth status >/dev/null 2>&1 || die "gh not authenticated"
cd "$CLONE_DIR"
[[ "$(git config --get commit.gpgsign || true)" == "true" ]] || die "commit signing is not enabled in $CLONE_DIR"

current=$(git branch --show-current)
if [[ "$current" == "main" ]]; then
  git fetch -q origin main
  [[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || die "local main differs from origin/main; sync first"
  git switch -c "$BRANCH"
elif [[ "$current" != "$BRANCH" ]]; then
  die "on branch '$current'; expected main or $BRANCH"
fi

if [[ -f "$PENDING/ci.yml" ]]; then
  log "installing CI workflow"
  cp "$PENDING/ci.yml" .github/workflows/ci.yml
fi

# Only the files this PR is meant to touch.
files=(
  SECURITY.md GOVERNANCE.md .github/workflows/ci.yml
  docs/index.md docs/adr/README.md
  docs/adr/0001-monorepo-with-split-guardrails.md docs/adr/0002-licence-lgpl-3-or-later.md
  docs/adr/0003-destructive-reset.md
  docs/architecture/target-architecture.md docs/architecture/workspace.dsl
  docs/spikes/README.md docs/security/README.md
  docs/project/claude-project-instructions.md
)
extra=$(git status --porcelain | awk '{print $2}' | grep -vxF -f <(printf '%s\n' "${files[@]}") || true)
[[ -z "$extra" ]] || die "unexpected changes, not committing: $extra"

git add -- "${files[@]}"
if git diff --cached --quiet; then
  log "nothing new to commit"
else
  git commit -q -s -F - <<'MSG'
Rewrite SECURITY.md, fix doc drift, pin CI

- SECURITY.md: disclosure process and targets, supported versions,
  security model, scope, safe harbour.
- ADR-0003: destructive reset (formerly LH-1), moved out of the
  target architecture note unchanged.
- Target architecture and workspace.dsl: C5 now states
  LGPL-3.0-or-later (ADR-0002); D-Bus name io.github.LinuxHello.Agent1.
- Frontmatter on every vault note.
- CI: runners pinned to ubuntu-24.04, actions pinned to commit SHAs,
  cargo-audit pinned to 0.22.2.
- GOVERNANCE.md: path-filtered CI deferred, with the reason; reset
  model listed as a one-way door.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01HDRiNrHMgwggETKeGt6Fed
MSG
fi
git log -1 --show-signature --format='%h %s' | tail -3

git push -u origin "$BRANCH"
if gh pr view "$BRANCH" >/dev/null 2>&1; then
  log "PR exists: $(gh pr view "$BRANCH" --json url --jq .url)"
else
  gh pr create --base main --head "$BRANCH" \
    --title "Rewrite SECURITY.md, fix doc drift, pin CI" \
    --label type:docs --label type:security \
    --body-file - <<'BODY'
## Intent
Make the security policy usable before anyone reports anything, and remove drift between accepted decisions and the docs.

## Affected
No crates. `SECURITY.md`, `GOVERNANCE.md`, `.github/workflows/ci.yml`, `docs/` (architecture note, DSL, ADRs, indexes, project instructions).

## Changes
- **SECURITY.md**: private reporting via GitHub, targets (ack 7 d, assessment 14 d, fix 90 d), supported versions, six-point security model, scope and out of scope, safe harbour.
- **ADR-0003** destructive reset (was LH-1 inside the target architecture), content unchanged.
- **Drift**: C5 says LGPL-3.0-or-later; `org.linuxhello.Agent1` → `io.github.LinuxHello.Agent1` in the note and `workspace.dsl`; frontmatter on every vault note.
- **CI**: `ubuntu-24.04`; actions pinned to commit SHAs (checkout v7.0.1, rust-toolchain v1 + `toolchain: stable`, cargo-deny-action v2.1.1); `cargo-audit` 0.22.2.
- **GOVERNANCE.md**: path-filtered CI deferred until crates hold code (a path-skipped required check blocks merges); reset model added to one-way doors.

## Tests
No code change. The six required checks must pass with the pinned actions; that is the test of the CI change.
Locally: workflow parses as YAML; relative links resolve. Not run: actionlint, Structurizr CLI on `workspace.dsl`.

## Verify
1. All six checks green on this PR.
2. `SECURITY.md` renders on the repo's Security tab.
3. `docs/adr/0003-destructive-reset.md` renders and links back to the target architecture.

## Rollback
Revert the squash commit.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_01HDRiNrHMgwggETKeGt6Fed
BODY
fi
