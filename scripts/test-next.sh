#!/usr/bin/env bash
# Tests for scripts/next.sh with a stub backlog and a stub gh; needs bash.
#
#   scripts/test-next.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
pass=0 fail=0
check() { if [[ "$2" == 0 ]]; then pass=$((pass + 1)); echo "ok   $1"; else fail=$((fail + 1)); echo "FAIL $1"; fi; }

mkdir -p "$work/bin"
cat > "$work/backlog.sh" <<'SH'
#!/usr/bin/env bash
cat <<'OUT'
Next in each lane for LinuxHello/linux-hello (rule: docs/project/backlog.md)

implement  implementer: code it from the brief
  #10   next    Something with a brief
brief      lead: write the implementation brief
  #20   next    Something to brief
spike      lead or contributor with the hardware: run the spike
  #30   next    A spike
review     lead reviews, maintainer merges
  #41   next    All PRs merged
  #42   next    A PR is open
  #43   next    No PR at all
stuck      lead: diagnose the failed run
  #50   next    A failed run
untriaged  lead: set one status: and one priority: label
  #60   next    No labels
OUT
SH
# gh pr list --search "<n>": prints the lines in $work/prs.<n> ("<number> <STATE>"), or fails when there is no file.
cat > "$work/bin/gh" <<'SH'
#!/usr/bin/env bash
n=""
while [[ $# -gt 0 ]]; do [[ "$1" == --search ]] && n=$2; shift; done
[[ -f "$STUB_DIR/prs.$n" ]] || exit 1
cat "$STUB_DIR/prs.$n"
SH
chmod +x "$work/backlog.sh" "$work/bin/gh"
export PATH="$work/bin:$PATH" STUB_DIR="$work"
printf '165 MERGED\n163 MERGED\n' > "$work/prs.41"
printf '170 OPEN\n160 MERGED\n' > "$work/prs.42"
: > "$work/prs.43"

out=$(bash "$here/next.sh" "$work/backlog.sh")

check "the_backlog_output_is_printed_unchanged" "$([[ "$(bash "$work/backlog.sh")" == "$(head -n "$(bash "$work/backlog.sh" | wc -l)" <<<"$out")" ]]; echo $?)"

# The "What to do:" block of one issue: its lines up to the next issue's.
block() { awk -v n="$1" '/^What to do:/ {on=1; next} on && $0 ~ "^  #" n "  " {f=1; print; next} on && f && /^  #[0-9]+  / {exit} on && f {print}' <<<"$out"; }

for n in 10 20 30 41 42 43 50 60; do
  check "issue_${n}_gets_a_you_decide_line" "$(grep -q 'You decide:' <<<"$(block "$n")"; echo $?)"
done

b41=$(block 41); b42=$(block 42); b43=$(block 43)
check "a_review_issue_with_only_merged_prs_says_close_it" "$(grep -q 'merged' <<<"$b41" && grep -q 'gh issue close 41' <<<"$b41" && ! grep -q 'make signoff' <<<"$b41"; echo $?)"
check "the_merged_prs_are_named_so_the_maintainer_can_check" "$(grep -q '#165' <<<"$b41" && grep -q '#163' <<<"$b41"; echo $?)"
check "a_review_issue_with_an_open_pr_names_it_and_the_signoff_command" "$(grep -q 'make signoff PR=170' <<<"$b42" && ! grep -q 'gh issue close' <<<"$b42"; echo $?)"
check "a_review_issue_with_no_pr_says_the_label_may_be_wrong" "$(grep -qi 'no pr' <<<"$b43" && grep -q 'triage.tsv' <<<"$b43"; echo $?)"

b20=$(block 20)
check "a_brief_issue_says_what_to_check_before_writing_one" "$(grep -q 'blocked' <<<"$b20" && grep -q 'make draft-brief ISSUE=20' <<<"$b20"; echo $?)"
check "a_brief_issue_says_to_set_the_status_to_ready_after_posting" "$(grep -q 'After you post it' <<<"$b20" && grep -q 'status ready' <<<"$b20" && grep -q 'not the comments' <<<"$b20"; echo $?)"

rm "$work/prs.41" "$work/prs.42" "$work/prs.43"
out=$(bash "$here/next.sh" "$work/backlog.sh")
b42=$(block 42)
check "a_failing_gh_does_not_break_the_hints" "$(grep -q 'You decide:' <<<"$b42" && grep -q 'gh pr list' <<<"$b42"; echo $?)"

echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
