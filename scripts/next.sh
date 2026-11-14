#!/usr/bin/env bash
# make next: the backlog's next issue in each lane (scripts/backlog/backlog.sh in the linux-hello
# clone), printed unchanged, then for each issue what it is, what is left for the maintainer to
# decide, and the commands. A review-lane issue is checked against its pull requests: one whose PRs
# are all merged is reported as stale, not as waiting for review.
#
#   scripts/next.sh <path to backlog.sh>
set -euo pipefail
backlog=${1:?usage: next.sh <path to backlog.sh>}
: "${REPO_SLUG:=LinuxHello/linux-hello}"

out=$(bash "$backlog" next)
printf '%s\n' "$out"

# One block per issue: what it is, "You decide:" (what is left to the maintainer), and the commands.
hint() {  # hint <lane> <issue>
  local n=$2 prs open merged rc=0
  case "$1" in
    implement)
      echo "  #$n  a brief is posted; the local model can implement it"
      echo "        You decide: run it now (it takes the GPU for a while) or leave it"
      echo "        make implement ISSUE=$n          HARNESS=claude for Claude Code on it; needs a clean clone (make reset)" ;;
    brief)
      echo "  #$n  no implementation brief yet"
      echo "        You decide: is anything left to brief? If every remaining part waits on another issue, give it blocked-by"
      echo "        links (last column of its row in issues/triage.tsv, status stays needs-brief; then make triage APPLY=1)."
      echo "        An issue whose blockers are open drops out of this list. (status:blocked means a failed run, not this.)"
      echo "        Otherwise have the draft made, read it against the issue, and post it yourself as a comment:"
      echo "        make draft-brief ISSUE=$n        a local model drafts it into ~/.cache/linux-hello-drafts/ (posts nothing)"
      echo "        After you post it, set the issue to ready: its row in issues/triage.tsv gets status ready, then make triage APPLY=1."
      echo "        make next follows the labels, not the comments, so a posted brief changes nothing until you do." ;;
    spike)
      echo "  #$n  a spike: someone with the hardware (or the test VM) has to run it"
      echo "        You decide: run it yourself, or defer it (priority later in issues/triage.tsv)"
      echo "        gh issue view $n --repo $REPO_SLUG       no command runs a spike for you; the make vm-* targets give a test VM" ;;
    review)
      prs=$(gh pr list --repo "$REPO_SLUG" --search "$n" --state all --json number,state --jq '.[] | "\(.number) \(.state)"' 2>/dev/null) || rc=$?
      if [[ $rc -ne 0 ]]; then
        echo "  #$n  a pull request is waiting for review (gh could not be asked which)"
        echo "        You decide: read it, then merge it or send it back"
        echo "        gh pr list --repo $REPO_SLUG --search \"$n\" --state open"
        echo "        then: make signoff PR=<number>, then merge"
      else
        open=$(awk '$2 == "OPEN" {printf "%s#%s", sep, $1; sep=", "}' <<<"$prs")
        merged=$(awk '$2 == "MERGED" {printf "%s#%s", sep, $1; sep=", "}' <<<"$prs")
        if [[ -n "$open" ]]; then
          echo "  #$n  review: ${open} is open"
          echo "        You decide: read it; if it is good, certify and merge it"
          for pr in $(awk '$2 == "OPEN" {print $1}' <<<"$prs"); do
            echo "        gh pr view $pr --repo $REPO_SLUG    then: make signoff PR=$pr, then merge"
          done
        elif [[ -n "$merged" ]]; then
          echo "  #$n  review: every pull request that mentions it is merged (${merged}); nothing is left to review"
          echo "        You decide: if the issue's work is done, close it; its status label is stale"
          echo "        gh issue close $n --repo $REPO_SLUG"
        else
          echo "  #$n  review: no PR found that mentions it"
          echo "        You decide: the label may be wrong; set its status in issues/triage.tsv and run make triage APPLY=1"
        fi
      fi ;;
    stuck)
      echo "  #$n  a run failed"
      echo "        You decide: fix the brief and retry, or correct the code by hand"
      echo "        gh issue view $n --repo $REPO_SLUG       run logs: ~/.local/state/linux-hello-implementer/logs/; make reset before a retry" ;;
    untriaged)
      echo "  #$n  no status or priority label yet"
      echo "        You decide: its status and its priority"
      echo "        set them in issues/triage.tsv, then make triage APPLY=1" ;;
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
[[ -z "$hints" ]] || { printf '\nWhat to do:\n%s\n' "$hints"; }
