#!/usr/bin/env bash
# Create the monorepo and set its baseline. Idempotent.
set -euo pipefail
source "$(dirname "$0")/../common.sh"

if gh repo view "$ORG/$REPO" >/dev/null 2>&1; then
  log "repo $ORG/$REPO exists, updating settings"
else
  log "creating $ORG/$REPO (public)"
  gh repo create "$ORG/$REPO" --public --disable-wiki \
    --description "PIN-rooted, biometric-unlocked passkeys and secrets for the Linux desktop"
fi

gh repo edit "$ORG/$REPO" \
  --enable-issues --enable-wiki=false \
  --enable-squash-merge --enable-merge-commit=false --enable-rebase-merge=false \
  --delete-branch-on-merge --enable-auto-merge \
  --add-topic passkeys,webauthn,fido2,tpm2,pam,biometrics,kde,rust

log "security features"
gh api -X PATCH "repos/$ORG/$REPO" --silent --input - <<'JSON'
{ "security_and_analysis": {
    "secret_scanning": { "status": "enabled" },
    "secret_scanning_push_protection": { "status": "enabled" } } }
JSON
gh api -X PUT "repos/$ORG/$REPO/vulnerability-alerts" --silent
gh api -X PUT "repos/$ORG/$REPO/automated-security-fixes" --silent
gh api -X PUT "repos/$ORG/$REPO/private-vulnerability-reporting" --silent
