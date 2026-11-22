#!/usr/bin/env bash
# Tests for local/lh-draft.sh with a stub model server, a stub claude and a stub gh; needs bash,
# python3, curl, jq, git.
#
#   local/test-lh-draft.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
work=$(mktemp -d)
srv=""
trap '[[ -z "$srv" ]] || kill "$srv" 2>/dev/null || true; rm -rf "$work"' EXIT
pass=0 fail=0
check() { if [[ "$2" == 0 ]]; then pass=$((pass + 1)); echo "ok   $1"; else fail=$((fail + 1)); echo "FAIL $1"; fi; }

mkdir -p "$work/srv" "$work/bin" "$work/clone" "$work/arch/templates" "$work/drafts"
python3 "$here/stub-ollama.py" "$work/srv" draft-model:1 implement-model:1 & srv=$!
for _ in $(seq 50); do [[ -s "$work/srv/port" ]] && break; sleep 0.1; done
port=$(cat "$work/srv/port")
export OLLAMA_HOST="http://127.0.0.1:$port"

# A clone with the rules the prompt quotes, an ADR template, and stubs for gh and claude.
git -C "$work/clone" init -q
printf '### The brief\n\nA brief has six parts.\n\n### Review\n\nx\n' > "$work/clone/AGENTS.md"
printf -- '---\ntype: adr\n---\n# ADR-NNNN: Title\n' > "$work/arch/templates/adr.md"
cat > "$work/bin/gh" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$STUB_DIR/gh.log"
case "$*" in
  *"--jq"*) printf '## Implementation brief\nexample\n' ;;
