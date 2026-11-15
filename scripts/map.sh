#!/usr/bin/env bash
# Writes docs/dependency-map.md: a Mermaid map of which open issues wait for which, from
# issues/triage.tsv and the open issues on GitHub. GitHub draws the diagram, also on a phone.
#
#   map.sh    needs gh and jq; prints the path it wrote.
set -euo pipefail
source "$(dirname "$0")/../common.sh"
for c in gh jq python3; do command -v "$c" >/dev/null || die "$c not installed"; done
issues=$(gh issue list --repo "$ORG/$REPO" --state open --limit 300 --json number,title,labels)
out="$BOOTSTRAP_DIR/docs/dependency-map.md"
jq -n --argjson issues "$issues" --rawfile triage "$BOOTSTRAP_DIR/issues/triage.tsv" \
  '{issues: $issues, triage: $triage}' | python3 "$BOOTSTRAP_DIR/scripts/map.py" > "$out"
log "wrote $out"
