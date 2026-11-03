#!/usr/bin/env bash
# Create the backlog in issues/backlog.json as GitHub issues. Idempotent: an issue whose exact
# title already exists (open or closed) is skipped, so edits on GitHub are never overwritten.
set -euo pipefail
source "$(dirname "$0")/../common.sh"
: "${BACKLOG:=$BOOTSTRAP_DIR/issues/backlog.json}"

command -v gh >/dev/null || die "gh not installed"
command -v jq >/dev/null || die "jq not installed"
gh auth status >/dev/null 2>&1 || die "gh not authenticated: run 'gh auth login'"
[[ -f "$BACKLOG" ]] || die "backlog not found: $BACKLOG"
jq -e 'type == "array" and all(.[]; .title and .body and (.labels | type == "array"))' "$BACKLOG" >/dev/null \
  || die "backlog is not a list of {title, body, labels, milestone}"

log "labels used by the backlog"
gh label create "container:workspace" --repo "$ORG/$REPO" --color 1d76db \
  --description "Cross-cutting: workspace, CI, governance, docs" --force >/dev/null
existing_labels=$(gh label list --repo "$ORG/$REPO" --limit 200 --json name --jq '.[].name')
missing=$(jq -r '.[].labels[]' "$BACKLOG" | sort -u | grep -vxF -f <(printf '%s\n' "$existing_labels") || true)
[[ -z "$missing" ]] || die "labels missing on $ORG/$REPO (run 'make protect' first): $missing"

log "milestones used by the backlog"
existing_ms=$(gh api "repos/$ORG/$REPO/milestones?state=all&per_page=100" --jq '.[].title')
while IFS= read -r ms; do
  [[ -z "$ms" ]] && continue
  if ! grep -qxF "$ms" <<<"$existing_ms"; then
    gh api -X POST "repos/$ORG/$REPO/milestones" --silent -f title="$ms"
    log "created milestone '$ms'"
  fi
done < <(jq -r '.[].milestone // empty' "$BACKLOG" | sort -u)

existing_titles=$(gh issue list --repo "$ORG/$REPO" --state all --limit 1000 --json title --jq '.[].title')
created=0 skipped=0
count=$(jq length "$BACKLOG")
for ((i = 0; i < count; i++)); do
  title=$(jq -r ".[$i].title" "$BACKLOG")
  if grep -qxF "$title" <<<"$existing_titles"; then
    skipped=$((skipped + 1)); continue
  fi
  args=(--repo "$ORG/$REPO" --title "$title" --body "$(jq -r ".[$i].body" "$BACKLOG")")
  while IFS= read -r l; do args+=(--label "$l"); done < <(jq -r ".[$i].labels[]" "$BACKLOG")
  ms=$(jq -r ".[$i].milestone // empty" "$BACKLOG")
  [[ -n "$ms" ]] && args+=(--milestone "$ms")
  url=$(gh issue create "${args[@]}")
  log "created: $url  $title"
  created=$((created + 1))
done
log "issues: $created created, $skipped already present"
