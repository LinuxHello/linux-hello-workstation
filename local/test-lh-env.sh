#!/usr/bin/env bash
# Tests for local/lh-env.sh: the implementer's settings come from implementer.env, and anything the
# caller already set wins. Needs bash only.
#
#   local/test-lh-env.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
pass=0 fail=0
check() { # name, condition exit status
  if [[ "$2" == 0 ]]; then pass=$((pass + 1)); echo "ok   $1"; else fail=$((fail + 1)); echo "FAIL $1"; fi
}

cat > "$work/implementer.env" <<'ENV'
# A comment, and a line that is not a setting.
OLLAMA_MODEL=file-model:tag
LH_NUM_CTX=262144
LH_BUSY_CHECK=
not a setting
lower=ignored
ENV

# run <env assignments...> -- prints the three settings after loading the file
run() {
  env -i PATH="$PATH" "$@" bash -c 'source "$1"; lh_load_env "$2"; echo "${OLLAMA_MODEL-unset}|${LH_NUM_CTX-unset}|${LH_BUSY_CHECK-unset}|${lower-unset}"' _ "$here/lh-env.sh" "$work/implementer.env"
}

[[ "$(run)" == "file-model:tag|262144||unset" ]]; check "settings_come_from_the_file" $?
[[ "$(run OLLAMA_MODEL=caller:tag)" == "caller:tag|262144||unset" ]]; check "a_setting_the_caller_made_wins_over_the_file" $?
[[ "$(run LH_BUSY_CHECK=x)" == "file-model:tag|262144|x|unset" ]]; check "an_empty_setting_in_the_file_does_not_override_the_caller" $?
[[ "$(run LH_NUM_CTX=)" == "file-model:tag|||unset" ]]; check "a_setting_the_caller_set_empty_stays_empty" $?
env -i PATH="$PATH" bash -c 'source "$1"; lh_load_env /nonexistent && echo ok' _ "$here/lh-env.sh" | grep -qx ok; check "a_missing_file_is_not_an_error" $?
printf 'OLLAMA_MODEL=$(touch %s/pwned)\n' "$work" > "$work/evil.env"
env -i PATH="$PATH" bash -c 'source "$1"; lh_load_env "$2"; echo "$OLLAMA_MODEL"' _ "$here/lh-env.sh" "$work/evil.env" | grep -q 'touch'; check "a_value_is_data_not_a_command" $?
[[ ! -e "$work/pwned" ]]; check "no_command_in_the_file_is_run" $?

echo "$pass passed, $fail failed"
[[ "$fail" == 0 ]]
