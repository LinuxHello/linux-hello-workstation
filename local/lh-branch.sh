# shellcheck shell=bash
# Branch selection for lh-implement.sh; sourced, not run. Tested by local/test-lh-branch.sh.
#
#   lh_select_branch <branch> <base-ref>
#
# Creates <branch> from <base-ref> when it does not exist. Reuses an existing <branch> (for example
# one a failed run kept for inspection) only when it already contains <base-ref>. A branch that does
# not contain it is stale, left over from an older main, and the model would work on old code: the
# function then prints why, switches nothing and returns 1. It never deletes or moves a branch.

lh_select_branch() {
  local branch=$1 base=$2
  if git show-ref -q --verify "refs/heads/$branch"; then
    if ! git merge-base --is-ancestor "$base" "refs/heads/$branch"; then
      printf 'branch %s (%s) does not contain %s (%s): it is stale. Check it holds nothing you need, then delete it (git branch -D %s), or set LH_BRANCH to a new name\n' \
        "$branch" "$(git rev-parse --short "refs/heads/$branch")" "$base" "$(git rev-parse --short "$base")" "$branch" >&2
      return 1
    fi
    git switch -q "$branch"
  else
    git switch -q --no-track -c "$branch" "$base"
  fi
}
