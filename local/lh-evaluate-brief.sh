#!/usr/bin/env bash
# Has Claude check an implementation brief against the issue and the code. Workstation-only.
#
#   lh-evaluate-brief.sh <issue> <brief file> [findings file]
#
# Prints the verdict as one line of JSON (see lh-verdict.py) and exits 0; exits 3 when there is no
# usable verdict (Claude failed, timed out or did not answer with a verdict), in which case the
# caller publishes nothing.
#
# This is the one place where the workstation tooling uses the maintainer's own Claude login instead
# of a local model: a reviewer of the same kind as the model that wrote the draft misses the same
# mistakes. What is sent is public: the issue, the draft brief and the code of the public repository
# at origin/main (a read-only snapshot made with git archive, so neither the working clone nor an
# implementer's edits are read or touched). Claude gets Read, Grep and Glob only, no GitHub token, and
# none of the local-model settings the drafting uses.
#
# Settings: LH_EVAL_MODEL (default: the account's), LH_EVAL_TURNS (40), LH_EVAL_TIMEOUT (900 s),
# LH_EVAL_CLAUDE (claude), CLONE_DIR, REPO_SLUG, ARCH_REPO_DIR.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
: "${CLONE_DIR:=$HOME/projects/LinuxHello/linux-hello}"
: "${REPO_SLUG:=LinuxHello/linux-hello}"
n=${1:?usage: lh-evaluate-brief.sh <issue> <brief file> [findings file]}
brief_file=${2:?usage: lh-evaluate-brief.sh <issue> <brief file> [findings file]}
findings_file=${3:-}
fail() { printf 'evaluator: %s\n' "$*" >&2; exit 3; }

# shellcheck source=local/lh-context.sh
source "$HERE/lh-context.sh"
snap=$(mktemp -d)
trap 'rm -rf "$snap"' EXIT
git -C "$CLONE_DIR" archive origin/main | tar -x -C "$snap" || fail "cannot make a snapshot of origin/main in $CLONE_DIR"

issue=$(gh issue view "$n" --repo "$REPO_SLUG" --json title,body --jq '"# " + .title + "\n\n" + .body') || fail "cannot read issue #$n"
brief=$(<"$brief_file")
findings=""; [[ -z "$findings_file" || ! -s "$findings_file" ]] || findings=$(<"$findings_file")
facts=$(lh_draft_facts "${ARCH_REPO_DIR:-}" || true)

prompt="You review an implementation brief for the open-source project Linux Hello. A weaker local model will implement the brief, and a person who is not a specialist in this code decides what goes ahead. Be exact, and write plainly.

THE ISSUE:
$issue

THE BRIEF (a draft written by a local model):
$brief

RESULTS OF AUTOMATIC CHECKS ON THE DRAFT (some are false alarms, for example an instruction to stop and report counted as a hedge, or a name the brief introduces counted as missing: decide each one yourself):
${findings:-(none)}

FACTS COLLECTED BY THE TOOLS:
${facts:-(none)}

WHAT TO CHECK. The code of the main branch is in the current directory. Use Read, Grep and Glob. Do not trust the brief: verify each claim yourself. AGENTS.md, section 'The brief', says what a brief must contain.
1. Scope: does the brief do what the issue asks, no more and no less? Is part of it already implemented on main? Does it depend on something that does not exist yet?
2. Every file, function, type, field and test the brief cites as existing: does it exist, with the signature and visibility the brief says? A private item cannot be used from another crate or from a test in a tests/ directory.
3. Every name the brief introduces is marked new. ADR and spike numbers are real (see the facts).
4. Code and configuration examples in the brief: would they parse or compile, with every required key?
5. Tests: the tests listed under 'Properties and tests first' are new tests. An existing test named there is an error. The brief must not ask to rename, remove or move an existing test. Each test must be able to fail.
6. Files: one to five, each a bullet that starts with its path. Rewriting a file of more than about 400 lines does not fit the implementer's reply limit; a short edit to it is fine.
7. The implementer is a small local model. Briefs that only edit existing files have worked. Briefs that create new files have failed every time so far. Say whether this brief creates new files.
8. Contradictions inside the brief (files, scope, tests, counts), choices left to the implementer, and anything private (host names, home paths, hardware, local model names) in a public project.
9. A rule or invariant the brief quotes must match AGENTS.md or the code.

HOW TO ANSWER. Reply with one JSON object and nothing else:
{\"verdict\": \"ok\" or \"problems\",
 \"summary\": \"one plain sentence: what the brief is for\",
 \"checked\": [\"short plain statements of what you verified and found fine\"],
 \"problems\": [{\"id\": \"P1\", \"what\": \"what is wrong, in plain words\", \"why\": \"one sentence: what goes wrong if it is not fixed\", \"fix\": \"what to change in the brief\", \"who\": \"ai\" or \"maintainer\", \"question\": \"only when who is maintainer: the direction question in plain words\", \"options\": [\"A. ...\", \"B. ...\"], \"recommendation\": \"A\", \"blocking\": true or false}],
 \"new_files\": true or false}
Rules for the answer:
- The reader is a senior infrastructure architect with no time for the details of this code. Write short plain sentences. Avoid names of functions, files and types unless the reader must act on them.
- who is maintainer only for a real choice of direction: architecture, a security trade-off, what the project should do. A wrong name, a missing key, a test that is not new or a file that is too long is ai: it is yours to fix.
- A problem blocks (blocking true) when the implementer would fail or build the wrong thing. Use blocking false for wording that does not change what is built.
- Say verdict ok only if there is no blocking problem. If the automatic checks reported something that is a false alarm, do not list it."

raw=$(cd "$snap" && env -u GH_TOKEN -u GITHUB_TOKEN -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN -u ANTHROPIC_BASE_URL \
        -u CLAUDE_CODE_USE_BEDROCK -u CLAUDE_CODE_USE_VERTEX -u CLAUDE_CODE_USE_FOUNDRY -u CLAUDE_CONFIG_DIR -u OLLAMA_HOST \
        timeout "${LH_EVAL_TIMEOUT:-900}" "${LH_EVAL_CLAUDE:-claude}" -p "$prompt" \
        --tools "Read,Grep,Glob" --allowedTools "Read Grep Glob" --max-turns "${LH_EVAL_TURNS:-40}" \
        ${LH_EVAL_MODEL:+--model "$LH_EVAL_MODEL"} </dev/null) || fail "claude did not finish (exit $?)"

printf '%s' "$raw" | python3 "$HERE/lh-verdict.py" || fail "the answer was not a verdict"
