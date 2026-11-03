#!/usr/bin/env bash
# Add the maintainer's DCO sign-off to commits on a PR branch that lack one, after he has reviewed them.
#
#   dco-signoff.sh <pr-number>
#
# Lists every commit without Signed-off-by (author and subject), asks for an explicit "yes",
# then rebases the branch onto its base with --signoff (re-signing with the local key) and
# force-pushes with lease. Works in a temporary worktree; the main clone is untouched.
set -euo pipefail
source "$(dirname "$0")/../common.sh"

pr=${1:-}; [[ "$pr" =~ ^[0-9]+$ ]] || die "usage: $0 <pr-number>"
command -v gh >/dev/null || die "gh not installed"
gh auth status >/dev/null 2>&1 || die "gh not authenticated"
[[ "$(git -C "$CLONE_DIR" config --get commit.gpgsign || true)" == "true" ]] || die "commit signing is not enabled in $CLONE_DIR"

read -r head base cross < <(gh pr view "$pr" --repo "$ORG/$REPO" --json headRefName,baseRefName,isCrossRepository \
  --jq '"\(.headRefName) \(.baseRefName) \(.isCrossRepository)"')
[[ "$cross" == "false" ]] || die "PR #$pr comes from a fork; ask its author to sign off instead"

git -C "$CLONE_DIR" fetch -q origin "$base" "$head"
missing=()
while IFS= read -r c; do
  git -C "$CLONE_DIR" log -1 --format=%B "$c" | grep -q '^Signed-off-by: ' || missing+=("$c")
done < <(git -C "$CLONE_DIR" rev-list "origin/$base..origin/$head")
if [[ ${#missing[@]} -eq 0 ]]; then log "every commit on PR #$pr is signed off"; exit 0; fi

log "commits on PR #$pr without a sign-off:"
for c in "${missing[@]}"; do git -C "$CLONE_DIR" log -1 --format='  %h  %an  %s' "$c"; done
echo "Signing off certifies the DCO for these commits under your name (https://developercertificate.org/)."
read -r -p "Have you reviewed them and do you certify them? Type yes: " answer
[[ "$answer" == "yes" ]] || die "not certified; nothing changed"

WT=$(mktemp -d "${TMPDIR:-/tmp}/lh-dco.XXXXXX")
trap 'git -C "$CLONE_DIR" worktree remove --force "$WT" >/dev/null 2>&1 || true' EXIT
git -C "$CLONE_DIR" worktree add -q --detach "$WT" "origin/$head"
git -C "$WT" rebase -q --signoff "origin/$base"
git -C "$WT" push -q --force-with-lease="$head:origin/$head" origin "HEAD:refs/heads/$head"
log "PR #$pr: commits signed off and pushed; CI reruns the dco check"
