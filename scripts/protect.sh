#!/usr/bin/env bash
# Ruleset on main, labels, Milestone 0. Run after seed (the ruleset blocks direct pushes).
set -euo pipefail
source "$(dirname "$0")/../common.sh"

if gh api "repos/$ORG/$REPO/rulesets" --jq '.[].name' | grep -qx main; then
  log "ruleset 'main' exists, skipping"
else
  log "ruleset on main"
  gh api -X POST "repos/$ORG/$REPO/rulesets" --silent --input "$BOOTSTRAP_DIR/ruleset-main.json"
fi

log "labels"
while IFS='|' read -r name color desc; do
  gh label create "$name" --repo "$ORG/$REPO" --color "$color" --description "$desc" --force >/dev/null
done <<'LABELS'
container:dbus|1d76db|linuxhello-dbus interface crate
container:agent|1d76db|Linux Hello Agent
container:pam|1d76db|pam_linuxhello
container:tpm-provider|1d76db|TPM credential provider
container:kpxc-bridge|1d76db|KeePassXC provider bridge
container:plasma|1d76db|Plasma integration
container:ctl|1d76db|linuxhello-ctl
container:security|1d76db|AppArmor, Tetragon, alert rules
container:policy|1d76db|Policy schema and stores
container:workspace|1d76db|Cross-cutting: workspace, CI, governance, docs
type:spike|fbca04|Time-boxed investigation of an unverified assumption
type:feature|0e8a16|New capability
type:bug|d73a4a|Behaviour differs from the documented intent
type:security|b60205|Security property, hardening or vulnerability fix
type:docs|c5def5|Documentation and architecture
one-way-door|5319e7|Hard to reverse; needs an ADR
upstream|bfdadc|Work lands in an upstream project
status:needs-brief|ededed|Waiting for the lead's implementation brief
status:ready|c2e0c6|Brief posted; ready for the implementer
status:in-progress|fef2c0|Being implemented
status:in-review|d4c5f9|Pull request open; lead review
LABELS

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
