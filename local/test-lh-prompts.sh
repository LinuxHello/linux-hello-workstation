#!/usr/bin/env bash
# Tests for the prompts in local/lh-prompts.sh; needs only bash.
#
#   local/test-lh-prompts.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=local/lh-prompts.sh
source "$here/lh-prompts.sh"

pass=0 fail=0
ok()  { pass=$((pass + 1)); echo "ok   $1"; }
nok() { fail=$((fail + 1)); echo "FAIL $1: $2"; }
check() { if [[ "$2" == *"$3"* ]]; then ok "$1"; else nok "$1" "prompt lacks: $3"; fi; }

brief=$'## Implementation brief\n\n**Goal:** merge layers.\n\n**Tests first:** `user_cannot_loosen_a_default`'
gates=$(for i in $(seq 1 100); do echo "gate line $i"; done; echo "Tests named in the brief are missing: user_cannot_loosen_a_default")

p=$(lh_implement_prompt "$brief")
check implement_prompt_carries_the_whole_brief "$p" "$brief"
check implement_prompt_states_the_rules "$p" "No unsafe code"

p=$(lh_repair_prompt "$brief" "$gates")
check repair_prompt_carries_the_whole_brief "$p" "$brief"
check repair_prompt_carries_the_gate_failure "$p" "Tests named in the brief are missing: user_cannot_loosen_a_default"
check repair_prompt_states_the_rules "$p" "No unsafe code"
# The gate output is 101 lines; the last 80 start at "gate line 22".
kept=$(grep '^gate line ' <<<"$p")
if [[ "$(head -1 <<<"$kept")" == "gate line 22" && "$(wc -l <<<"$kept")" -eq 79 ]]; then
  ok repair_prompt_keeps_only_the_last_80_gate_lines
else nok repair_prompt_keeps_only_the_last_80_gate_lines "kept from '$(head -1 <<<"$kept")', $(wc -l <<<"$kept") gate lines"; fi
if [[ "${p##*"$brief"}" == *"Gate output"* ]]; then
  ok repair_prompt_puts_the_gate_output_after_the_brief
else nok repair_prompt_puts_the_gate_output_after_the_brief "gate output precedes the brief"; fi

# Long lines and a long output are bounded: 80 lines of 5000 characters must not reach the prompt whole.
long=$(for i in $(seq 1 80); do printf 'x%.0s' $(seq 1 5000); echo; done)
p=$(lh_repair_prompt "$brief" "$long")
if [[ ${#p} -lt $((${#brief} + 14000)) ]]; then ok repair_prompt_bounds_long_gate_output
else nok repair_prompt_bounds_long_gate_output "prompt is ${#p} characters"; fi

echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
