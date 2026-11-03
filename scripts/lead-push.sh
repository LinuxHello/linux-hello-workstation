#!/usr/bin/env bash
# Apply the lead's prepared changes to a PR branch and make sure a PR exists. Idempotent.
#
#   lead-push.sh <branch> <pending-dir>
#
# <pending-dir> holds:
#   files named with '__' for '/'   e.g. docs__spikes__README.md -> docs/spikes/README.md
#   commit.msg                      commit message (sign-off added by git commit -s)
#   pr-title, pr-body.md            used only when the PR does not exist yet
#   requires                        optional: paths that must already exist on origin/main
#                                   (files here replace whole files, so merge what they build on first)
#
# If the branch already exists on GitHub (e.g. pushed by a Claude Code cloud session or Copilot),
# commits without a DCO sign-off are listed and need your explicit "yes" before the branch is
# rebased onto main with your sign-off and signature. Works in a temporary worktree.
set -euo pipefail
source "$(dirname "$0")/../common.sh"

branch=${1:-}; dir=${2:-}
[[ -n "$branch" && -d "$dir" ]] || die "usage: $0 <branch> <pending-dir>"
dir=$(cd "$dir" && pwd)
[[ -f "$dir/commit.msg" ]] || die "$dir/commit.msg missing"
command -v gh >/dev/null || die "gh not installed"
gh auth status >/dev/null 2>&1 || die "gh not authenticated"
[[ "$(git -C "$CLONE_DIR" config --get commit.gpgsign || true)" == "true" ]] || die "commit signing is not enabled in $CLONE_DIR"

git -C "$CLONE_DIR" fetch -q --prune origin
if [[ -f "$dir/requires" ]]; then
  while IFS= read -r path; do
    [[ -z "$path" || "$path" == \#* ]] && continue
    git -C "$CLONE_DIR" cat-file -e "origin/main:$path" 2>/dev/null || die "$path is not on main yet; merge the PR that adds it first"
  done < "$dir/requires"
fi
WT=$(mktemp -d "${TMPDIR:-/tmp}/lh-lead.XXXXXX")
trap 'git -C "$CLONE_DIR" worktree remove --force "$WT" >/dev/null 2>&1 || true' EXIT

existing=false
if git -C "$CLONE_DIR" show-ref -q --verify "refs/remotes/origin/$branch"; then
  existing=true
  git -C "$CLONE_DIR" worktree add -q --detach "$WT" "origin/$branch"
  missing=()
  while IFS= read -r c; do
    git -C "$WT" log -1 --format=%B "$c" | grep -q '^Signed-off-by: ' || missing+=("$c")
  done < <(git -C "$WT" rev-list origin/main..HEAD)
  if [[ ${#missing[@]} -gt 0 ]]; then
    log "commits on $branch without a DCO sign-off:"
    for c in "${missing[@]}"; do git -C "$WT" log -1 --format='  %h  %an  %s' "$c"; done
    echo "Signing off certifies the DCO for these commits under your name (https://developercertificate.org/)."
    read -r -p "Have you reviewed them and do you certify them? Type yes: " answer
    [[ "$answer" == "yes" ]] || die "not certified; nothing changed"
  fi
  log "rebasing $branch onto main with sign-off"
  git -C "$WT" rebase -q --signoff origin/main
else
  git -C "$CLONE_DIR" worktree add -q --detach "$WT" origin/main
fi

shopt -s nullglob dotglob
for src in "$dir"/*; do
  name=$(basename "$src")
  case "$name" in commit.msg|pr-title|pr-body.md|requires) continue ;; esac
  [[ -f "$src" ]] || continue
  dest="$WT/${name//__//}"
  mkdir -p "$(dirname "$dest")"; cp "$src" "$dest"
done
git -C "$WT" add -A
if git -C "$WT" diff --cached --quiet; then
  log "no new changes from $dir"
else
  git -C "$WT" commit -q -s -F "$dir/commit.msg"
fi

if [[ "$existing" == true ]]; then
  git -C "$WT" push -q --force-with-lease="$branch:origin/$branch" origin "HEAD:refs/heads/$branch"
else
  git -C "$WT" push -q origin "HEAD:refs/heads/$branch"
fi

pr=$(gh pr list --repo "$ORG/$REPO" --head "$branch" --state open --json url --jq '.[0].url // empty')
if [[ -n "$pr" ]]; then
  log "PR: $pr"
else
  [[ -f "$dir/pr-title" && -f "$dir/pr-body.md" ]] || die "no open PR for $branch and no pr-title/pr-body.md in $dir"
  gh pr create --repo "$ORG/$REPO" --base main --head "$branch" \
    --title "$(cat "$dir/pr-title")" --body-file "$dir/pr-body.md"
fi
