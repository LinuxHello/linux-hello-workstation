#!/usr/bin/env bash
# A local model drafts a brief or an ADR into a file; nothing is posted to GitHub (ADR-0004: the lead
# reviews a draft before an implementer sees it). Workstation-only.
#
#   lh-draft.sh brief <issue>            draft the "## Implementation brief" of an issue
#   lh-draft.sh adr <title> <decision>   draft an ADR (status Proposed); <decision> is text or a file
#
# The draft goes to ${LH_DRAFT_DIR:-~/.cache/linux-hello-drafts}/ and its path is printed. The model
# can only read the linux-hello clone (Read, Grep, Glob) and gets no GitHub or git credential: this
# script fetches the issue itself and puts an outline of the files it names in the prompt (lh-context.sh),
# so the model rarely needs a tool call. Exploring ate the window and compaction cannot work in it. The model for the role "draft" is loaded first and unloaded after
# (local/lh-model.sh); a model that an interactive session uses is not evicted unless LH_EVICT=1.
#
# Environment: CLONE_DIR (linux-hello clone), ARCH_REPO_DIR (architecture clone, for the ADR template),
# REPO_SLUG, LH_EXAMPLE_BRIEF (issue whose brief is the worked example, default 106),
# LH_THINK (0 default: the model does not think, through local/lh-nothink-relay.py; a thinking model used
# the whole reply cap and left no answer, measured 2026-11-13), LH_DRAFT_MAX_TURNS (default 8, the ADR run; the brief draft has no tools and 3 turns), LH_DRAFT_CONTEXT_BYTES (default 24000), LH_DRAFT_MAX_OUTPUT (default 6000, Claude Code's cap on one reply), LH_MODELS_ENV and the settings of local/lh-model.sh.
set -euo pipefail
: "${CLONE_DIR:=$HOME/projects/LinuxHello/linux-hello}"
: "${ARCH_REPO_DIR:=$HOME/projects/LinuxHello/linux-hello-architecture}"
: "${REPO_SLUG:=LinuxHello/linux-hello}"
: "${LH_EXAMPLE_BRIEF:=106}"
: "${LH_DRAFT_MAX_TURNS:=8}"
: "${LH_THINK:=0}"
: "${LH_DRAFT_ROUNDS:=2}"
: "${LH_DRAFT_REFINE_CALLS:=10}"
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
# shellcheck source=local/lh-context.sh
source "$HERE/lh-context.sh"
# shellcheck source=local/lh-memory.sh
source "$HERE/lh-memory.sh"

kind=${1:-}
case "$kind" in
  brief) [[ "${2:-}" =~ ^[0-9]+$ ]] || die "usage: $0 brief <issue>" ;;
  adr) [[ -n "${2:-}" && -n "${3:-}" ]] || die "usage: $0 adr <title> <decision text or file>" ;;
  *) die "usage: $0 brief <issue> | adr <title> <decision>" ;;
esac
for c in claude gh jq curl; do command -v "$c" >/dev/null || die "$c not installed"; done
[[ -d "$CLONE_DIR/.git" ]] || die "$CLONE_DIR is not a git clone"
branch=$(git -C "$CLONE_DIR" branch --show-current 2>/dev/null || true)
[[ "$branch" == main ]] || printf 'WARNING: %s is on %s, not main: the outline below shows that branch, which may hold unmerged work the issue does not know about\n' "$CLONE_DIR" "${branch:-a detached HEAD}" >&2

# The instructions and context of the prompt, built before any model is touched.
if [[ "$kind" == brief ]]; then
  num=$2
  issue=$(gh issue view "$num" --repo "$REPO_SLUG" --json title,body --jq '"# " + .title + "\n\n" + .body')
  example=$(gh issue view "$LH_EXAMPLE_BRIEF" --repo "$REPO_SLUG" --json body,comments \
    --jq '[.body] + [.comments[].body] | map(select(test("(?m)^## Implementation brief"))) | last // empty')
  [[ -n "$example" ]] || die "issue #$LH_EXAMPLE_BRIEF has no brief to use as the example (set LH_EXAMPLE_BRIEF)"
  rules=$(sed -n '/^### The brief$/,/^### Review$/p' "$CLONE_DIR/AGENTS.md" | sed '$d')
  context=$(lh_draft_context "$CLONE_DIR" "$issue")
  facts=$(lh_draft_facts "${ARCH_REPO_DIR:-}")
  [[ -z "$facts" ]] || context+=$'\n\n'"FACTS THE HARNESS CHECKED (they outrank anything the outline above implies, which comes from a pinned copy):
