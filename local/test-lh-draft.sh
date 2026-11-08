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
python3 "$here/stub-ollama.py" "$work/srv" qwen38-27b-text-32k:latest gemma4-26b-64k:latest & srv=$!
for _ in $(seq 50); do [[ -s "$work/srv/port" ]] && break; sleep 0.1; done
export OLLAMA_HOST="http://127.0.0.1:$(cat "$work/srv/port")"

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
echo "token=${GH_TOKEN:-unset}" > "$STUB_DIR/claude.env"
cp "$STUB_DIR/srv/loaded" "$STUB_DIR/loaded.during"
cat "$STUB_DIR/answer"
SH
cat > "$work/bin/pgrep" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x "$work"/bin/*
export PATH="$work/bin:$PATH" STUB_DIR="$work" CLONE_DIR="$work/clone" ARCH_REPO_DIR="$work/arch" \
  LH_DRAFT_DIR="$work/drafts" LH_MODELS_ENV=/nonexistent GH_TOKEN=secret

printf 'gemma4-26b-64k:latest\n' > "$work/srv/loaded"
printf 'Sure, here is the brief.\n## Implementation brief\n### 1. Goal\nDo it.\n### 3. Properties and tests first\n- `a_test_that_fails`: it works.\n' > "$work/answer"
bash "$here/lh-draft.sh" brief 7 > "$work/out" 2>&1; rc=$?
check "a_brief_draft_is_written" "$([[ $rc -eq 0 && -f "$work/drafts/brief-7.md" ]]; echo $?)"
check "preamble_before_the_heading_is_dropped" "$([[ "$(head -1 "$work/drafts/brief-7.md")" == "## Implementation brief" ]]; echo $?)"
check "the_draft_model_was_the_only_one_loaded_during_the_run" "$([[ "$(tr -d '\n' < "$work/loaded.during")" == qwen38-27b-text-32k:latest ]]; echo $?)"
check "the_draft_model_is_unloaded_afterwards" "$([[ -z "$(tr -d '\n ' < "$work/srv/loaded")" ]]; echo $?)"
check "the_model_can_only_read" "$(grep -q 'allowedTools Read Grep Glob' "$work/claude.args"; echo $?)"
check "the_model_gets_no_github_token" "$([[ "$(cat "$work/claude.env")" == token=unset ]]; echo $?)"
check "nothing_is_posted_to_github" "$(! grep -Eq 'issue (comment|edit|create|close)|pr ' "$work/gh.log"; echo $?)"
check "test_names_are_counted_for_the_implementer_gate" "$(grep -q '1 test name' "$work/out"; echo $?)"

printf 'I could not do it.\n' > "$work/answer"
rc=0; bash "$here/lh-draft.sh" brief 8 > "$work/out" 2>&1 || rc=$?
check "an_answer_without_the_brief_heading_is_rejected" "$([[ $rc -ne 0 && ! -f "$work/drafts/brief-8.md" && -f "$work/drafts/brief-8.md.rejected" ]]; echo $?)"

printf 'Here you go:\n---\ntype: adr\n---\n# ADR-0019: Platforms\n' > "$work/answer"
rc=0; bash "$here/lh-draft.sh" adr "Supported platforms" "AppArmor only" > "$work/out" 2>&1 || rc=$?
check "an_adr_draft_starts_at_its_frontmatter" "$([[ $rc -eq 0 && "$(head -1 "$work/drafts/adr-supported-platforms.md")" == --- ]]; echo $?)"

printf 'qwen38-27b-text-32k:latest\n' > "$work/srv/loaded"
cat > "$work/bin/pgrep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
printf 'gemma4-26b-64k:latest\n' > "$work/srv/loaded"
rc=0; bash "$here/lh-draft.sh" brief 9 > "$work/out" 2>&1 || rc=$?
check "a_model_in_use_by_a_session_is_not_evicted" "$([[ $rc -ne 0 ]] && grep -q 'interactive session' "$work/out"; echo $?)"

echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
