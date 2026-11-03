#!/usr/bin/env bash
# Read-only: print the effective state for review.
set -euo pipefail
source "$(dirname "$0")/../common.sh"

log "org $ORG"
gh api "orgs/$ORG" --jq '{two_factor_requirement_enabled, default_repository_permission, members_can_create_repositories, web_commit_signoff_required}'
gh api "orgs/$ORG/actions/permissions" --jq '{enabled_repositories, allowed_actions}'
gh api "orgs/$ORG/actions/permissions/workflow" --jq .
log "repo $ORG/$REPO"
gh api "repos/$ORG/$REPO" --jq '{visibility, default_branch, allow_squash_merge, allow_merge_commit, allow_rebase_merge, allow_auto_merge, delete_branch_on_merge, security_and_analysis}'
gh api "repos/$ORG/$REPO/private-vulnerability-reporting" --jq .
log "rulesets"
gh api "repos/$ORG/$REPO/rulesets" --jq '.[] | {name, enforcement}'
log "labels: $(gh label list --repo "$ORG/$REPO" --limit 100 --json name --jq 'length')"
gh api "repos/$ORG/$REPO/milestones" --jq '.[].title'
