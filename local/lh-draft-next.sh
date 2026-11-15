#!/usr/bin/env bash
# make draft-next-brief: draft the brief of the next issue, have Claude check it, and publish it only if
# the check finds nothing wrong. Workstation-only.
#
#   lh-draft-next.sh            the next issue of the brief lane
#   LH_ISSUE=<n> lh-draft-next.sh   that issue
#   LH_DRY=1 lh-draft-next.sh   do everything except post and relabel
#
# 1. Pick: the first issue of the brief lane that has no open blocker, in the order of `make next`.
#    An ADR (a decision for the maintainer) and an issue that already has a brief are skipped, aloud.
# 2. Draft it with lh-draft.sh (the local model, with its mechanical checks and refine rounds).
# 3. Evaluate it with lh-evaluate-brief.sh (Claude, against the issue and the code on origin/main).
# 4. Nothing wrong: post it with `gh issue comment <n> --repo <repo> --body-file <brief>` and set the issue
#    to status:ready. Something wrong: post nothing and print a short report in plain words: the decisions
#    that are the maintainer's, what the lead fixes, and what was checked. The report is also saved
#    beside the brief as report-<n>.md.
#
# Nothing is posted when: the issue already has a brief (the implementer takes the LAST brief on an
# issue, so a second one would replace the first); the draft has no brief heading; it names no files or
# more than five; every test it names already exists on main; the evaluator did not answer with a
# verdict; the verdict has a blocking problem. An implementer run in progress stops the flow before
# anything is drafted, because the drafting reads the clone.
#
# Exit status: 0 published (or a dry run that would publish), 2 not published, 1 an error.
# Tested by local/test-lh-draft-next.sh.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
: "${CLONE_DIR:=$HOME/projects/LinuxHello/linux-hello}"
: "${REPO_SLUG:=LinuxHello/linux-hello}"
: "${LH_BACKLOG:=$CLONE_DIR/scripts/backlog/backlog.sh}"
: "${LH_DRAFT_DIR:=${XDG_CACHE_HOME:-$HOME/.cache}/linux-hello-drafts}"
: "${LH_EVALUATE:=$HERE/lh-evaluate-brief.sh}"
: "${LH_DRY:=0}"
: "${LH_ISSUE:=}"
export CLONE_DIR REPO_SLUG LH_DRAFT_DIR
log() { printf '\033[1m==> %s\033[0m\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
for c in gh jq python3 git; do command -v "$c" >/dev/null || die "$c not installed"; done

# shellcheck source=local/lh-brief.sh
source "$HERE/lh-brief.sh"
# shellcheck source=local/lh-context.sh
source "$HERE/lh-context.sh"
# shellcheck source=local/lh-status.sh
source "$HERE/lh-status.sh"

if pgrep -f 'lh-implement.sh|aider --model' >/dev/null 2>&1; then
  die "an implementer run is using the clone ($CLONE_DIR); wait until it ends, then run this again"
fi

has_brief() { # <n>: does the issue have a comment that starts with the brief heading?
  local c
  c=$(gh issue view "$1" --repo "$REPO_SLUG" --json comments \
        --jq '[.comments[] | select(.body | test("(?m)^## Implementation brief"))] | length')
  [[ "${c:-0}" -gt 0 ]]
}

is_architecture() { # <n>: is its work an ADR or a spike in the architecture repository, not code in this one?
  local text labels body
  text=$(gh issue view "$1" --repo "$REPO_SLUG" --json body,labels \
           --jq '(.labels | map(.name) | join(",")) + "\n" + .body') || return 1
  labels=${text%%$'\n'*}; body=${text#*$'\n'}
  [[ ",$labels," == *,type:spike,* ]] && return 0
  # The issue text asks for an ADR before code: "Proposed change (ADR before ...)" or an acceptance of "An accepted ADR".
  grep -Eiq 'proposed change \(ADR|^\*\*Acceptance\.\*\* +(An )?accepted ADR' <<<"$body"
}

pick() { # the first issue of the brief lane that can be drafted
  local data n t
  data=$(REPO_SLUG="$REPO_SLUG" bash "$LH_BACKLOG" json) || die "the backlog could not be read"
  while IFS=$'\t' read -r n t; do
    if [[ "$t" =~ ^ADR([^A-Za-z]|$) ]]; then
      printf '  #%s skipped: "%s" is a decision for you (an ADR), not a brief\n' "$n" "$t" >&2
    elif is_architecture "$n"; then
      printf '  #%s skipped: "%s" is an ADR or a spike for the lead and you (the architecture repository), not a brief\n' "$n" "$t" >&2
    elif has_brief "$n"; then
      printf '  #%s skipped: it already has a brief; set it to ready if it is the one to implement\n' "$n" >&2
    else
      echo "$n"; return 0
    fi
  done < <(jq -r '.[] | select(.lane == "brief" and (.blocked_by // 0) == 0) | [.number, .title] | @tsv' <<<"$data")
  return 1
}

if [[ -n "$LH_ISSUE" ]]; then
  [[ "$LH_ISSUE" =~ ^[0-9]+$ ]] || die "ISSUE must be an issue number"
  n=$LH_ISSUE
  if has_brief "$n"; then
    echo "Issue #$n already has a brief. Posting another would replace it, because the implementer uses the last brief on an issue. Nothing was done."
    exit 2
  fi
else
  log "picking the next issue of the brief lane"
  n=$(pick) || { echo "No issue in the brief lane can be drafted now."; exit 2; }
fi
issue_text=$(gh issue view "$n" --repo "$REPO_SLUG" --json title,body --jq '"# " + .title + "\n\n" + .body')
title=$(head -1 <<<"$issue_text"); title=${title#\# }
log "issue #$n: $title"

mkdir -p "$LH_DRAFT_DIR"
brief_file="$LH_DRAFT_DIR/brief-$n.md"
rm -f "$brief_file" "$LH_DRAFT_DIR/report-$n.md"

log "drafting the brief with the local model"
if [[ -n "${LH_DRAFT_CMD:-}" ]]; then draft_cmd=("$LH_DRAFT_CMD"); else draft_cmd=(bash "$HERE/lh-draft.sh"); fi
"${draft_cmd[@]}" brief "$n" || die "the draft failed (its output is above)"

reasons=()
brief=""
[[ -s "$brief_file" ]] && brief=$(<"$brief_file")
details=""
if ! grep -q '^## Implementation brief' <<<"$brief"; then
  reasons+=("The draft has no brief in it (it does not start with the brief heading).")
else
  nfiles=$(cd "$CLONE_DIR" && lh_brief_files "$brief" | grep -c . || true)
  if [[ "$nfiles" -lt 1 || "$nfiles" -gt 5 ]]; then
    reasons+=("The brief names $nfiles files to change; it must name between one and five.")
  fi
  if (cd "$CLONE_DIR" && lh_brief_already_implemented "$brief"); then
    reasons+=("Every test the brief names already exists on main: the work looks done already.")
  fi
  details=$(lh_brief_open_points "$CLONE_DIR" "$issue_text" "$brief" 2>/dev/null || true)
fi

verdict=""
eval_note=""
if [[ ${#reasons[@]} -eq 0 ]]; then
  log "having Claude check the brief against the issue and the code"
  findings_file=$(mktemp); printf '%s\n' "$details" > "$findings_file"
  if verdict=$(bash "$LH_EVALUATE" "$n" "$brief_file" "$findings_file" 2>"$findings_file.err"); then :; else
    verdict=""; eval_note=$(tail -1 "$findings_file.err" 2>/dev/null || true)
    reasons+=("The brief could not be evaluated${eval_note:+ ($eval_note)}, so nothing was checked and nothing was posted.")
  fi
  rm -f "$findings_file" "$findings_file.err"
fi

outcome=not_published
if [[ ${#reasons[@]} -eq 0 && -n "$verdict" ]]; then
  if jq -e '.verdict == "ok" and ([.problems[]? | select(.blocking == true)] | length) == 0' <<<"$verdict" >/dev/null; then
    outcome=clean
  fi
fi

if [[ "$outcome" == clean ]]; then
  if [[ "$LH_DRY" == 1 ]]; then
    outcome=dry_run
  else
    log "publishing the brief on #$n"
    gh issue comment "$n" --repo "$REPO_SLUG" --body-file "$brief_file" >/dev/null || die "posting the brief failed"
    lh_set_status "$REPO_SLUG" "$n" ready
    outcome=published
  fi
fi

reasons_json=$(printf '%s\n' "${reasons[@]:-}" | jq -R . | jq -s 'map(select(length > 0))')
jq -n --argjson n "$n" --arg title "$title" --arg outcome "$outcome" --argjson reasons "$reasons_json" \
      --argjson verdict "${verdict:-null}" --arg details "$details" \
      '{issue: $n, title: $title, outcome: $outcome, reasons: $reasons, verdict: $verdict, details: $details}' \
  | python3 "$HERE/lh-brief-report.py" | tee "$LH_DRAFT_DIR/report-$n.md"
[[ "$outcome" == published || "$outcome" == dry_run ]]  || exit 2
