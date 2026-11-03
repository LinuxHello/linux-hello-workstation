#!/usr/bin/env bash
# GitHub security scanning for the repo. Idempotent. UNTESTED against the GitHub API.
#  1. Org Actions allow-list (adds the SonarQube scan action) via org.sh.
#  2. CodeQL default setup (all detected languages, extended query suite).
#  3. Status labels for the agent workflow (protect.sh labels block).
#  4. Ruleset: block merges on CodeQL errors and high/critical security alerts,
#     but only once CodeQL has produced an analysis, so the rule cannot deadlock merges.
set -euo pipefail
source "$(dirname "$0")/../common.sh"

command -v gh >/dev/null || die "gh not installed"
command -v jq >/dev/null || die "jq not installed"
gh auth status >/dev/null 2>&1 || die "gh not authenticated"

bash "$BOOTSTRAP_DIR/scripts/org.sh"

log "CodeQL default setup"
state=$(gh api "repos/$ORG/$REPO/code-scanning/default-setup" --jq .state 2>/dev/null || echo unknown)
if [[ "$state" == "configured" ]]; then
  log "CodeQL default setup already configured"
else
  gh api -X PATCH "repos/$ORG/$REPO/code-scanning/default-setup" --silent \
    -f state=configured -f query_suite=extended
  log "CodeQL default setup requested; the first analysis runs on main"
fi

log "labels"
bash "$BOOTSTRAP_DIR/scripts/protect.sh"

log "ruleset: code scanning merge protection"
id=$(gh api "repos/$ORG/$REPO/rulesets" --jq '.[] | select(.name == "main") | .id')
[[ -n "$id" ]] || die "ruleset 'main' not found; run protect.sh first"
rules=$(gh api "repos/$ORG/$REPO/rulesets/$id")
if jq -e '.rules[] | select(.type == "code_scanning")' <<<"$rules" >/dev/null; then
  log "code scanning rule already present"
elif [[ "$(gh api "repos/$ORG/$REPO/code-scanning/analyses?tool_name=CodeQL&per_page=1" --jq length 2>/dev/null || echo 0)" == "0" ]]; then
  log "no CodeQL analysis yet; re-run this script after the first one completes"
else
  jq '{name, target, enforcement, conditions, bypass_actors,
       rules: (.rules + [{type: "code_scanning", parameters: {code_scanning_tools: [
         {tool: "CodeQL", alerts_threshold: "errors", security_alerts_threshold: "high_or_higher"}]}}])}' \
    <<<"$rules" | gh api -X PUT "repos/$ORG/$REPO/rulesets/$id" --silent --input -
  log "code scanning rule added"
fi
