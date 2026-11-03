#!/usr/bin/env bash
# One-off: branch, commit (signed, signed-off) and open the agent-roles and scanning PR.
# Stacks on the agent-rules PR while it is open; branches from main once it is merged.
set -euo pipefail
: "${CLONE_DIR:=$HOME/projects/LinuxHello/linux-hello}"
: "${BRANCH:=docs/agent-roles-and-scanning}"
: "${BASE_PR_BRANCH:=docs/agents-md}"
PENDING="$(cd "$(dirname "$0")" && pwd)/roles"
log() { printf '\033[1m==> %s\033[0m\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

command -v gh >/dev/null || die "gh not installed"
gh auth status >/dev/null 2>&1 || die "gh not authenticated"
cd "$CLONE_DIR"
[[ "$(git config --get commit.gpgsign || true)" == "true" ]] || die "commit signing is not enabled in $CLONE_DIR"

files=(AGENTS.md GOVERNANCE.md CONTRIBUTING.md .gitignore sonar-project.properties
       docs/adr/README.md docs/adr/0004-agent-roles.md docs/project/claude-project-instructions.md
       .github/copilot-instructions.md .github/copilot-commit-message.md .github/pull_request_template.md
       .github/workflows/sonar.yml .github/workflows/dependency-review.yml .vscode/settings.json)

state=$(gh pr view "$BASE_PR_BRANCH" --json state --jq .state 2>/dev/null || echo NONE)
case "$state" in
  OPEN) base="$BASE_PR_BRANCH" ;;
  MERGED|NONE) base=main ;;
  *) die "PR for $BASE_PR_BRANCH is $state; resolve it first" ;;
esac
log "base branch: $base"

current=$(git branch --show-current)
if [[ "$current" != "$BRANCH" ]]; then
  git fetch -q origin "$base"
  git switch "$base" 2>/dev/null || git switch -c "$base" --track "origin/$base"
  git merge -q --ff-only "origin/$base"
  git switch -c "$BRANCH"
fi

# Remote file tools cannot write any path containing .github/ or .vscode/; those files wait
# under pending/roles/ with flattened names: github__workflows__sonar.yml -> .github/workflows/sonar.yml
if [[ -d "$PENDING" ]]; then
  for src in "$PENDING"/*; do
    [[ -f "$src" ]] || continue
    name=$(basename "$src")
    dest=".${name//__//}"
    mkdir -p "$(dirname "$dest")"; cp "$src" "$dest"
  done
fi

extra=$(git status --porcelain --untracked-files=all | awk '{print $2}' | grep -vxF -f <(printf '%s\n' "${files[@]}") || true)
[[ -z "$extra" ]] || die "unexpected changes, not committing: $extra"

git add -- "${files[@]}"
if git diff --cached --quiet; then
  log "nothing new to commit"
else
  git commit -q -s -F - <<'MSG'
Fix agent roles; add CodeQL, dependency review and Sonar

- ADR-0004: the local model implements, Claude leads (briefs,
  backlog, review, fixes, docs, spikes), Copilot writes PR
  summaries and commit messages and reviews.
- AGENTS.md: roles, status labels, brief format, review checklist;
  scanner findings count like failing tests.
- Copilot: PR summary and review guidance, commit message rules
  (wired up in .vscode/settings.json), PR template.
- CI: dependency review on every PR; SonarQube Cloud with Clippy
  and coverage reports, off until SONAR_ENABLED is set.
- GOVERNANCE.md: code scanning merge protection.

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
    --title "Fix agent roles; add CodeQL, dependency review and Sonar" \
    --label type:docs --label type:security --label container:workspace \
    --body-file - <<'BODY'
## Intent
Make the local model the primary implementer, Claude the lead (briefs, backlog, review, fixes, docs) and Copilot the assistant for PR summaries and commit messages (ADR-0004). Add security and quality scanning.

## Affected containers
Workspace only: `AGENTS.md`, `GOVERNANCE.md`, `CONTRIBUTING.md`, `docs/adr/`, `docs/project/`, `.github/`, `.vscode/settings.json`, `sonar-project.properties`, `.gitignore`. No crate changes.

## Tests
No code change. New workflows must report on this PR:
- `dependency-review` must pass.
- `sonar` must be **skipped** (off until `SONAR_ENABLED=true`).

## Security
- CodeQL default setup and its merge-protection rule are repository settings, applied by the bootstrap script, not by this PR.
- Sonar needs a `SONAR_TOKEN` repository secret; it is set through `gh secret set` at a hidden prompt, never in a file.
- All new actions are pinned to commit SHAs (checkout v7.0.1, rust-toolchain v1, dependency-review-action v5.0.0, sonarqube-scan-action v8.4.0).

## How to verify
1. `dependency-review` green; `sonar` skipped.
2. In VS Code, Copilot's commit message button follows `.github/copilot-commit-message.md`.
3. A new PR opens with the template.

## Rollback
Revert the squash commit; turn off CodeQL default setup in repository settings if needed.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_01HDRiNrHMgwggETKeGt6Fed
BODY
fi
