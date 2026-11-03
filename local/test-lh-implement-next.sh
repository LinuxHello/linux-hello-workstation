#!/usr/bin/env bash
# Tests for lh-implement-next.sh with fake gh, curl, implementer and reset. Needs bash, jq,
# flock and timeout; never calls GitHub or a model server.
#
#   local/test-lh-implement-next.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
loop="$here/lh-implement-next.sh"
for c in jq flock timeout; do command -v "$c" >/dev/null || { echo "$c not installed" >&2; exit 1; }; done

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"

# gh: answers from $FIX (issue list, issue view <n>), records edits and comments in $CALLS.
cat >"$work/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "gh $*" >>"$CALLS"
[[ "$1" == auth ]] && exit 0
jqf=""; args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do [[ "${args[i]}" == --jq ]] && jqf="${args[i+1]}"; done
case "$1 $2" in
  "issue list") jq -r "$jqf" "$FIX/list.json" ;;
  "issue view") jq -r "$jqf" "$FIX/issue-$3.json" ;;
  "issue comment") cat >"$FIX/comment-$3.md" ;;
  "issue edit") ;;
  *) echo "unexpected gh $*" >&2; exit 1 ;;
esac
EOF
# curl: the model server's loaded models.
cat >"$work/bin/curl" <<'EOF'
#!/usr/bin/env bash
cat "$FIX/ps.json"
EOF
# Implementer: records its issue and environment, prints machine details, exits $IMPL_RC.
cat >"$work/bin/fake-implement" <<'EOF'
#!/usr/bin/env bash
echo "implement $1 unattended=$LH_UNATTENDED" >>"$CALLS"
echo "error in $CLONE_DIR/crates/x.rs on $OLLAMA_MODEL at $OLLAMA_HOST in $HOME"
exit "${IMPL_RC:-0}"
EOF
cat >"$work/bin/fake-reset" <<'EOF'
#!/usr/bin/env bash
echo "reset $*" >>"$CALLS"
EOF
chmod +x "$work/bin/"*

pass=0 fail=0 out="" status=0
FIX="" CALLS="" STATE=""
new_case() {
  FIX="$work/$1"; CALLS="$FIX/calls"; STATE="$FIX/state"; mkdir -p "$FIX"; : >"$CALLS"
  echo '{"models":[]}' >"$FIX/ps.json"
  echo '[]' >"$FIX/list.json"
  cat >"$FIX/env" <<EOF
OLLAMA_MODEL=fake-model:1b
LH_BG_MODEL=fake-small:1b
CLONE_DIR=$FIX/clone
LH_UNATTENDED=0
EOF
}
issue() { # number created-at has-brief
  local body="Some issue."; [[ "$3" == yes ]] && body=$'Text\n## Implementation brief\nGoal: x'
  jq -n --arg b "$body" '{body: $b, comments: []}' >"$FIX/issue-$1.json"
  jq --argjson n "$1" --arg c "$2" '. + [{number: $n, createdAt: $c}]' "$FIX/list.json" >"$FIX/l" && mv "$FIX/l" "$FIX/list.json"
}
run() {
  status=0
  export FIX CALLS
  out="$(PATH="$work/bin:$PATH" LH_ENV_FILE="$FIX/env" LH_STATE_DIR="$STATE" \
         LH_IMPLEMENT="$work/bin/fake-implement" LH_RESET="$work/bin/fake-reset" "$@" "$loop" 2>&1)" || status=$?
}
ok()  { pass=$((pass + 1)); echo "ok   $1"; }
nok() { fail=$((fail + 1)); echo "FAIL $1: $2"; echo "     ${out//$'\n'/$'\n'     }"; }
implemented() { grep '^implement' "$CALLS" || true; }

# ---------------------------------------------------------------------------
t=oldest_ready_issue_with_a_brief_is_implemented_unattended
new_case "$t"
issue 12 2026-11-02T00:00:00Z no
issue 15 2026-11-03T00:00:00Z yes
issue 14 2026-11-01T00:00:00Z yes
run
if [[ $status == 0 && "$(implemented)" == "implement 14 unattended=1" ]] && grep -q '^reset -y --main' "$CALLS"
then ok "$t"; else nok "$t" "status $status, $(implemented)"; fi

