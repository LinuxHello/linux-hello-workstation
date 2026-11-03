#!/usr/bin/env bash
# The Linux Hello agent loop (ADR-0004). Workstation-only. UNTESTED.
#
#   lh-agent.sh brief <issue>       Lead (Claude, cloud) writes the implementation brief
#   lh-agent.sh implement <issue>   Implementer (local model through Aider, lh-implement.sh) codes it and opens a draft PR
#   lh-agent.sh review <pr>         Lead reviews, fixes small faults, marks the PR ready
#   lh-agent.sh next                Lead lists what to do next across the backlog
#
# brief, review and next are headless Claude Code runs in the clone, so CLAUDE.md -> AGENTS.md applies.
set -euo pipefail
: "${CLONE_DIR:=$HOME/projects/LinuxHello/linux-hello}"
: "${REPO_SLUG:=LinuxHello/linux-hello}"
HERE="$(cd "$(dirname "$0")" && pwd)"
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '\033[1m==> %s\033[0m\n' "$*"; }

for c in gh git jq; do command -v "$c" >/dev/null || die "$c not installed"; done
gh auth status >/dev/null 2>&1 || die "gh not authenticated"
[[ -d "$HOME/.cargo/bin" ]] && PATH="$HOME/.cargo/bin:$PATH"
cd "$CLONE_DIR"
[[ -z "$(git status --porcelain)" ]] || die "working tree not clean in $CLONE_DIR (clean it, keeping a copy: bash $HERE/lh-reset.sh)"

cmd=${1:-}; num=${2:-}
need_num() { [[ "$num" =~ ^[0-9]+$ ]] || die "usage: $0 $cmd <number>"; }

# Tools each role may use without asking. Nothing outside the clone, no secrets, no merge.
LEAD_TOOLS=(Read Grep Glob Edit Write 'Bash(gh issue:*)' 'Bash(gh pr view:*)' 'Bash(gh pr diff:*)' 'Bash(gh pr checks:*)' 'Bash(gh pr comment:*)' 'Bash(gh pr edit:*)' 'Bash(gh pr ready:*)' 'Bash(gh label list:*)' 'Bash(gh api repos/LinuxHello/linux-hello/code-scanning:*)' 'Bash(git status:*)' 'Bash(git diff:*)' 'Bash(git log:*)' 'Bash(git add:*)' 'Bash(git commit:*)' 'Bash(git push:*)' 'Bash(cargo:*)')

lead() { command -v claude >/dev/null || die "claude not installed"; claude -p "$1" --permission-mode acceptEdits --allowedTools "${LEAD_TOOLS[@]}"; }

case "$cmd" in
  brief)
    need_num
    lead "You are the lead (AGENTS.md, Roles and workflow). Read issue #$num in $REPO_SLUG with gh, including comments, and the docs it depends on. If it is a spike, say so and stop. Otherwise post an implementation brief as an issue comment exactly in the AGENTS.md brief format, sized for a small context window; split the issue into new issues if it is too big. Then set its label to status:ready and remove other status: labels."
    ;;
  implement)
    need_num
    exec bash "$HERE/lh-implement.sh" "$num"   # local model through Aider (ADR-0004)
    ;;
  review)
    need_num
    gh pr checkout "$num" --repo "$REPO_SLUG" >/dev/null
    lead "You are the lead (AGENTS.md, Review). Review pull request #$num in $REPO_SLUG against the brief of the issue it closes. Run every gate locally. Read Copilot's review comments and the CodeQL, dependency-review and Sonar results (gh pr checks $num). Fix small faults yourself with signed-off commits (trailer 'Assisted-by: Claude Code (<model>)') and push to the PR branch. For larger faults, post a review comment that the implementer can act on, keep the PR in draft and set the issue back to status:in-progress. If it passes, fill any gaps in the PR description, mark it ready for review with 'gh pr ready $num' and post a short summary for the maintainer: what changed in behaviour, which tests prove it, what you fixed, anything the maintainer must decide."
    git switch -q - || true
    ;;
  next)
    lead "You are the lead. Look at the open issues, milestones and pull requests in $REPO_SLUG with gh. Make sure every open issue has exactly one status: label (add status:needs-brief where missing). Then list, in order, the next three actions for the maintainer and the agents, respecting spike dependencies (no implementation that depends on an open spike). Do not change any code."
    ;;
  *) die "usage: $0 {brief|implement|review|next} [number]" ;;
esac