$facts"
  memory=$(lh_memory_recall "$CLONE_DIR" "$issue")
  [[ -z "$memory" ]] || context+=$'\n\n'"WHAT THE PROJECT MEMORY RECALLS (evidence with its source, kind and date, not fact; the outline above
is the code as it is now and outranks any note about it. A hit marked NOT IN REPOSITORY cites a name that
does not exist: do not use that name. Hits marked CONFLICT disagree: do not pick one, settle it from the
outline or list it under '## Open questions for the lead'. Never state a fact from a hit without naming
its source):
$memory"
  out="$LH_DRAFT_DIR/brief-$num.md"
  prompt="You are the lead of a software project and write an implementation brief for a weaker coding model.

RULES FOR A BRIEF (from AGENTS.md):
$rules

A FINISHED BRIEF, as the model of your work (copy its structure, not its content):
$example

THE ISSUE TO WRITE THE BRIEF FOR:
$issue

WHAT THE REPOSITORY HOLDS (collected for you from the files and identifiers the issue names; line
numbers refer to the current main):
$context

You have no tools and your context window is small: write the brief from the outline above. Never invent
an API. Where the outline does not show what you need (a type, a function, how something is
recorded), write the instruction in terms of what the issue says, and put the exact thing, as one line,
under a final heading '## To look up': a later pass will look each one up. Quote the invariants that
apply.
Answer with the brief only, in Markdown, starting with the line '## Implementation brief'.

No tool exists in this session: do not call Read, Grep, Glob or any other tool. Everything you need is above. Write the brief now."
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
not invent facts: write 'not checked' where you did not read it.

Write for a reader who is new to the subject: someone who uses Linux and has programmed, but has never
worked with passkeys, a TPM, PAM or D-Bus and has read no other page of the project. Begin the Context
with what the parts involved are and what the problem is, in everyday words. Explain every term and
abbreviation in one clause where it first appears. Never leave an identifier (an ADR, issue or spike
number, 'P-12', 'M2') to explain itself: say in words what it states, then give the identifier. For the
decision and each consequence give the reason. Write full sentences. Keep exact names, paths and numbers.

Answer with the ADR only, in Markdown, starting with the frontmatter."
fi

lh_role draft
export OLLAMA_MODEL LH_NUM_CTX
lh_model_acquire "$OLLAMA_MODEL" || exit 1
RELAY_PID=""
trap 'lh_model_release; [[ -z "$RELAY_PID" ]] || kill "$RELAY_PID" 2>/dev/null || true' EXIT

mkdir -p "$LH_DRAFT_DIR"
if [[ "$LH_THINK" == 0 ]]; then
  relay_port_file=$(mktemp)
  python3 -I "$HERE/lh-nothink-relay.py" "$OLLAMA_HOST" >"$relay_port_file" 2>/dev/null &
  RELAY_PID=$!
  for _ in $(seq 50); do [[ -s "$relay_port_file" ]] && break; sleep 0.1; done
  relay_port=$(head -1 "$relay_port_file"); rm -f "$relay_port_file"
  [[ "$relay_port" =~ ^[0-9]+$ ]] || die "thinking-off relay did not start"
  export LH_CLAUDE_BASE_URL="http://127.0.0.1:$relay_port"
