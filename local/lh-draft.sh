#!/usr/bin/env bash
# A local model drafts a brief or an ADR into a file; nothing is posted to GitHub (ADR-0004: the lead
# reviews a draft before an implementer sees it). Workstation-only.
#
#   lh-draft.sh brief <issue>            draft the "## Implementation brief" of an issue
#   lh-draft.sh adr <title> <decision>   draft an ADR (status Proposed); <decision> is text or a file
#
# The draft goes to ${LH_DRAFT_DIR:-~/.cache/linux-hello-drafts}/ and its path is printed. The model
# can only read the linux-hello clone (Read, Grep, Glob) and gets no GitHub or git credential: this
# script fetches the issue itself. The model for the role "draft" is loaded first and unloaded after
# (local/lh-model.sh); a model that an interactive session uses is not evicted unless LH_EVICT=1.
#
# Environment: CLONE_DIR (linux-hello clone), ARCH_REPO_DIR (architecture clone, for the ADR template),
# REPO_SLUG, LH_EXAMPLE_BRIEF (issue whose brief is the worked example, default 106),
# LH_DRAFT_MAX_TURNS (default 30), LH_DRAFT_MAX_OUTPUT (default 6000, Claude Code's cap on one reply), LH_MODELS_ENV and the settings of local/lh-model.sh.
set -euo pipefail
: "${CLONE_DIR:=$HOME/projects/LinuxHello/linux-hello}"
: "${ARCH_REPO_DIR:=$HOME/projects/LinuxHello/architecture}"
: "${REPO_SLUG:=LinuxHello/linux-hello}"
: "${LH_EXAMPLE_BRIEF:=106}"
: "${LH_DRAFT_MAX_TURNS:=30}"
# Claude Code compacts at window - min(max reply, 20000) - 13000, so at its default reply size a 32k
# window has no room for a prompt at all ("Prompt is too long", measured 2026-11-08).
: "${LH_DRAFT_MAX_OUTPUT:=6000}"
: "${LH_DRAFT_DIR:=${XDG_CACHE_HOME:-$HOME/.cache}/linux-hello-drafts}"
HERE="$(cd "$(dirname "$0")" && pwd)"
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '\033[1m==> %s\033[0m\n' "$*"; }
# shellcheck source=local/lh-model.sh
source "$HERE/lh-model.sh"
# shellcheck source=local/claude-local-lib.sh
source "$HERE/claude-local-lib.sh"

kind=${1:-}
case "$kind" in
  brief) [[ "${2:-}" =~ ^[0-9]+$ ]] || die "usage: $0 brief <issue>" ;;
  adr) [[ -n "${2:-}" && -n "${3:-}" ]] || die "usage: $0 adr <title> <decision text or file>" ;;
  *) die "usage: $0 brief <issue> | adr <title> <decision>" ;;
esac
for c in claude gh jq curl; do command -v "$c" >/dev/null || die "$c not installed"; done
[[ -d "$CLONE_DIR/.git" ]] || die "$CLONE_DIR is not a git clone"

# The instructions and context of the prompt, built before any model is touched.
if [[ "$kind" == brief ]]; then
  num=$2
  issue=$(gh issue view "$num" --repo "$REPO_SLUG" --json title,body --jq '"# " + .title + "\n\n" + .body')
  example=$(gh issue view "$LH_EXAMPLE_BRIEF" --repo "$REPO_SLUG" --json body,comments \
    --jq '[.body] + [.comments[].body] | map(select(test("(?m)^## Implementation brief"))) | last // empty')
  [[ -n "$example" ]] || die "issue #$LH_EXAMPLE_BRIEF has no brief to use as the example (set LH_EXAMPLE_BRIEF)"
  rules=$(sed -n '/^### The brief$/,/^### Review$/p' "$CLONE_DIR/AGENTS.md" | sed '$d')
  out="$LH_DRAFT_DIR/brief-$num.md"
  prompt="You are the lead of a software project and write an implementation brief for a weaker coding model.

RULES FOR A BRIEF (from AGENTS.md):
$rules

A FINISHED BRIEF, as the model of your work (copy its structure, not its content):
$example

THE ISSUE TO WRITE THE BRIEF FOR:
$issue

Read the files in the repository that the issue names, to get real function names, types and test
helpers right. Never invent an API: if you did not read it, say so in the brief. Quote the invariants
that apply. Answer with the brief only, in Markdown, starting with the line '## Implementation brief'."
else
  title=$2
  decision=$3; [[ ! -f "$decision" ]] || decision=$(<"$decision")
  template=$(<"$ARCH_REPO_DIR/templates/adr.md") || die "no ADR template at $ARCH_REPO_DIR/templates/adr.md"
  slug=$(tr '[:upper:] ' '[:lower:]-' <<<"$title" | tr -cd 'a-z0-9-')
  out="$LH_DRAFT_DIR/adr-$slug.md"
  prompt="Write an architecture decision record for a software project, from this template:

$template

TITLE: $title

THE DECISION, already made by the maintainer (do not change it):
$decision

Set the status to Proposed. State the context from what you read in the repository's docs, the options
with pros and cons, the decision as given, and the consequences (what becomes easier, what harder). Do
not invent facts: write 'not checked' where you did not read it. Answer with the ADR only, in Markdown,
starting with the frontmatter."
fi

lh_role draft
export OLLAMA_MODEL LH_NUM_CTX
lh_model_acquire "$OLLAMA_MODEL" || exit 1
trap 'lh_model_release' EXIT

mkdir -p "$LH_DRAFT_DIR"
log "drafting with $OLLAMA_MODEL (window $LH_NUM_CTX); the model can only read $CLONE_DIR"
# claude_local_run execs, so it runs in a subshell. No GitHub credential reaches it.
raw=$(env -u GH_TOKEN -u GITHUB_TOKEN CLAUDE_CODE_MAX_OUTPUT_TOKENS="$LH_DRAFT_MAX_OUTPUT" NAME=draft CLONE_DIR="$CLONE_DIR" bash -c '
  source "$1"; claude_local_run -p "$2" --allowedTools "Read Grep Glob" --max-turns "$3"' _ \
  "$HERE/claude-local-lib.sh" "$prompt" "$LH_DRAFT_MAX_TURNS" </dev/null) \
  || { printf '%s\n' "$raw" >&2; die "the model run failed (its output is above)"; }

# Keep only the document: from its first line to the end.
if [[ "$kind" == brief ]]; then
  draft=$(sed -n '/^## Implementation brief/,$p' <<<"$raw")
else
  draft=$(sed -n '/^---$/,$p' <<<"$raw")
fi
[[ -n "$draft" ]] || { printf '%s\n' "$raw" > "$out.rejected"; die "the model did not answer with the document; raw answer in $out.rejected"; }
printf '%s\n' "$draft" > "$out"
log "draft written to $out (not posted anywhere)"

# Cheap checks that the lead would otherwise do first; they do not replace the review.
if [[ "$kind" == brief ]]; then
  # shellcheck source=local/lh-brief.sh
  source "$HERE/lh-brief.sh"
  for h in "Goal" "Files" "tests" "Constraints" "Acceptance" "Out of scope"; do
    grep -qi "^#\+ .*$h" "$out" || printf 'WARNING: no section "%s"\n' "$h" >&2
  done
  names=$(lh_brief_test_names "$draft")
  printf '%s test name(s) found by the harness parser\n' "$(grep -c . <<<"$names" || true)"
  [[ -n "$names" ]] || printf 'WARNING: the implementer gate would find no test names in this brief\n' >&2
fi
