#!/usr/bin/env bash
# Rewrite a repository's history so that no commit and no commit message describes the
# maintainer's machine (linux-hello AGENTS.md, invariant 8). For a repository that is about to be
# made public, or one where such a detail slipped in. Any maintainer can run it; each keeps the
# replacement rules in their own config, because the rules name what they hide.
#
#   make history-clean REPO=linux-hello-workstation          rewrite a fresh copy and check it
#   make history-clean REPO=linux-hello-workstation PUSH=1   ... and force-push it to GitHub
#
# Needs git-filter-repo (sudo apt install git-filter-repo) and gh.
#
# Rules: ${LH_HISTORY_RULES:-~/.config/linux-hello/history-replacements.txt}, in the
# git-filter-repo --replace-text format, one rule per line (local/history-replacements.example):
#   literal text==>replacement
#   regex:(?i)\bsome-host\b==>workstation
# The same rules apply to file contents and to commit messages. Author names and Signed-off-by
# lines are not touched.
#
# Without PUSH=1 nothing leaves this machine: the rewritten copy stays in
# ${LH_HISTORY_WORK:-~/.cache/linux-hello/history-clean}/<repo>.git to inspect. The copy is checked
# with scripts/check-public.sh --history and the run stops if anything is left.
#
# With PUSH=1, after you type the repository's name:
#  - every branch and tag is force-pushed. The ruleset on main refuses that (no force-push,
#    signed commits only), so an admin must allow it first, e.g. by adding themselves to the
#    ruleset's bypass list for the run. The rewritten commits lose their signatures.
#  - the run refuses while pull requests are open: they would point at the old commits.
#  - every clone and worktree must then be cloned again (or reset to the new main); a push from
#    an old clone brings the old history back.
#  - GitHub still serves the old commits by their hashes, and closed pull requests keep them,
#    until GitHub Support removes them ("Removing sensitive data from a repository").
set -euo pipefail
source "$(dirname "$0")/../common.sh"
root="$(cd "$(dirname "$0")/.." && pwd)"

rules=${LH_HISTORY_RULES:-${XDG_CONFIG_HOME:-$HOME/.config}/linux-hello/history-replacements.txt}
work=${LH_HISTORY_WORK:-${XDG_CACHE_HOME:-$HOME/.cache}/linux-hello/history-clean}
slug="$ORG/$REPO"
push=${PUSH:-0}

command -v git-filter-repo >/dev/null || die "git-filter-repo not installed (sudo apt install git-filter-repo)"
command -v gh >/dev/null || die "gh not installed"
[[ -s "$rules" ]] || die "no replacement rules at $rules (format: local/history-replacements.example)"

open=$(gh pr list --repo "$slug" --state open --json number --jq 'map(.number) | join(" ")')
if [[ -n "$open" ]]; then
  [[ "$push" == 1 ]] && die "$slug has open pull requests ($open); merge or close them first"
  log "note: $slug has open pull requests ($open); a push would have to wait for them"
fi

repo="$work/$REPO.git"
rm -rf "$repo"
mkdir -p "$work"
log "cloning $slug into $repo"
git clone -q --bare "git@github.com:$slug.git" "$repo"
before=$(git -C "$repo" rev-list --all | wc -l)

log "rewriting file contents and commit messages with $rules"
git -C "$repo" filter-repo --quiet --force --replace-text "$rules" --replace-message "$rules"
changed=$(awk 'NR>1 && $1 != $2' "$repo/filter-repo/commit-map" | wc -l)
log "$changed of $before commits changed"

log "checking every commit and message of the rewritten copy"
bash "$root/scripts/check-public.sh" --history "$repo" \
  || die "the rules leave the lines above; add rules to $rules and run again (nothing was pushed)"

if [[ "$push" != 1 ]]; then
  log "dry run: nothing pushed. Inspect $repo (git -C $repo log -p), then run again with PUSH=1"
  exit 0
fi

read -r -p "Force-push the rewritten history of $slug? Every clone must be made again. Type $REPO to go on: " answer </dev/tty
[[ "$answer" == "$REPO" ]] || die "not confirmed; nothing pushed"
git -C "$repo" remote add origin "git@github.com:$slug.git"
git -C "$repo" push --force origin 'refs/heads/*:refs/heads/*' 'refs/tags/*:refs/tags/*'
log "pushed. Clone $slug again everywhere (or: git fetch origin && git reset --hard origin/main in a clean clone, and remove old worktrees)"
