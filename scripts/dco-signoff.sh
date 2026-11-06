#!/usr/bin/env bash
# Add the maintainer's DCO sign-off to commits on a PR branch that lack one, after he has reviewed them.
#
#   dco-signoff.sh <pr-number> [<repo> | <owner>/<repo>]
#
# The repository defaults to $ORG/$REPO (LinuxHello/linux-hello). Name another one to certify a PR
# there, for example `dco-signoff.sh 6 architecture`; `make signoff PR=6 REPO=architecture` does the same.
# The clone is $CLONE_DIR, which defaults to ~/projects/<owner>/<repo>. The script refuses a clone
# whose origin is not that repository, so it can never rewrite the wrong one.
#
# Lists every commit without Signed-off-by (author and subject), asks for an explicit "yes",
# then rebases the branch onto its base with --signoff (re-signing with the local key) and
# force-pushes with lease. Works in a temporary worktree; the main clone is untouched.
set -euo pipefail

pr=${1:-}; repo_arg=${2:-}
[[ "$pr" =~ ^[0-9]+$ ]] || { echo "ERROR: usage: $0 <pr-number> [<repo> | <owner>/<repo>]" >&2; exit 1; }
if [[ -n "$repo_arg" ]]; then
  if [[ "$repo_arg" == */* ]]; then ORG=${repo_arg%%/*}; REPO=${repo_arg#*/}; else REPO=$repo_arg; fi
fi
source "$(dirname "$0")/../common.sh"
slug="$ORG/$REPO"
command -v gh >/dev/null || die "gh not installed"
gh auth status >/dev/null 2>&1 || die "gh not authenticated"

# The clone must be a clone of this repository: its origin names $slug.
origin=$(git -C "$CLONE_DIR" config --get remote.origin.url 2>/dev/null) || die "$CLONE_DIR is not a clone with an origin remote; set CLONE_DIR=<a clone of $slug>"
path=${origin%.git}; path=${path//:/\/}
have=${path%/*}; have=${have##*/}/${path##*/}
[[ "${have,,}" == "${slug,,}" ]] || die "$CLONE_DIR is a clone of $have, not of $slug; set CLONE_DIR=<a clone of $slug>"
[[ "$(git -C "$CLONE_DIR" config --get commit.gpgsign || true)" == "true" ]] || die "commit signing is not enabled in $CLONE_DIR"

read -r head base cross < <(gh pr view "$pr" --repo "$slug" --json headRefName,baseRefName,isCrossRepository \
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
