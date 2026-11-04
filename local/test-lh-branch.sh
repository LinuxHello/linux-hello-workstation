#!/usr/bin/env bash
# Tests for lh_select_branch (local/lh-branch.sh) in a throwaway git repository; needs only git.
#
#   local/test-lh-branch.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=local/lh-branch.sh
source "$here/lh-branch.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid

pass=0 fail=0
ok()  { pass=$((pass + 1)); echo "ok   $1"; }
nok() { fail=$((fail + 1)); echo "FAIL $1: $2"; }

# A repository whose origin/main is two commits ahead of the commit tagged "old".
new_repo() {
  local d="$work/$1"
  git init -q -b main "$d"
  cd "$d"
  git commit -q --allow-empty -m old && git tag old
  git commit -q --allow-empty -m newer
  git commit -q --allow-empty -m current
  git update-ref refs/remotes/origin/main HEAD
}

new_repo absent
if lh_select_branch issue-1 origin/main 2>/dev/null \
  && [[ "$(git branch --show-current)" == issue-1 && "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]]; then
  ok absent_branch_is_created_from_current_main
else nok absent_branch_is_created_from_current_main "branch $(git branch --show-current) at $(git log -1 --format=%s)"; fi

new_repo current
git switch -q -c issue-1 && git commit -q --allow-empty -m "model edits" && git switch -q main
kept=$(git rev-parse issue-1)
if lh_select_branch issue-1 origin/main 2>/dev/null \
  && [[ "$(git branch --show-current)" == issue-1 && "$(git rev-parse HEAD)" == "$kept" ]]; then
  ok branch_containing_current_main_is_reused_with_its_edits
else nok branch_containing_current_main_is_reused_with_its_edits "branch $(git branch --show-current) at $(git log -1 --format=%s)"; fi

new_repo stale
git branch issue-1 old
stale=$(git rev-parse issue-1)
if err=$(lh_select_branch issue-1 origin/main 2>&1); then
  nok stale_branch_is_refused "returned 0"
elif [[ "$(git branch --show-current)" != main || "$(git rev-parse issue-1)" != "$stale" ]]; then
  nok stale_branch_is_refused "switched to $(git branch --show-current) or moved issue-1"
elif [[ "$err" != *"issue-1"*"stale"*"git branch -D issue-1"* ]]; then
  nok stale_branch_is_refused "message does not name the branch and the fix: $err"
else ok stale_branch_is_refused_and_left_untouched; fi

echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
