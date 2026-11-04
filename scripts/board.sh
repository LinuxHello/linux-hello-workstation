#!/usr/bin/env bash
# The public "Linux Hello roadmap" project board: create it once, then mirror the issues onto it.
# Labels and blocked-by links on the issues stay the source of truth; this copies them into the
# board's fields (Lane, Priority, Order, Waiting for) and archives closed issues. Idempotent.
# Edit labels, not board fields: the next run overwrites board fields.
#
#   board.sh    needs: gh with the project scope (gh auth refresh -s project), jq, and a clone of
#               the monorepo at CLONE_DIR whose scripts/backlog/backlog.sh supplies the order.
#
# UNTESTED against the GitHub API.
set -euo pipefail
source "$(dirname "$0")/../common.sh"
TITLE="${BOARD_TITLE:-Linux Hello roadmap}"
BACKLOG="${LH_BACKLOG:-$CLONE_DIR/scripts/backlog/backlog.sh}"
for c in gh jq; do command -v "$c" >/dev/null || die "$c not installed"; done
gh auth status 2>&1 | grep -q "'project'" || die "gh lacks the project scope: run  gh auth refresh -s project"
[[ -f "$BACKLOG" ]] || die "$BACKLOG missing; pull main in $CLONE_DIR"

# 1. The project, public and linked to the monorepo.
num=$(gh project list --owner "$ORG" --format json --limit 100 \
        --jq ".projects[] | select(.title == \"$TITLE\") | .number")
if [[ -z "$num" ]]; then
  log "create project '$TITLE'"
  num=$(gh project create --owner "$ORG" --title "$TITLE" --format json --jq .number)
fi
pid=$(gh project view "$num" --owner "$ORG" --format json --jq .id)
gh project edit "$num" --owner "$ORG" --visibility PUBLIC \
  --description "What is next in Linux Hello. Mirrors issue labels; edit labels, not this board." >/dev/null
gh project link "$num" --owner "$ORG" --repo "$ORG/$REPO" >/dev/null 2>&1 || true
log "project #$num: https://github.com/orgs/$ORG/projects/$num"

# 2. Fields. Single-select options are listed in the order the board sorts them.
fields() { gh project field-list "$num" --owner "$ORG" --format json --limit 100; }
ensure_field() { # name type [options]
  fields | jq -e --arg n "$1" '.fields[] | select(.name == $n)' >/dev/null && return
  log "field $1"
  if [[ $2 == SINGLE_SELECT ]]; then
    gh project field-create "$num" --owner "$ORG" --name "$1" --data-type SINGLE_SELECT --single-select-options "$3" >/dev/null
  else
    gh project field-create "$num" --owner "$ORG" --name "$1" --data-type "$2" >/dev/null
  fi
}
ensure_field Lane SINGLE_SELECT "Implement,Brief,Spike,Review,Doing,Stuck,Untriaged"
ensure_field Priority SINGLE_SELECT "Now,Next,Later"
ensure_field Order NUMBER
ensure_field "Waiting for" TEXT
F=$(fields)
fid() { jq -r --arg n "$1" '.fields[] | select(.name == $n) | .id' <<<"$F"; }
oid() { jq -r --arg n "$1" --arg o "$2" '.fields[] | select(.name == $n) | .options[] | select(.name == $o) | .id' <<<"$F"; }
cap() { local s="$1"; printf '%s' "${s^}"; }

# 3. Every open issue on the board with its fields.
issues=$(REPO_SLUG="$ORG/$REPO" bash "$BACKLOG" json)
count=0
while IFS=$'\t' read -r n lane prio order waiting; do
  item=$(gh project item-add "$num" --owner "$ORG" --url "https://github.com/$ORG/$REPO/issues/$n" --format json --jq .id)
  gh project item-edit --id "$item" --project-id "$pid" --field-id "$(fid Lane)" \
    --single-select-option-id "$(oid Lane "$(cap "$lane")")" >/dev/null
  if [[ "$prio" != - ]]; then
    gh project item-edit --id "$item" --project-id "$pid" --field-id "$(fid Priority)" \
      --single-select-option-id "$(oid Priority "$(cap "$prio")")" >/dev/null
  else
    gh project item-edit --id "$item" --project-id "$pid" --field-id "$(fid Priority)" --clear >/dev/null
  fi
  gh project item-edit --id "$item" --project-id "$pid" --field-id "$(fid Order)" --number "$order" >/dev/null
  if [[ -n "$waiting" ]]; then
    gh project item-edit --id "$item" --project-id "$pid" --field-id "$(fid "Waiting for")" --text "$waiting" >/dev/null
  else
    gh project item-edit --id "$item" --project-id "$pid" --field-id "$(fid "Waiting for")" --clear >/dev/null
  fi
  count=$((count + 1))
done < <(jq -r '.[] | [.number, .lane, (.priority[0] // "-"), .order, .waiting_for] | @tsv' <<<"$issues")
log "$count open issue(s) mirrored"

# 4. Archive items whose issue is closed.
open_numbers=$(jq -r '.[].number' <<<"$issues")
gh project item-list "$num" --owner "$ORG" --format json --limit 1000 \
  --jq '.items[] | select(.content.type == "Issue") | [.id, .content.number] | @tsv' |
while IFS=$'\t' read -r item n; do
  grep -qx "$n" <<<"$open_numbers" && continue
  gh project item-archive "$num" --owner "$ORG" --id "$item" >/dev/null && log "archived #$n (closed)"
done
log "board in sync. Views are set once by hand: see RUNBOOK.md, 'Board views'."