esac
SH
cat > "$work/bin/claude" <<'SH'
#!/usr/bin/env bash
echo "$*" > "$STUB_DIR/claude.args"
echo CALL >> "$STUB_DIR/claude.ncalls"
# fail_once: the first call answers like a model that tried a tool that does not exist; fail_always: every call does.
if [[ -f "$STUB_DIR/fail_once" ]]; then rm -f "$STUB_DIR/fail_once"; echo "Error: Reached max turns (3)"; exit 1; fi
if [[ -f "$STUB_DIR/fail_always" ]]; then echo "Error: Reached max turns (3)"; exit 1; fi
echo "token=${GH_TOKEN:-unset} out=${CLAUDE_CODE_MAX_OUTPUT_TOKENS:-unset} base=${LH_CLAUDE_BASE_URL:-unset}" > "$STUB_DIR/claude.env"
cp "$STUB_DIR/srv/loaded" "$STUB_DIR/loaded.during"
cat "$STUB_DIR/answer"
SH
cat > "$work/bin/pgrep" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x "$work"/bin/*
# The tests never read the maintainer's real memory or its configuration: the memory tests below set both.
export LH_MEMORY_ENV=/nonexistent LH_MEMORY_DIR="$work/no-memory"
export PATH="$work/bin:$PATH" STUB_DIR="$work" CLONE_DIR="$work/clone" ARCH_REPO_DIR="$work/arch" \
  LH_DRAFT_DIR="$work/drafts" LH_MODELS_ENV="$work/models.env" GH_TOKEN=secret
printf 'LH_MODEL_DRAFT=draft-model:1\nLH_CTX_DRAFT=32768\n' > "$work/models.env"

printf 'implement-model:1\n' > "$work/srv/loaded"
printf 'Sure, here is the brief.\n## Implementation brief\n### 1. Goal\nDo it.\n### 3. Properties and tests first\n- `a_test_that_fails`: it works.\n' > "$work/answer"
bash "$here/lh-draft.sh" brief 7 > "$work/out" 2>&1; rc=$?
check "a_brief_draft_is_written" "$([[ $rc -eq 0 && -f "$work/drafts/brief-7.md" ]]; echo $?)"
check "preamble_before_the_heading_is_dropped" "$([[ "$(head -1 "$work/drafts/brief-7.md")" == "## Implementation brief" ]]; echo $?)"
check "the_draft_model_was_the_only_one_loaded_during_the_run" "$([[ "$(tr -d '\n' < "$work/loaded.during")" == draft-model:1 ]]; echo $?)"
check "the_draft_model_is_unloaded_afterwards" "$([[ -z "$(tr -d '\n ' < "$work/srv/loaded")" ]]; echo $?)"
check "the_first_brief_pass_has_no_tools" "$(grep -qE -- '--tools  ?--max-turns 3'  "$work/claude.args"; echo $?)"
check "the_model_gets_no_github_token" "$(grep -q "token=unset" "$work/claude.env"; echo $?)"
check "the_reply_cap_leaves_room_in_a_small_window" "$(grep -q "out=6000" "$work/claude.env"; echo $?)"
check "thinking_is_switched_off_through_the_relay" "$(grep -qE 'base=http://127.0.0.1:[0-9]+' "$work/claude.env"; echo $?)"
check "nothing_is_posted_to_github" "$(! grep -Eq 'issue (comment|edit|create|close)|pr ' "$work/gh.log"; echo $?)"
check "test_names_are_counted_for_the_implementer_gate" "$(grep -q '1 test name' "$work/out"; echo $?)"

printf 'I could not do it.\n' > "$work/answer"
rc=0; bash "$here/lh-draft.sh" brief 8 > "$work/out" 2>&1 || rc=$?
check "an_answer_without_the_brief_heading_is_rejected" "$([[ $rc -ne 0 && ! -f "$work/drafts/brief-8.md" && -f "$work/drafts/brief-8.md.rejected" ]]; echo $?)"

printf 'Here you go:\n---\ntype: adr\n---\n# ADR-0019: Platforms\n' > "$work/answer"
rc=0; bash "$here/lh-draft.sh" adr "Supported platforms" "AppArmor only" > "$work/out" 2>&1 || rc=$?
check "an_adr_draft_starts_at_its_frontmatter" "$([[ $rc -eq 0 && "$(head -1 "$work/drafts/adr-supported-platforms.md")" == --- ]]; echo $?)"
# The maintainer's rule for documents: a reader with no earlier knowledge must be able to follow them.
check "the_adr_prompt_asks_for_a_text_a_newcomer_can_follow" "$(grep -q 'reader who is new to the subject' "$work/claude.args" && grep -q 'Explain every term' "$work/claude.args"; echo $?)"

printf 'draft-model:1\n' > "$work/srv/loaded"
cat > "$work/bin/pgrep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
printf 'implement-model:1\n' > "$work/srv/loaded"
rc=0; bash "$here/lh-draft.sh" brief 9 > "$work/out" 2>&1 || rc=$?
check "a_model_in_use_by_a_session_is_not_evicted" "$([[ $rc -ne 0 ]] && grep -q 'interactive session' "$work/out"; echo $?)"

printf '#!/usr/bin/env bash\nexit 1\n' > "$work/bin/pgrep"
# Refining: a brief with a hedge and a name that exists nowhere is sent back; a clean one is not.
printf '## Implementation brief\n### 3. Properties and tests first\n- `hedged_test_name`: works.\nCall `ghost_helper_fn` (unverified: check api.rs).\n' > "$work/answer"
printf 'implement-model:1\n' > "$work/srv/loaded"
rc=0; bash "$here/lh-draft.sh" brief 10 > "$work/out" 2>&1 || rc=$?
check "a_hedged_brief_is_sent_back_for_refining" "$([[ $rc -eq 0 ]] && grep -q 'refine round 1' "$work/out" && grep -q 'refine round 2' "$work/out" && grep -q 'DEFECTS FOUND' "$work/claude.args"; echo $?)"
check "refining_can_only_read" "$(grep -q 'tools Read,Grep,Glob --allowedTools Read Grep Glob' "$work/claude.args"; echo $?)"
check "the_defects_name_the_hedge_and_the_missing_name" "$(grep -q 'ghost_helper_fn' "$work/out" && grep -q 'HEDGES' "$work/out"; echo $?)"
check "each_refined_version_is_kept" "$([[ -f "$work/drafts/brief-10.md.round0" ]]; echo $?)"
check "what_is_still_open_is_reported" "$(grep -q 'still open after refining' "$work/out"; echo $?)"
printf 'implement-model:1\n' > "$work/srv/loaded"
printf '## Implementation brief\n### 3. Properties and tests first\n- `clean_test_name`: works.\n' > "$work/answer"
rc=0; bash "$here/lh-draft.sh" brief 11 > "$work/out" 2>&1 || rc=$?
check "a_clean_brief_is_not_refined" "$([[ $rc -eq 0 ]] && ! grep -q 'refine round' "$work/out"; echo $?)"
printf 'implement-model:1\n' > "$work/srv/loaded"
printf '## Implementation brief\n- `hedged_test_name`: works. (unverified)\n' > "$work/answer"
rc=0; LH_DRAFT_ROUNDS=0 bash "$here/lh-draft.sh" brief 12 > "$work/out" 2>&1 || rc=$?
check "rounds_zero_turns_refining_off" "$([[ $rc -eq 0 ]] && ! grep -q 'refine round' "$work/out"; echo $?)"

# Cross-checks on a brief's sections.
mkdir -p "$work/clone/src"; printf 'pub fn existing_test_name() {}\n' > "$work/clone/src/t.rs"; git -C "$work/clone" add src/t.rs
printf 'fn existing_test_name() {}\n' > "$work/clone/src/t.rs"
bad=$'## Implementation brief\n### 1. Goal\nChange `src/lib.rs` and `src/other.rs`.\n### 2. Files\nExactly one file:\n- `src/lib.rs`: x\n- `src/t.rs`: y\n### 3. Properties and tests first\n- `fresh_test_name`: a\n- `fresh_test_name`: b\n- `existing_test_name`: c\n### 6. Out of scope\n`src/t.rs` and #55.\n'
cc=$(printf '%s\n' "$bad" | python3 -I "$here/lh-brief-checks.py" "$work/clone")
check "a_stated_file_count_is_checked_against_the_list" "$(grep -q "says 'Exactly one file' but lists 2" <<<"$cc"; echo $?)"
check "a_source_file_outside_the_files_section_is_found" "$(grep -q 'src/other.rs. is named under .goal' <<<"$cc"; echo $?)"
check "an_out_of_scope_item_in_files_is_found" "$(grep -q 'src/t.rs. is listed out of scope' <<<"$cc"; echo $?)"
check "a_duplicate_test_is_found" "$(grep -q 'fresh_test_name. is listed twice' <<<"$cc"; echo $?)"
check "a_new_test_that_already_exists_is_found" "$(grep -q 'existing_test_name. already exists' <<<"$cc"; echo $?)"
good=$'## Implementation brief\n### 2. Files\nExactly two files:\n- `src/lib.rs`: x\n- `src/t.rs`: y\n### 3. Properties and tests first\n- `fresh_test_name`: a\n- `existing_test_name`: existing, unchanged\n### 6. Out of scope\nThe bus.\n'
check "a_consistent_brief_has_no_findings" "$([[ -z "$(printf '%s\n' "$good" | python3 -I "$here/lh-brief-checks.py" "$work/clone")" ]]; echo $?)"
source "$here/lh-brief.sh"; source "$here/lh-context.sh"
pts=$(lh_brief_open_points "$work/clone" "" "$bad")
check "the_lint_reports_inconsistencies" "$(grep -q INCONSISTENT <<<"$pts"; echo $?)"

# Out-of-scope names that are not files the brief edits (a prose mention, a bare word, a directory
# prefix, a C4 owner) are not conflicts; a listed file or a test name that is also out of scope still is.
fp=$'## Implementation brief\n### 2. Files\nDo not change `src/merge.rs`. Where a bullet names `agent`, that is a C4 owner, not a file.\n- `crates/linuxhello-agent/tests/props.rs`: x\n- `docs/security/properties.md`: y\n### 3. Properties and tests first\n- `fresh_test_name`: a\n### 6. Out of scope\n`src/merge.rs`; all of `crates/`; `agent`; `security/`; `tpmProvider`.\n'
cc=$(printf '%s\n' "$fp" | python3 -I "$here/lh-brief-checks.py" "$work/clone")
check "scope_check_ignores_prose_mentions_bare_words_and_directory_prefixes" "$([[ -z "$(grep SCOPE <<<"$cc")" ]]; echo $?)"
bp=$'## Implementation brief\n### 2. Files\n- `src/lib.rs`: x\n### 3. Properties and tests first\n- `fresh_test_name`: a\n### 6. Out of scope\n`lib.rs`; `fresh_test_name`.\n'
cc=$(printf '%s\n' "$bp" | python3 -I "$here/lh-brief-checks.py" "$work/clone")
check "scope_check_matches_a_basename_to_a_listed_path" "$(grep -q 'lib.rs. is listed out of scope' <<<"$cc"; echo $?)"
check "scope_check_finds_a_test_name_that_is_also_out_of_scope" "$(grep -q 'fresh_test_name. is listed out of scope' <<<"$cc"; echo $?)"

# The context builder: outlines named files, finds identifiers, ignores files that do not exist.
source "$here/lh-context.sh"
mkdir -p "$work/clone/src"
printf 'pub struct Frame {}\npub fn verify_frame(f: &Frame) {}\n#[cfg(test)]\nmod tests {\n    fn helper() {}\n}\n' > "$work/clone/src/lib.rs"
git -C "$work/clone" add src/lib.rs
ctx=$(lh_draft_context "$work/clone" 'Change `verify_frame` in src/lib.rs and gone/missing.rs')
check "context_outlines_a_named_file" "$(grep -q '### src/lib.rs (6 lines)' <<<"$ctx" && grep -q 'fn verify_frame' <<<"$ctx"; echo $?)"
check "context_skips_a_file_that_does_not_exist" "$(! grep -q missing.rs <<<"$ctx"; echo $?)"
check "context_finds_a_named_identifier" "$(grep -q 'Definitions' <<<"$ctx"; echo $?)"
ctx=$(LH_DRAFT_CONTEXT_BYTES=40 lh_draft_context "$work/clone" 'src/lib.rs')
check "context_is_capped" "$(grep -q 'cut at 40 bytes' <<<"$ctx"; echo $?)"
check "no_file_named_is_said_plainly" "$(lh_draft_context "$work/clone" 'nothing here' | grep -q 'names no file'; echo $?)"

# The facts the harness checks for the prompt: the next free ADR number and the highest spike on the
# architecture repository's main, never on whatever branch is checked out.
ag="$work/archgit"; mkdir -p "$ag/adr" "$ag/spikes"
git -C "$ag" init -q -b main
touch "$ag/adr/0001-a.md" "$ag/adr/0019-shared.md" "$ag/adr/README.md" "$ag/spikes/0094-y.md" "$ag/spikes/0121-x.md" "$ag/spikes/README.md"
git -C "$ag" add -A; git -C "$ag" -c user.name=t -c user.email=t@example.org -c commit.gpgsign=false commit -q -m x
git -C "$ag" checkout -q -b wip; touch "$ag/adr/0020-wip.md"; git -C "$ag" add -A
git -C "$ag" -c user.name=t -c user.email=t@example.org -c commit.gpgsign=false commit -q -m wip
facts=$(lh_draft_facts "$ag")
check "facts_name_the_next_free_adr_number" "$(grep -q 'next free ADR number is 0020' <<<"$facts"; echo $?)"
check "facts_name_the_highest_spike_and_how_spikes_are_numbered" "$(grep -q 'highest spike is 0121' <<<"$facts" && grep -q 'issue number' <<<"$facts"; echo $?)"
check "facts_come_from_main_not_the_checked_out_branch" "$(! grep -q '0021' <<<"$facts"; echo $?)"
check "facts_are_empty_without_an_architecture_repository" "$([[ -z "$(lh_draft_facts "$work/nowhere")" ]]; echo $?)"

# The shared memory (ADR-0019): recalled into the prompt at the public tier, whatever the environment says.
cat > "$work/bin/gh" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$STUB_DIR/gh.log"
case "$*" in
  *"view 77 "*) printf '# Retry limit\n\nthe retry limit is wrong\n' ;;
  *"--jq"*) printf '## Implementation brief\nexample\n' ;;
esac
SH
cat > "$work/bin/pgrep" <<'SH'
#!/usr/bin/env bash
exit 1
SH
printf 'implement-model:1\n' > "$work/srv/loaded"
printf '## Implementation brief\n### 1. Goal\nDo it.\n### 3. Properties and tests first\n- `a_test_that_fails`: it works.\n' > "$work/answer"
mem="$work/mem"
memenv=(LH_MEMORY_DIR="$mem" LH_MEMORY_BACKEND=jsonl LH_EMBED_HOST="$OLLAMA_HOST" LH_EMBED_MODEL=hash-test
        LH_MEMORY_ENV=/nonexistent LH_MEMORY_PYTHON=python3)
env "${memenv[@]}" LH_MEMORY_TIER=public python3 "$here/lh-memory.py" remember "public conclusion about the retry limit" --agent a --run r1 --issue 77 > /dev/null
env "${memenv[@]}" LH_MEMORY_TIER=private python3 "$here/lh-memory.py" remember "private secret about the retry limit" --agent a --run r2 > /dev/null

env "${memenv[@]}" LH_DRAFT_ROUNDS=0 bash "$here/lh-draft.sh" brief 77 > "$work/out" 2>&1; rc=$?
check "memory_hits_reach_the_drafting_prompt" "$([[ $rc -eq 0 ]] && grep -q 'public conclusion about the retry limit' "$work/claude.args"; echo $?)"
check "an_unverified_hit_is_marked_in_the_prompt" "$(grep -q 'UNVERIFIED' "$work/claude.args"; echo $?)"
check "the_prompt_says_a_hit_is_evidence_not_fact" "$(grep -q 'not fact' "$work/claude.args"; echo $?)"

env "${memenv[@]}" LH_MEMORY_TIER=private LH_DRAFT_ROUNDS=0 bash "$here/lh-draft.sh" brief 77 > "$work/out" 2>&1; rc=$?
check "a_drafting_run_recalls_at_the_public_tier_even_if_the_environment_says_private" "$([[ $rc -eq 0 ]] && ! grep -q 'private secret' "$work/claude.args"; echo $?)"

env "${memenv[@]}" LH_MEMORY_BACKEND=bogus LH_DRAFT_ROUNDS=0 bash "$here/lh-draft.sh" brief 77 > "$work/out" 2>&1; rc=$?
check "a_memory_that_cannot_be_read_does_not_stop_the_draft" "$([[ $rc -eq 0 ]] && grep -q 'could not be read' "$work/out"; echo $?)"

env "${memenv[@]}" LH_MEMORY_DIR="$work/none" LH_DRAFT_ROUNDS=0 bash "$here/lh-draft.sh" brief 77 > "$work/out" 2>&1; rc=$?
check "no_memory_set_up_means_no_memory_section" "$([[ $rc -eq 0 ]] && ! grep -q 'PROJECT MEMORY' "$work/claude.args"; echo $?)"

# A clone that is not on main is said so: its files may be someone's unmerged work.
git -C "$work/clone" symbolic-ref HEAD refs/heads/issue-132-work
printf '## Implementation brief\n### 1. Goal\nDo it.\n### 3. Properties and tests first\n- `a_test_that_fails`: it works.\n' > "$work/answer"
LH_DRAFT_ROUNDS=0 bash "$here/lh-draft.sh" brief 7 > "$work/out" 2>&1 || true
check "a_clone_off_main_is_warned_about" "$(grep -q 'is on issue-132-work, not main' "$work/out"; echo $?)"
git -C "$work/clone" symbolic-ref HEAD refs/heads/main
LH_DRAFT_ROUNDS=0 bash "$here/lh-draft.sh" brief 7 > "$work/out" 2>&1 || true
check "a_clone_on_main_is_not_warned_about" "$(! grep -q 'not main' "$work/out"; echo $?)"

ARCH_REPO_DIR="$work/archgit" LH_DRAFT_ROUNDS=0 LH_MEMORY_DIR="$work/none" bash "$here/lh-draft.sh" brief 77 > "$work/out" 2>&1; rc=$?
check "the_brief_prompt_carries_the_checked_facts" "$([[ $rc -eq 0 ]] && grep -q 'next free ADR number is 0020' "$work/claude.args" && grep -q 'never guess a number' "$work/claude.args"; echo $?)"

# The first pass of a brief has no tools, but a local model sometimes calls Read or Glob anyway, burns its
# turns on "No such tool" and ends with "Reached max turns" (#135, 2026-11-14). The prompt ends with a
# reminder, and a failed first pass is asked once more.
printf 'implement-model:1\n' > "$work/srv/loaded"
printf '## Implementation brief\n### 1. Goal\nDo it.\n### 3. Properties and tests first\n- `a_test_that_fails`: it works.\n' > "$work/answer"
: > "$work/claude.ncalls"
rc=0; LH_DRAFT_ROUNDS=0 bash "$here/lh-draft.sh" brief 77 > "$work/out" 2>&1 || rc=$?
check "the_brief_prompt_ends_with_the_no_tool_reminder" "$([[ $rc -eq 0 ]] && tr '\n' ' ' < "$work/claude.args" | grep -q "Answer with the brief only.*No tool exists in this session"; echo $?)"

printf 'implement-model:1\n' > "$work/srv/loaded"
: > "$work/claude.ncalls"; touch "$work/fail_once"; rm -f "$work/drafts/brief-77.md"
rc=0; LH_DRAFT_ROUNDS=0 bash "$here/lh-draft.sh" brief 77 > "$work/out" 2>&1 || rc=$?
check "a_first_pass_that_runs_out_of_turns_is_asked_once_more" "$([[ $rc -eq 0 && "$(grep -c CALL "$work/claude.ncalls")" -eq 2 ]] && grep -q 'asking once more' "$work/out" && tr '\n' ' ' < "$work/claude.args" | grep -q 'previous attempt called a tool'; echo $?)"
check "the_retry_produces_the_draft" "$([[ -f "$work/drafts/brief-77.md" && "$(head -1 "$work/drafts/brief-77.md")" == '## Implementation brief' ]]; echo $?)"

printf 'implement-model:1\n' > "$work/srv/loaded"
: > "$work/claude.ncalls"; touch "$work/fail_always"
rc=0; LH_DRAFT_ROUNDS=0 bash "$here/lh-draft.sh" brief 77 > "$work/out" 2>&1 || rc=$?
check "a_second_failure_ends_the_run_after_exactly_one_retry" "$([[ $rc -ne 0 && "$(grep -c CALL "$work/claude.ncalls")" -eq 2 ]] && grep -q 'the model run failed' "$work/out"; echo $?)"
rm -f "$work/fail_always"

echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
