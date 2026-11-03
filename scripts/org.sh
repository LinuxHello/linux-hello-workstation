#!/usr/bin/env bash
# Organisation baseline. Idempotent: PATCH/PUT set absolute values.
set -euo pipefail
source "$(dirname "$0")/../common.sh"

log "org settings: $ORG"
gh api -X PATCH "orgs/$ORG" --silent \
  -f description="Linux Hello: biometric- and PIN-gated passkeys and secrets for the Linux desktop" \
  -f default_repository_permission=read \
  -F members_can_create_repositories=false \
  -F members_can_create_public_repositories=false \
  -F members_can_create_private_repositories=false \
  -F members_can_fork_private_repositories=false \
  -F web_commit_signoff_required=true

log "actions: GitHub-owned plus an explicit allow-list only"
gh api -X PUT "orgs/$ORG/actions/permissions" --silent \
  -f enabled_repositories=all -f allowed_actions=selected
gh api -X PUT "orgs/$ORG/actions/permissions/selected-actions" --silent --input - <<'JSON'
{
  "github_owned_allowed": true,
  "verified_allowed": false,
  "patterns_allowed": [
    "dtolnay/rust-toolchain@*",
    "EmbarkStudios/cargo-deny-action@*",
    "SonarSource/sonarqube-scan-action@*"
  ]
}
JSON
gh api -X PUT "orgs/$ORG/actions/permissions/workflow" --silent \
  -f default_workflow_permissions=read -F can_approve_pull_request_reviews=false
