#!/usr/bin/env bash
# Connect the repo to SonarQube Cloud after the one-time web sign-up. Idempotent. UNTESTED.
# The token is typed into gh's hidden prompt; it is never echoed, stored in a file or passed as an argument.
set -euo pipefail
source "$(dirname "$0")/../common.sh"

command -v gh >/dev/null || die "gh not installed"
gh auth status >/dev/null 2>&1 || die "gh not authenticated"

if gh secret list --repo "$ORG/$REPO" --json name --jq '.[].name' | grep -qx SONAR_TOKEN; then
  log "SONAR_TOKEN already set (rotate with: gh secret set SONAR_TOKEN --repo $ORG/$REPO)"
else
  log "paste the SonarQube Cloud token at the hidden prompt"
  gh secret set SONAR_TOKEN --repo "$ORG/$REPO"
fi

gh variable set SONAR_ENABLED --repo "$ORG/$REPO" --body true
log "Sonar enabled; the next pull request or push to main runs the 'sonar' job"
