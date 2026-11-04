#!/usr/bin/env bash
# Ruleset on main, labels (labels.sh), Milestone 0. Run after seed (the ruleset blocks direct pushes).
set -euo pipefail
source "$(dirname "$0")/../common.sh"

if gh api "repos/$ORG/$REPO/rulesets" --jq '.[].name' | grep -qx main; then
  log "ruleset 'main' exists, skipping"
else
  log "ruleset on main"
  gh api -X POST "repos/$ORG/$REPO/rulesets" --silent --input "$BOOTSTRAP_DIR/ruleset-main.json"
fi

bash "$(dirname "$0")/labels.sh"

log "remove GitHub default labels that overlap type:*"
for name in bug documentation enhancement; do
  if gh label list --repo "$ORG/$REPO" --limit 200 --json name --jq '.[].name' | grep -qx "$name"; then
    gh label delete "$name" --repo "$ORG/$REPO" --yes >/dev/null
    log "deleted label '$name'"
  fi
done

title="M0 – Spikes"
if gh api "repos/$ORG/$REPO/milestones?state=all" --jq '.[].title' | grep -qx "$title"; then
  log "milestone '$title' exists"
else
  gh api -X POST "repos/$ORG/$REPO/milestones" --silent \
    -f title="$title" \
    -f description="Verify the unverified assumptions before any implementation: credentialsd provider API and portal on KDE, browser portal support, Howdy interface, greeter and lock-screen extension points, TPM root key auth change."
fi
