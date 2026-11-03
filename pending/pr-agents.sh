#!/usr/bin/env bash
# One-off: branch, commit (signed, signed-off) and open the agent-rules PR in LinuxHello/linux-hello.
# Stacks on the hygiene PR while it is open; branches from main once it is merged.
set -euo pipefail
: "${CLONE_DIR:=$HOME/projects/LinuxHello/linux-hello}"
: "${BRANCH:=docs/agents-md}"
: "${BASE_PR_BRANCH:=chore/repo-hygiene-security-md}"
log() { printf '\033[1m==> %s\033[0m\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

command -v gh >/dev/null || die "gh not installed"
gh auth status >/dev/null 2>&1 || die "gh not authenticated"
cd "$CLONE_DIR"
[[ "$(git config --get commit.gpgsign || true)" == "true" ]] || die "commit signing is not enabled in $CLONE_DIR"

files=(AGENTS.md CLAUDE.md .github/copilot-instructions.md CONTRIBUTING.md .gitignore
       docs/project/claude-project-instructions.md)

state=$(gh pr view "$BASE_PR_BRANCH" --json state --jq .state 2>/dev/null || echo NONE)
case "$state" in
  OPEN)   base="$BASE_PR_BRANCH" ;;
  MERGED|NONE) base=main ;;
  *) die "hygiene PR is $state; resolve it first" ;;
esac
log "base branch: $base"

current=$(git branch --show-current)
if [[ "$current" != "$BRANCH" ]]; then
  git fetch -q origin "$base"
  git switch "$base" 2>/dev/null || git switch -c "$base" --track "origin/$base"
  git merge -q --ff-only "origin/$base"
  git switch -c "$BRANCH"
fi

# Remote file tools cannot write into .github/; the file waits beside this script.
PENDING="$(cd "$(dirname "$0")" && pwd)"
if [[ -f "$PENDING/copilot-instructions.md" ]]; then
  cp "$PENDING/copilot-instructions.md" .github/copilot-instructions.md
fi

extra=$(git status --porcelain | awk '{print $2}' | grep -vxF -f <(printf '%s\n' "${files[@]}") || true)
[[ -z "$extra" ]] || die "unexpected changes, not committing: $extra"

git add -- "${files[@]}"
if git diff --cached --quiet; then
  log "nothing new to commit"
else
  git commit -q -s -F - <<'MSG'
Add AGENTS.md as the single source of agent rules

- AGENTS.md: invariants, source-of-truth order, workflow, gates,
  commit and PR rules, docs conventions, for every coding agent.
- CLAUDE.md imports AGENTS.md; .github/copilot-instructions.md
  points to it. Both add only tool-specific lines.
- CONTRIBUTING.md: AI-assisted contributions; human sign-off,
  Assisted-by trailer, no gate exemptions.
- Claude Project instructions: rules moved to AGENTS.md; local
  clone path removed.
- .gitignore: personal Claude Code settings.

Assisted-by: Claude Code (claude-opus-5-5)
Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01HDRiNrHMgwggETKeGt6Fed
MSG
fi
git log -1 --show-signature --format='%h %s' | tail -3

git push -u origin "$BRANCH"
if gh pr view "$BRANCH" >/dev/null 2>&1; then
  log "PR exists: $(gh pr view "$BRANCH" --json url --jq .url)"
else
  gh pr create --base "$base" --head "$BRANCH" \
    --title "Add AGENTS.md as the single source of agent rules" \
    --label type:docs \
    --body-file - <<'BODY'
## Intent
Claude Code, GitHub Copilot and Claude Code against a local model all work on this repo. One rules file keeps them consistent; the CI gates stay the backstop.

## Affected
No crates. `AGENTS.md` (new), `CLAUDE.md` (new), `.github/copilot-instructions.md` (new), `CONTRIBUTING.md`, `.gitignore`, `docs/project/claude-project-instructions.md`.

## Changes
- **AGENTS.md**: the rules from the Claude Project instructions, made tool-neutral: invariants, source of truth, workflow, gates with exact commands, sign-off and `Assisted-by:` trailer, docs conventions. Invariant 8 now names hostnames, home paths, hardware, local endpoints and model names as private.
- **CLAUDE.md**: `@AGENTS.md` plus four Claude Code lines.
- **.github/copilot-instructions.md**: points to AGENTS.md; repeats the five rules most relevant to completions.
- **CONTRIBUTING.md**: AI-assisted contributions.
- **Project instructions**: keep only the role and Claude-Project-specific rules; local clone path removed.

## Tests
Docs only; the six required checks must stay green. Not verified: whether Copilot Chat in the IDE reads AGENTS.md directly (documented for the coding agent); the pointer file covers the IDE.

## Verify
1. In Claude Code, `/memory` lists CLAUDE.md with AGENTS.md imported.
2. Copilot coding agent on a test issue cites AGENTS.md rules.

## Rollback
Revert the squash commit.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_01HDRiNrHMgwggETKeGt6Fed
BODY
fi