t=gpu_busy_with_another_model_claims_nothing
new_case "$t"
issue 14 2026-11-01T00:00:00Z yes
echo '{"models":[{"name":"fake-model:1b"},{"name":"someone-else:7b"}]}' >"$FIX/ps.json"
run
if [[ $status == 0 && -z "$(implemented)" ]] && ! grep -q 'issue list' "$CALLS"; then ok "$t"; else nok "$t" "status $status"; fi

t=own_models_loaded_do_not_count_as_busy
new_case "$t"
issue 14 2026-11-01T00:00:00Z yes
echo '{"models":[{"name":"fake-model:1b"},{"name":"fake-small:1b"}]}' >"$FIX/ps.json"
run
if [[ $status == 0 && "$(implemented)" == "implement 14 unattended=1" ]]; then ok "$t"; else nok "$t" "status $status"; fi

t=busy_check_hook_claims_nothing
new_case "$t"
issue 14 2026-11-01T00:00:00Z yes
echo 'LH_BUSY_CHECK=true' >>"$FIX/env"
run
if [[ $status == 0 && -z "$(implemented)" ]]; then ok "$t"; else nok "$t" "status $status"; fi

t=no_ready_issue_with_a_brief_exits_cleanly
new_case "$t"
issue 12 2026-11-02T00:00:00Z no
run
if [[ $status == 0 && -z "$(implemented)" ]] && ! grep -q '^reset' "$CALLS"; then ok "$t"; else nok "$t" "status $status"; fi

t=concurrent_run_exits_without_claiming
new_case "$t"
issue 14 2026-11-01T00:00:00Z yes
mkdir -p "$STATE"
exec 8>"$STATE/lock"; flock -n 8
run
exec 8>&-
if [[ $status == 0 && -z "$(implemented)" ]]; then ok "$t"; else nok "$t" "status $status"; fi

t=failure_below_the_limit_returns_issue_to_ready
new_case "$t"
issue 14 2026-11-01T00:00:00Z yes
IMPL_RC=1 run
if [[ $status != 0 && "$(cat "$STATE/attempts/14")" == 1 ]] \
   && grep -q 'issue edit 14 .*--add-label status:ready --remove-label status:in-progress' "$CALLS" \
   && ! grep -q 'status:blocked' "$CALLS"; then ok "$t"; else nok "$t" "status $status, $(cat "$CALLS")"; fi

t=last_allowed_failure_blocks_issue_with_a_scrubbed_log
new_case "$t"
issue 14 2026-11-01T00:00:00Z yes
mkdir -p "$STATE/attempts"; echo 2 >"$STATE/attempts/14"
IMPL_RC=1 run
comment="$(cat "$FIX/comment-14.md" 2>/dev/null || true)"
if [[ $status != 0 ]] && grep -q 'issue edit 14 .*--add-label status:blocked --remove-label status:ready' "$CALLS" \
   && grep -q '<clone>/crates/x.rs on <model> at <model-server>' <<<"$comment" \
   && ! grep -qF -e "$FIX" -e fake-model -e "$HOME" <<<"$comment" && [[ ! -e "$STATE/attempts/14" ]]
then ok "$t"; else nok "$t" "status $status, comment: $comment"; fi

t=success_clears_the_attempt_count
new_case "$t"
issue 14 2026-11-01T00:00:00Z yes
mkdir -p "$STATE/attempts"; echo 2 >"$STATE/attempts/14"
run
if [[ $status == 0 && ! -e "$STATE/attempts/14" ]]; then ok "$t"; else nok "$t" "status $status"; fi

t=timeout_counts_as_a_failure
new_case "$t"
issue 14 2026-11-01T00:00:00Z yes
echo 'LH_RUN_TIMEOUT=1s' >>"$FIX/env"
cat >"$FIX/slow" <<'EOF'
#!/usr/bin/env bash
sleep 30
EOF
chmod +x "$FIX/slow"
run env LH_IMPLEMENT="$FIX/slow"
if [[ $status != 0 && "$(cat "$STATE/attempts/14" 2>/dev/null)" == 1 ]]; then ok "$t"; else nok "$t" "status $status"; fi

echo "$pass passed, $fail failed"
((fail == 0))