fi
log "drafting with $OLLAMA_MODEL (window $LH_NUM_CTX); the model can only read $CLONE_DIR"
# One model run: prints the raw answer, returns 1 when the run failed. $2 turns, $3 "read" (Read, Grep,
# Glob) or "none" (no tools: the model can only answer). claude_local_run execs, so it runs in a
# subshell. No GitHub credential reaches it.
model_run() {
  local raw
  raw=$(env -u GH_TOKEN -u GITHUB_TOKEN CLAUDE_CODE_MAX_OUTPUT_TOKENS="$LH_DRAFT_MAX_OUTPUT" NAME=draft CLONE_DIR="$CLONE_DIR" bash -c '
    source "$1"
    # --tools removes every other built-in tool (Bash among them); --allowedTools alone left them to the permission mode.
    if [[ "$4" == none ]]; then tools=(--tools ""); else tools=(--tools "Read,Grep,Glob" --allowedTools "Read Grep Glob"); fi
    claude_local_run -p "$2" "${tools[@]}" --max-turns "$3"' _ \
    "$HERE/claude-local-lib.sh" "$1" "${2:-$LH_DRAFT_MAX_TURNS}" "${3:-read}" </dev/null) \
    || { printf '%s\n' "$raw" >&2; return 1; }
  printf '%s\n' "$raw"
}
# A brief's first pass has no tools: the outline in the prompt is what it has, and exploring with a
# small window ran out of turns without an answer (2026-11-13). The refine rounds look things up.
if [[ "$kind" == brief ]]; then
  # A local model sometimes calls Read or Glob although none is offered, spends its turns on "No such tool"
  # and ends with "Reached max turns" (#135, 2026-11-14; the same prompt had worked an hour before).
  # Ask once more, saying so, before giving up.
  if ! raw=$(model_run "$prompt" 3 none); then
    log "the first pass failed (a model that calls a tool that does not exist runs out of turns); asking once more"
    raw=$(model_run "$prompt"$'\n\n'"Your previous attempt called a tool. No tool exists. Answer with the brief text only, starting with the line '## Implementation brief'." 3 none) \
      || die "the model run failed twice (its output is above)"
  fi
else
  raw=$(model_run "$prompt") || die "the model run failed (its output is above)"
fi


# Keep only the document: from its first line to the end.
if [[ "$kind" == brief ]]; then
  draft=$(sed -n '/^## Implementation brief/,$p' <<<"$raw")
else
  draft=$(sed -n '/^---$/,$p' <<<"$raw")
fi
[[ -n "$draft" ]] || { printf '%s\n' "$raw" > "$out.rejected"; die "the model did not answer with the document; raw answer in $out.rejected"; }
printf '%s\n' "$draft" > "$out"
log "draft written to $out (not posted anywhere)"

# Refine rounds (brief only): the harness finds hedges and names that exist nowhere, and sends the brief
# back to the model with that list until it is clean or the rounds are used up. A revision that loses
# the heading or the test names is dropped and the previous version kept.
if [[ "$kind" == brief && "$LH_DRAFT_ROUNDS" -gt 0 ]]; then
  # shellcheck source=local/lh-brief.sh
  source "$HERE/lh-brief.sh"
  for round in $(seq "$LH_DRAFT_ROUNDS"); do
    points=$(lh_brief_open_points "$CLONE_DIR" "$issue" "$draft")
    [[ -n "$points" ]] || { log "refine: nothing left to resolve after $((round - 1)) round(s)"; break; }
    log "refine round $round: $(grep -c . <<<"$points") open point line(s)"
    rprompt="You are the lead of a software project. Below is your draft of an implementation brief for a weaker coding model, and a list of its defects. Fix them.

RULES FOR A BRIEF (from AGENTS.md):
$rules

THE ISSUE:
$issue

WHAT THE REPOSITORY HOLDS:
$context

YOUR DRAFT:
$draft

DEFECTS FOUND BY THE HARNESS:
$points

For each defect: look the thing up (Grep, then Read at most 80 lines; at most $LH_DRAFT_REFINE_CALLS tool calls in all) and write the real answer into the brief, or decide it yourself and state the decision as an instruction. The implementer must not be left to find out, to check, or to decide: no 'unverified', no 'if none exists', no 'stop and say'. Resolve every line under '## To look up' and then delete that heading. A name the brief introduces is marked 'new'. Where you truly cannot find an answer, delete the instruction that depends on it and list it, as one line, under a final heading '## Open questions for the lead'. Keep everything else as it is. Answer with the whole revised brief only, in Markdown, starting with the line '## Implementation brief'."
    if ! rraw=$(model_run "$rprompt" "$((LH_DRAFT_REFINE_CALLS + 4))" read); then
      printf 'WARNING: refine round %s failed; keeping the previous version\n' "$round" >&2; break
    fi
    revised=$(sed -n '/^## Implementation brief/,$p' <<<"$rraw")
    printf '%s\n' "$draft" > "$out.round$((round - 1))"
    # A revision is dropped when it has no heading or names fewer tests than the version it replaces
    # (a draft without the bullet format has none, and a revision may still be the better brief).
    if [[ -z "$revised" ]] || [[ "$(lh_brief_test_names "$revised" | grep -c .)" -lt "$(lh_brief_test_names "$draft" | grep -c .)" ]]; then
      printf 'WARNING: round %s gave no usable brief; keeping the previous version (raw answer in %s.rejected)\n' "$round" "$out" >&2
      printf '%s\n' "$rraw" > "$out.rejected"; break
    fi
    draft=$revised
    printf '%s\n' "$draft" > "$out"
  done
  left=$(lh_brief_open_points "$CLONE_DIR" "$issue" "$draft")
  [[ -z "$left" ]] || printf 'WARNING: still open after refining, for the lead to settle:\n%s\n' "$left" >&2
fi

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
