#!/usr/bin/env bash
# Tests for local/lh-draft-next.sh (make draft-next-brief) with a stub gh, backlog, drafting step and
# evaluator claude; no model and no GitHub. Needs bash, python3, git, jq.
#
#   local/test-lh-draft-next.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
pass=0 fail=0
check() { if [[ "$2" == 0 ]]; then pass=$((pass + 1)); echo "ok   $1"; else fail=$((fail + 1)); echo "FAIL $1"; fi; }

mkdir -p "$work/bin" "$work/clone/src" "$work/drafts"
# The clone: origin/main has src/lib.rs "committed_version"; the working tree differs.
git -C "$work/clone" init -q -b main
printf '### The brief\n\nA brief has parts.\n\n### Review\n\nx\n' > "$work/clone/AGENTS.md"
printf 'pub fn committed_version() {}\n' > "$work/clone/src/lib.rs"
git -C "$work/clone" add -A
git -C "$work/clone" -c user.name=t -c user.email=t@example.org -c commit.gpgsign=false commit -q -m x
git -C "$work/clone" update-ref refs/remotes/origin/main HEAD
printf 'pub fn uncommitted_edit() {}\n' > "$work/clone/src/lib.rs"

# gh: comments of an issue ($FIX/briefs-<n>: how many brief comments it has), comment and edit are logged.
cat > "$work/bin/gh" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$FIX/gh.log"
case "$1 $2" in
  "issue view")
    n=$3
    case "$*" in
      *"--json comments"*) cat "$FIX/briefs-$n" 2>/dev/null || echo 0 ;;
      *"--json title,body"*) printf '# Title of %s\n\nThe body of the issue.\n' "$n" ;;
      *) echo "unexpected gh $*" >&2; exit 1 ;;
    esac ;;
  "issue comment") echo "https://github.com/x/y/issues/$3#issuecomment-1" ;;
  "issue edit") ;;
  *) echo "unexpected gh $*" >&2; exit 1 ;;
