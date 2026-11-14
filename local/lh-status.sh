# shellcheck shell=bash
# Source it, do not run it. Workstation-only.
#
# lh_set_status <repo> <issue> <status>   leaves the issue with exactly one status: label, <status>:
# adds it and removes every other status:* label the issue has. A failed run used to add status:ready and
# remove only status:in-progress, so an issue that had been in review ended up with two (#132, 2026-11-14).
# Never fails the caller: when the labels cannot be read, the target is still requested.
lh_set_status() {
  local repo=$1 n=$2 want=$3 have l
  local -a drop=()
  have=$(gh issue view "$n" --repo "$repo" --json labels --jq '.labels[].name' 2>/dev/null) || have=""
  for l in $have; do
    [[ "$l" == status:* && "$l" != "status:$want" ]] && drop+=(--remove-label "$l")
  done
  gh issue edit "$n" --repo "$repo" --add-label "status:$want" ${drop[@]+"${drop[@]}"} >/dev/null 2>&1 || true
}
