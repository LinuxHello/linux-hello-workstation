#!/usr/bin/env bash
# make next: the backlog's next issue in each lane (scripts/backlog/backlog.sh in the linux-hello
# clone), then the command that starts each one. The backlog output is printed unchanged.
#
#   scripts/next.sh <path to backlog.sh>
set -euo pipefail
backlog=${1:?usage: next.sh <path to backlog.sh>}
: "${REPO_SLUG:=LinuxHello/linux-hello}"

out=$(bash "$backlog" next)
printf '%s\n' "$out"

hint() {  # hint <lane> <issue>
  local n=$2
  case "$1" in
    implement)
      echo "  #$n  make implement ISSUE=$n                 local model, free; HARNESS=claude for Claude Code on it"
      echo "        (needs the issue to have an '## Implementation brief' and a clean clone: make reset)" ;;
    brief)
      echo "  #$n  gh issue view $n --repo $REPO_SLUG       read it, then write the brief as an issue comment"
      echo "        make claude-gpu                       local Claude Code to draft it; the desktop app is billed" ;;
    spike)
      echo "  #$n  gh issue view $n --repo $REPO_SLUG       needs the hardware; no command runs it for you" ;;
    review)
      echo "  #$n  gh pr list --repo $REPO_SLUG --search \"$n\" --state open"
      echo "        read the PR, then: make signoff PR=<number>, then merge" ;;
    stuck)
      echo "  #$n  gh issue view $n --repo $REPO_SLUG       run logs: ~/.local/state/linux-hello-implementer/logs/" ;;
    untriaged)
      echo "  #$n  add one status: and one priority: label, or set it in issues/triage.tsv and make triage APPLY=1" ;;
  esac
}

lane=
hints=$(
  while IFS= read -r line; do
    if [[ "$line" =~ ^([a-z]+)[[:space:]]{2,} ]]; then lane=${BASH_REMATCH[1]}
    elif [[ "$line" =~ ^[[:space:]]+#([0-9]+) ]]; then hint "$lane" "${BASH_REMATCH[1]}"
    fi
  done <<<"$out"
)
[[ -z "$hints" ]] || { printf '\nHow to start:\n%s\n' "$hints"; }
