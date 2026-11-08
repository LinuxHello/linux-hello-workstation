#!/usr/bin/env bash
# Tests for local/lh-model.sh against a stub model server and a stub pgrep; needs bash, python3, curl, jq.
#
#   local/test-lh-model.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
work=$(mktemp -d)
srv=""
trap '[[ -z "$srv" ]] || kill "$srv" 2>/dev/null || true; rm -rf "$work"' EXIT
pass=0 fail=0
check() { # name, condition exit status
  if [[ "$2" == 0 ]]; then pass=$((pass + 1)); echo "ok   $1"; else fail=$((fail + 1)); echo "FAIL $1"; fi
}

# A stub of the model server (local/stub-ollama.py).
python3 "$here/stub-ollama.py" "$work" & srv=$!
for _ in $(seq 50); do [[ -s "$work/port" ]] && break; sleep 0.1; done
export OLLAMA_HOST="http://127.0.0.1:$(cat "$work/port")"

# A stub pgrep: succeeds when $work/session names the model in the pattern.
mkdir -p "$work/bin"
cat > "$work/bin/pgrep" <<'SH'
#!/usr/bin/env bash
[[ -f "$STUB_SESSION" ]] && grep -qF -- "$(cat "$STUB_SESSION")" <<<"${*: -1}"
SH
chmod +x "$work/bin/pgrep"
export PATH="$work/bin:$PATH" STUB_SESSION="$work/session"

# shellcheck source=local/lh-model.sh
source "$here/lh-model.sh"
loaded() { tr '\n' ' ' < "$work/loaded" | sed 's/ *$//'; }

printf 'big\n' > "$work/loaded"
lh_model_acquire small 2>/dev/null
check "acquire_unloads_the_other_model_and_loads_the_wanted_one" "$([[ "$(loaded)" == small ]]; echo $?)"
lh_model_release 2>/dev/null
check "release_unloads_what_acquire_loaded" "$([[ -z "$(loaded)" ]]; echo $?)"

printf 'small\n' > "$work/loaded"
lh_model_acquire small 2>/dev/null; lh_model_release 2>/dev/null
check "release_keeps_a_model_that_was_already_loaded" "$([[ "$(loaded)" == small ]]; echo $?)"

printf 'big\n' > "$work/loaded"; echo big > "$work/session"
rc=0; lh_model_acquire small 2>"$work/err" || rc=$?
check "acquire_refuses_to_evict_a_model_an_interactive_session_uses" "$([[ $rc -ne 0 && "$(loaded)" == big ]]; echo $?)"
check "the_refusal_names_the_model_and_the_override" "$(grep -q "big.*LH_EVICT=1" "$work/err"; echo $?)"
rc=0; LH_EVICT=1 lh_model_acquire small 2>/dev/null || rc=$?
check "lh_evict_unloads_it_anyway" "$([[ $rc -eq 0 && "$(loaded)" == small ]]; echo $?)"
lh_model_release 2>/dev/null; rm -f "$work/session"

rc=0; OLLAMA_HOST=http://example.com:11434 bash -c "source $here/lh-model.sh; lh_model_post '{}'" 2>/dev/null || rc=$?
check "a_non_loopback_host_is_refused_for_loading" "$([[ $rc -ne 0 ]]; echo $?)"

rc=0; [[ "$(env -u OLLAMA_HOST bash -c "source $here/lh-model.sh; bash -c 'echo \$OLLAMA_HOST'")" == http://127.0.0.1:11434 ]] || rc=$?
check "the_default_host_reaches_child_processes" $rc
rc=0; ( LH_MODELS_ENV=/nonexistent; lh_role implement; [[ "$OLLAMA_MODEL" == gemma4-26b-64k:latest && "$LH_NUM_CTX" == 65536 ]] ) || rc=$?; check "implement_role_defaults" $rc
rc=0; ( LH_MODELS_ENV=/nonexistent; lh_role draft; [[ "$OLLAMA_MODEL" == qwen38-27b-text-32k:latest && "$LH_NUM_CTX" == 32768 ]] ) || rc=$?; check "draft_role_defaults" $rc
printf 'LH_MODEL_DRAFT=other:1\nLH_CTX_DRAFT=8192\n' > "$work/models.env"
rc=0; ( LH_MODELS_ENV="$work/models.env"; lh_role draft; [[ "$OLLAMA_MODEL" == other:1 && "$LH_NUM_CTX" == 8192 ]] ) || rc=$?; check "the_models_file_overrides_the_defaults" $rc
rc=0; ( lh_role bogus 2>/dev/null ) || rc=$?
check "an_unknown_role_is_refused" "$([[ $rc -ne 0 ]]; echo $?)"

echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