esac
SH
# The backlog: json of the open issues.
cat > "$work/bin/fake-backlog" <<'SH'
#!/usr/bin/env bash
[[ "$1" == json ]] || { echo "unexpected backlog $*" >&2; exit 2; }
cat "$FIX/backlog.json"
SH
# The drafting step: writes the brief the case prepared.
cat > "$work/bin/fake-draft" <<'SH'
#!/usr/bin/env bash
echo "draft $*" >> "$FIX/draft.log"
cp "$FIX/draft-$2.md" "$LH_DRAFT_DIR/brief-$2.md"
SH
# The evaluator's claude: records how it was called, answers from $FIX/verdict.json inside prose.
cat > "$work/bin/claude" <<'SH'
#!/usr/bin/env bash
echo "$*" > "$FIX/claude.args"
{ echo "cwd=$PWD"; echo "GH_TOKEN=${GH_TOKEN-unset}"; echo "BASE=${ANTHROPIC_BASE_URL-unset}"; echo "KEY=${ANTHROPIC_API_KEY-unset}"; } > "$FIX/claude.env"
cp src/lib.rs "$FIX/claude.snapshot-lib" 2>/dev/null || true
[[ -f "$FIX/claude-fails" ]] && { echo "boom" >&2; exit 1; }
printf 'Here is my review.\n'; cat "$FIX/verdict.json"; printf '\nDone.\n'
SH
cat > "$work/bin/pgrep" <<'SH'
#!/usr/bin/env bash
[[ -f "$FIX/implementer-running" ]] && exit 0 || exit 1
SH
chmod +x "$work"/bin/*

GOOD_BRIEF=$'## Implementation brief\n\n### 1. Goal\nDo the thing.\n\n### 2. Files\n\n- `src/lib.rs`: the change.\n\n### 3. Properties and tests first\n\n- `brand_new_test_name`: it works.\n\n### 6. Out of scope\nNothing else.\n'
OK_VERDICT='{"verdict":"ok","summary":"Makes the store refuse a bad request.","checked":["Every file the brief names exists","The test it adds is new"],"problems":[],"new_files":false}'
BAD_VERDICT='{"verdict":"problems","summary":"Makes the store refuse a bad request.","checked":["Every file the brief names exists"],"problems":[{"id":"P1","what":"The brief says to change a test that is already there and must not be renamed.","why":"The run would be refused by the safety check.","fix":"Keep the old test name and add a new test beside it.","who":"ai","blocking":true},{"id":"P2","what":"It is unclear whether a refused request should be logged.","why":"Logging changes what an administrator can see.","fix":"","who":"maintainer","question":"Should a refused request be written to the system log?","options":["A. Yes, always","B. No, only counts"],"recommendation":"A","blocking":true}],"new_files":true}'

FIX=""
new_case() {
  FIX="$work/$1"; mkdir -p "$FIX"; : > "$FIX/gh.log"; : > "$FIX/draft.log"
  printf '%s\n' '[
    {"number":22,"title":"ADR: names before the first publish","lane":"brief","blocked_by":0,"order":1},
    {"number":131,"title":"A blocked issue","lane":"brief","blocked_by":1,"order":2},
    {"number":50,"title":"A spike","lane":"spike","blocked_by":0,"order":3},
    {"number":146,"title":"User policy store: error paths report the wrong outcome","lane":"brief","blocked_by":0,"order":4},
    {"number":147,"title":"Another issue","lane":"brief","blocked_by":0,"order":5}
  ]' > "$FIX/backlog.json"
  printf '%s\n' "$GOOD_BRIEF" > "$FIX/draft-146.md"
  printf '%s\n' "$GOOD_BRIEF" > "$FIX/draft-147.md"
  printf '%s\n' "$OK_VERDICT" > "$FIX/verdict.json"
}
out="" status=0
run() { # run the command with the stubs; extra env first
  status=0
  out="$(env FIX="$FIX" PATH="$work/bin:$PATH" CLONE_DIR="$work/clone" REPO_SLUG=LinuxHello/linux-hello \
        LH_BACKLOG="$work/bin/fake-backlog" LH_DRAFT_CMD="$work/bin/fake-draft" LH_DRAFT_DIR="$work/drafts" \
        LH_MEMORY_ENV=/nonexistent LH_MEMORY_DIR="$work/none" \
        GH_TOKEN=secret ANTHROPIC_BASE_URL=http://127.0.0.1:1 ANTHROPIC_API_KEY=local "$@" \
        bash "$here/lh-draft-next.sh" 2>&1)" || status=$?
}
published() { grep -q 'issue comment' "$FIX/gh.log"; }

new_case picks
run
check "the_first_unblocked_brief_issue_is_picked_and_adrs_are_skipped_aloud" "$([[ $status -eq 0 ]] && grep -q 'draft brief 146' "$FIX/draft.log" && grep -q '#22' <<<"$out" && grep -qi 'decision' <<<"$out" && ! grep -q 'draft brief 22' "$FIX/draft.log"; echo $?)"
check "a_blocked_issue_and_a_spike_are_never_picked" "$(! grep -qE 'draft brief (131|50)' "$FIX/draft.log"; echo $?)"
check "a_clean_brief_is_published_with_the_documented_command" "$(grep -q "issue comment 146 --repo LinuxHello/linux-hello --body-file $work/drafts/brief-146.md" "$FIX/gh.log"; echo $?)"
check "a_published_issue_is_set_to_ready" "$(grep -q 'issue edit 146 --repo LinuxHello/linux-hello --add-label status:ready' "$FIX/gh.log"; echo $?)"
check "the_result_says_it_was_published" "$(grep -qi 'published' <<<"$out" && ! grep -qi 'NOT PUBLISHED' <<<"$out"; echo $?)"

new_case explicit
run LH_ISSUE=147
check "an_explicit_issue_overrides_the_pick" "$([[ $status -eq 0 ]] && grep -q 'draft brief 147' "$FIX/draft.log" && ! grep -q 'draft brief 146' "$FIX/draft.log"; echo $?)"

new_case rejected
printf '%s\n' "$BAD_VERDICT" > "$FIX/verdict.json"
run
check "a_brief_the_evaluator_rejects_is_not_published" "$([[ $status -eq 2 ]] && ! published && grep -q 'NOT PUBLISHED' <<<"$out"; echo $?)"
check "a_rejected_issue_is_not_set_to_ready" "$(! grep -q 'issue edit' "$FIX/gh.log"; echo $?)"
check "the_report_names_the_decision_with_options_and_a_recommendation" "$(grep -q 'Needs your decision' <<<"$out" && grep -q 'Should a refused request be written to the system log' <<<"$out" && grep -q 'A. Yes, always' <<<"$out" && grep -q 'recommend' <<<"$out"; echo $?)"
check "the_report_lists_what_the_lead_will_fix_apart_from_the_decisions" "$(grep -q 'Mine to fix' <<<"$out" && grep -q 'already there and must not be renamed' <<<"$out"; echo $?)"
check "the_report_is_plain_text_not_json" "$(! grep -q '"verdict"' <<<"$out" && ! grep -q '"problems"' <<<"$out"; echo $?)"
check "the_report_is_saved_beside_the_brief" "$([[ -s "$work/drafts/report-146.md" ]] && grep -q 'Needs your decision' "$work/drafts/report-146.md"; echo $?)"
check "a_new_file_brief_is_called_out" "$(grep -qi 'new files' <<<"$out"; echo $?)"

new_case skips_briefed
echo 1 > "$FIX/briefs-146"
run
check "an_issue_that_already_has_a_brief_is_skipped_when_picking" "$([[ $status -eq 0 ]] && grep -q 'draft brief 147' "$FIX/draft.log" && ! grep -q 'draft brief 146' "$FIX/draft.log" && grep -q '#146' <<<"$out" && grep -qi 'already has a brief' <<<"$out"; echo $?)"

new_case has_brief
echo 1 > "$FIX/briefs-146"
run LH_ISSUE=146
check "a_named_issue_that_already_has_a_brief_is_never_published_over" "$([[ $status -eq 2 ]] && ! published && grep -qi 'already has a brief' <<<"$out"; echo $?)"
check "a_named_issue_that_already_has_a_brief_is_not_drafted_again" "$(! grep -q 'draft brief 146' "$FIX/draft.log"; echo $?)"

new_case eval_fails
touch "$FIX/claude-fails"
run
check "an_evaluator_that_fails_publishes_nothing" "$([[ $status -eq 2 ]] && ! published && grep -qi 'could not be evaluated' <<<"$out"; echo $?)"

new_case eval_garbage
printf 'I could not decide.' > "$FIX/verdict.json"
run
check "an_evaluator_answer_that_is_not_json_publishes_nothing" "$([[ $status -eq 2 ]] && ! published && grep -qi 'could not be evaluated' <<<"$out"; echo $?)"

new_case eval_wrong_shape
printf '{"verdict":"maybe"}' > "$FIX/verdict.json"
run
check "a_verdict_that_is_neither_ok_nor_problems_publishes_nothing" "$([[ $status -eq 2 ]] && ! published; echo $?)"

new_case ok_with_blocking_problem
printf '%s\n' '{"verdict":"ok","summary":"s","checked":[],"problems":[{"id":"P1","what":"w","why":"y","fix":"f","who":"ai","blocking":true}],"new_files":false}' > "$FIX/verdict.json"
run
check "a_blocking_problem_stops_publishing_even_if_the_verdict_says_ok" "$([[ $status -eq 2 ]] && ! published; echo $?)"

new_case nonblocking
printf '%s\n' '{"verdict":"ok","summary":"s","checked":["c"],"problems":[{"id":"P1","what":"A minor wording point.","why":"None for the run.","fix":"f","who":"ai","blocking":false}],"new_files":false}' > "$FIX/verdict.json"
run
check "a_non_blocking_note_does_not_stop_publishing_and_is_reported" "$([[ $status -eq 0 ]] && published && grep -q 'A minor wording point' <<<"$out"; echo $?)"

new_case no_heading
printf 'Just some text with no heading.\n' > "$FIX/draft-146.md"
run
check "a_draft_without_the_brief_heading_is_not_published" "$([[ $status -eq 2 ]] && ! published; echo $?)"

new_case isolation
run
check "the_evaluator_has_read_tools_only" "$(grep -q -- '--tools Read,Grep,Glob' "$FIX/claude.args" && ! grep -qE -- '--tools [^ ]*(Bash|Write|Edit)' "$FIX/claude.args"; echo $?)"
check "the_evaluator_gets_no_github_token_and_no_local_model_settings" "$(grep -q 'GH_TOKEN=unset' "$FIX/claude.env" && grep -q 'BASE=unset' "$FIX/claude.env" && grep -q 'KEY=unset' "$FIX/claude.env"; echo $?)"
check "the_evaluator_reads_origin_main_not_the_working_tree" "$(grep -q committed_version "$FIX/claude.snapshot-lib" && ! grep -q uncommitted_edit "$FIX/claude.snapshot-lib"; echo $?)"
check "the_evaluator_does_not_run_in_the_clone" "$(! grep -q "cwd=$work/clone" "$FIX/claude.env"; echo $?)"

new_case mechanical
printf '%s\n' $'## Implementation brief\n\n### 2. Files\n\n- `src/lib.rs`: x\n\n### 3. Properties and tests first\n\n- `brand_new_test_name`: it works. (unverified)\n' > "$FIX/draft-146.md"
run
check "findings_of_the_mechanical_checks_reach_the_evaluator_but_do_not_block_alone" "$([[ $status -eq 0 ]] && published && grep -q 'HEDGES' "$FIX/claude.args"; echo $?)"

new_case busy
touch "$FIX/implementer-running"
run
check "a_running_implementer_stops_the_flow_before_anything_is_drafted" "$([[ $status -ne 0 ]] && grep -qi 'implementer' <<<"$out" && [[ ! -s "$FIX/draft.log" ]]; echo $?)"

new_case dry
run LH_DRY=1
check "a_dry_run_publishes_nothing_even_for_a_clean_brief" "$([[ $status -eq 0 ]] && ! published && grep -qi 'dry run' <<<"$out"; echo $?)"

echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
