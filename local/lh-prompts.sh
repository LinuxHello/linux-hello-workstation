# shellcheck shell=bash
# Prompts lh-implement.sh gives the model; sourced, not run. Tested by local/test-lh-prompts.sh.
#
#   lh_implement_prompt <brief>               round 1
#   lh_repair_prompt <brief> <gate-output>    every repair round
#
# Each round starts a new harness session that remembers nothing of the round before, so every
# prompt carries the whole brief. A repair prompt without it leaves the model to guess the task
# from test names (seen on #38, Aider, 2026-11-04). The gate output comes last, trimmed to its
# last 80 lines, each cut to 300 characters and the whole to 12000, so it is the freshest text in
# the model's context and cannot fill it (prompts reached 65,462 of 65,536 tokens, 2026-11-06).

LH_RULES="Edit only the files you were given. Follow AGENTS.md (read-only). No unsafe code, no unwrap() or expect() outside tests, no new dependencies beyond those the brief names."

lh_implement_prompt() {
  printf '%s\n\n%s\n' \
    "You are the implementer for Linux Hello. Implement exactly this brief. Write the brief's tests first, then the code. $LH_RULES" \
    "$1"
}

lh_repair_prompt() {
  printf '%s\n\n%s\n\n%s\n%s\n' \
    "You are the implementer for Linux Hello, implementing the brief below. Your earlier edits are already in the files; the gates then failed. Fix the cause so the brief is met, including every test it names. Do not weaken tests, lints or checks. $LH_RULES" \
    "$1" \
    "Gate output (last 80 lines):" \
    "$(printf '%s\n' "$2" | tail -80 | cut -c1-300 | tail -c 12000)"
}
