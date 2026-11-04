#!/usr/bin/env bash
# Apply issues/triage.tsv to the monorepo's issues: exactly one status: and one priority: label,
# and GitHub "blocked by" links. Shows the plan unless APPLY=1. Idempotent; never removes a
# blocked-by link, never closes an issue, never touches labels other than status:* and priority:*.
#
#   triage.sh [file]          show what would change
#   APPLY=1 triage.sh [file]  change it
set -euo pipefail
source "$(dirname "$0")/../common.sh"
FILE="${1:-$BOOTSTRAP_DIR/issues/triage.tsv}"
APPLY="${APPLY:-0}"
R="$ORG/$REPO"
[[ -f "$FILE" ]] || die "$FILE not found"
for c in gh jq; do command -v "$c" >/dev/null || die "$c not installed"; done

act() { # description command...
  if [[ "$APPLY" == 1 ]]; then "${@:2}" >/dev/null; printf '  done: %s\n' "$1"; else printf '  plan: %s\n' "$1"; fi
}

changes=0
while IFS=$'\t' read -r n status priority blockers _note; do
  [[ -z "$n" || "$n" == \#* ]] && continue
  [[ "$n" =~ ^[0-9]+$ ]] || die "bad issue number '$n' in $FILE"
  [[ "$status" =~ ^(needs-brief|ready|in-progress|in-review|blocked)$ ]] || die "#$n: bad status '$status'"
  [[ "$priority" =~ ^(now|next|later)$ ]] || die "#$n: bad priority '$priority'"

  issue=$(gh api "repos/$R/issues/$n")
  [[ "$(jq -r .state <<<"$issue")" == open ]] || { echo "#$n is closed; skipped"; continue; }
  have=$(jq -r '.labels[].name' <<<"$issue")
  want=("status:$status" "priority:$priority")
  echo "#$n $(jq -r .title <<<"$issue" | cut -c1-70)"

  add=(); remove=()
  for l in "${want[@]}"; do grep -qxF "$l" <<<"$have" || add+=("$l"); done
  while read -r l; do
    [[ -z "$l" ]] && continue
    printf '%s\n' "${want[@]}" | grep -qxF "$l" || remove+=("$l")
  done < <(grep -E '^(status|priority):' <<<"$have" || true)
  args=()
  for l in "${add[@]}"; do args+=(--add-label "$l"); done
  for l in "${remove[@]}"; do args+=(--remove-label "$l"); done
  if ((${#args[@]})); then
    changes=$((changes + 1))
    act "labels +[${add[*]}] -[${remove[*]}]" gh issue edit "$n" --repo "$R" "${args[@]}"
  fi

  [[ "$blockers" == - || -z "$blockers" ]] && continue
  existing=$(gh api "repos/$R/issues/$n/dependencies/blocked_by" --jq '.[].number')
  for b in ${blockers//,/ }; do
    [[ "$b" =~ ^[0-9]+$ ]] || die "#$n: bad blocker '$b'"
    grep -qx "$b" <<<"$existing" && continue
    changes=$((changes + 1))
    id=$(gh api "repos/$R/issues/$b" --jq .id)
    act "blocked by #$b" gh api -X POST "repos/$R/issues/$n/dependencies/blocked_by" -F "issue_id=$id"
  done
done <"$FILE"

if [[ "$APPLY" == 1 ]]; then log "$changes change(s) applied"
elif ((changes)); then log "$changes change(s) planned; run with APPLY=1 to make them"
else log "nothing to change"; fi
