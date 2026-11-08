#!/usr/bin/env bash
# Implementer step of the agent loop (ADR-0004, ADR-0007): a local model implements one issue from
# its brief, through Aider or Claude Code. Workstation-only. UNTESTED against a live model.
#
#   lh-implement.sh <issue>
#
# Environment (defaults below; lh-implement-next.sh reads them from implementer.env):
#   LH_HARNESS      aider | claude            which harness drives the model
#   OLLAMA_MODEL    model the harness uses    LH_NUM_CTX  context window Ollama serves it with
#   LH_BG_MODEL     Claude Code's background-call model (default: OLLAMA_MODEL)
#   LH_MAX_TURNS    Claude Code turn limit per round
#   LH_MAX_OUTPUT   Claude Code's cap on one reply, in tokens (default 12000). Claude Code compacts
#                   at LH_NUM_CTX - min(LH_MAX_OUTPUT, 20000) - 13000: at its default reserve of 20000
#                   a 64k window compacted at 32.5k, which left the model about 15k tokens to work in
#                   and thrashed on #38. 12000 moves it to 40.5k; the largest reply on #38 was 7k.
#   LH_THINK        0 = the model does not think (default), in both harnesses; 1 = Ollama's default.
#                   Thinking took 20-40k tokens per reply on #38 and overflowed a 64k window in both.
#                   Aider: think: false. Claude Code cannot switch it off, so it talks to Ollama
#                   through local/lh-nothink-relay.py, which sets thinking to disabled.
#   LH_AIDER_EDIT_FORMAT  whole (default) | diff: how Aider applies the model's edits. In diff
#                   format a block with an empty SEARCH creates a file, and on an existing file
#                   Aider appends it: query.rs, view.rs, merge.rs and restrict.rs each ended up
#                   holding copies of themselves (#40, #85, #62, #61). In whole format every reply
#                   replaces the file, so nothing is appended; replies are larger.
#   LH_MAX_FILES_BYTES  refuse a brief whose edited files total more than this (default 100000,
#                   about 30k tokens): Aider sends them whole on every request.
#   LH_READ_MAX_BYTES / LH_READ_MAX_FILES  read-only files Aider gets beyond AGENTS.md: each at most
#                   this size (default 8000) and at most this many (default 2). The old 20000 x 3
#                   could be 20k tokens of a 64k window. Prompts reached 65,462 of 65,536 tokens
#                   (Ollama journal, 2026-11-06).
#   LH_UNATTENDED   1 = nobody reviews before commit: no Signed-off-by, no signing requirement (ADR-0007)
#   LH_BRANCH       branch to work on and push (default issue-<n>); the harness trials run each
#                   brief twice, e.g. LH_BRANCH=issue-53-aider and LH_BRANCH=issue-53-claude
#
# The model only edits code. This script does everything else deterministically:
#   1. reads the issue's "## Implementation brief" and the files it lists;
#   2. runs Aider on exactly those files (plus AGENTS.md and any repo file the brief names, read-only),
#      with cargo test after each edit;
#   3. runs the gates, giving the model up to two more rounds with the failure output;
#   4. refuses changes outside the brief's files;
#   5. commits (signed and signed-off when attended; neither when LH_UNATTENDED=1), pushes branch
#      issue-<n> (or LH_BRANCH), opens a draft PR.
# The model's process gets no GitHub or git credential.
set -euo pipefail
: "${CLONE_DIR:=$HOME/projects/LinuxHello/linux-hello}"
: "${REPO_SLUG:=LinuxHello/linux-hello}"
: "${OLLAMA_HOST:=http://127.0.0.1:11434}"
: "${OLLAMA_MODEL:=gemma4-26b-64k:latest}"
: "${FIX_ROUNDS:=2}"
: "${LH_HARNESS:=aider}"
: "${LH_NUM_CTX:=65536}"
: "${LH_BG_MODEL:=$OLLAMA_MODEL}"
: "${LH_MAX_TURNS:=60}"
: "${LH_MAX_OUTPUT:=12000}"
: "${LH_UNATTENDED:=0}"
: "${LH_THINK:=0}"
: "${LH_AIDER_EDIT_FORMAT:=whole}"
: "${LH_MAX_FILES_BYTES:=100000}"
: "${LH_READ_MAX_BYTES:=8000}"
: "${LH_READ_MAX_FILES:=2}"
HERE="$(cd "$(dirname "$0")" && pwd)"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/linux-hello-aider"
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '\033[1m==> %s\033[0m\n' "$*"; }

num=${1:-}; [[ "$num" =~ ^[0-9]+$ ]] || die "usage: $0 <issue>"
: "${LH_BRANCH:=issue-$num}"
[[ "$LH_BRANCH" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ && "$LH_BRANCH" != main ]] || die "LH_BRANCH must be a plain branch name other than main, got '$LH_BRANCH'"
[[ -d "$HOME/.cargo/bin" ]] && PATH="$HOME/.cargo/bin:$PATH"
[[ -d "$HOME/.local/bin" ]] && PATH="$HOME/.local/bin:$PATH"
case "$LH_HARNESS" in aider|claude) ;; *) die "LH_HARNESS must be aider or claude, got '$LH_HARNESS'" ;; esac
[[ "$LH_NUM_CTX" =~ ^[0-9]+$ && "$LH_MAX_TURNS" =~ ^[0-9]+$ && "$LH_MAX_OUTPUT" =~ ^[0-9]+$ ]] \
  || die "LH_NUM_CTX, LH_MAX_TURNS and LH_MAX_OUTPUT must be numbers"
[[ "$LH_UNATTENDED" == 0 || "$LH_UNATTENDED" == 1 ]] || die "LH_UNATTENDED must be 0 or 1"
[[ "$LH_THINK" == 0 || "$LH_THINK" == 1 ]] || die "LH_THINK must be 0 or 1"
[[ "$LH_AIDER_EDIT_FORMAT" == whole || "$LH_AIDER_EDIT_FORMAT" == diff ]] \
  || die "LH_AIDER_EDIT_FORMAT must be whole or diff, got '$LH_AIDER_EDIT_FORMAT'"
harness_cmd=aider; [[ "$LH_HARNESS" == claude ]] && harness_cmd=claude
for c in "$harness_cmd" gh git jq python3 cargo curl; do command -v "$c" >/dev/null || die "$c not installed (aider: bash $HERE/install-aider.sh)"; done
gh auth status >/dev/null 2>&1 || die "gh not authenticated"
[[ "$OLLAMA_HOST" =~ ^http://(127\.0\.0\.1|localhost):[0-9]+$ ]] || die "OLLAMA_HOST must be loopback, got '$OLLAMA_HOST'"
for m in "$OLLAMA_MODEL" "$LH_BG_MODEL"; do
  curl -fsS --max-time 5 "$OLLAMA_HOST/api/tags" | jq -e --arg m "$m" '.models[] | select(.name == $m or .model == $m)' >/dev/null \
    || die "model '$m' not available on $OLLAMA_HOST"
done
cd "$CLONE_DIR"
if [[ "$LH_UNATTENDED" == 0 ]]; then
  [[ "$(git config --get commit.gpgsign || true)" == "true" ]] || die "commit signing is not enabled in $CLONE_DIR"
fi
[[ -z "$(git status --porcelain)" ]] || die "working tree not clean in $CLONE_DIR (clean it, keeping a copy: bash $HERE/lh-reset.sh)"
mkdir -p "$CACHE"
grep -qxF '.aider*' .git/info/exclude 2>/dev/null || echo '.aider*' >> .git/info/exclude   # local only, never committed

# 1. Brief, title and file lists.
issue_json=$(gh issue view "$num" --repo "$REPO_SLUG" --json title,body,comments)
title=$(jq -r .title <<<"$issue_json")
brief=$(jq -r '[.body] + [.comments[].body] | map(select(test("(?m)^## Implementation brief"))) | last // empty' <<<"$issue_json")
[[ -n "$brief" ]] || die "issue #$num has no '## Implementation brief'"
brief=$(python3 -c 'import sys; t=sys.stdin.read(); print(t[t.index("## Implementation brief"):])' <<<"$brief")
# The file list sits under "**Files:**" or a "### N. Files" heading and runs to the next heading.
# Directories (a submodule pointer) are not editable files: see pins below.
mapfile -t files < <(python3 - "$brief" <<'PY'
import os, re, sys
text = sys.argv[1]
m = re.search(r"(?:\*\*Files:\*\*|^#{2,}[ \t]*(?:\d+\.[ \t]*)?Files[ \t]*$)(.*?)(?=^#{1,6}[ \t]|\n\*\*[A-Z]|\Z)", text, re.S | re.M)
seen = []
section = m.group(1) if m else ""
ext = r"`([A-Za-z0-9_./-]+\.(?:rs|toml|md|txt|yml|yaml|json|sh))`"
# A file is a list item that starts with its path; prose such as "never edit `x.yml`" is not a file.
# Briefs with no such list items fall back to every quoted path in the section.
found = [mm.group(1) for line in section.splitlines() if (mm := re.match(r"\s*[-*]\s+" + ext, line))]
if not found:
    found = re.findall(ext, section)
for p in found:
    if ("/" in p or p.endswith(".toml")) and not os.path.isdir(p) and p not in seen: seen.append(p)
if seen: print("\n".join(seen))
PY
)
# Submodule pins the brief asks to bump: "`<submodule>` (the submodule pointer): bump it to `<sha>`".
mapfile -t pins < <(python3 - "$brief" <<'PY'
import re, subprocess, sys
mods = set(re.findall(r"^\s*path = (.+)$", open(".gitmodules").read(), re.M)) if __import__("os").path.exists(".gitmodules") else set()
for path, sha in re.findall(r"`([A-Za-z0-9_./-]+)`[^\n`]*submodule pointer[^\n]*?`([0-9a-f]{40})`", sys.argv[1]):
    if path in mods: print(path, sha)
PY
)
[[ ${#files[@]} -gt 0 && ${#files[@]} -le 5 ]] || die "brief must list 1-5 files under **Files:** or a 'Files' heading, found ${#files[@]}"
files_bytes=0
for f in "${files[@]}"; do [[ -f "$f" ]] && files_bytes=$((files_bytes + $(stat -c %s "$f"))); done
[[ $files_bytes -le $LH_MAX_FILES_BYTES ]] \
  || die "the brief's files total $files_bytes bytes (limit $LH_MAX_FILES_BYTES, LH_MAX_FILES_BYTES): they do not fit a $LH_NUM_CTX-token window beside the prompt; split the brief"
mapfile -t reads < <(LH_READ_MAX_BYTES="$LH_READ_MAX_BYTES" LH_READ_MAX_FILES="$LH_READ_MAX_FILES" python3 - "$brief" <<'PY'
import os, re, sys
limit, count = int(os.environ["LH_READ_MAX_BYTES"]), int(os.environ["LH_READ_MAX_FILES"])
out = []
for p in re.findall(r"(?:\.\./)*([a-z0-9_-]+(?:/[A-Za-z0-9_.-]+)+\.(?:rs|toml|md))", sys.argv[1]):
    if os.path.isfile(p) and os.path.getsize(p) < limit and p not in out: out.append(p)
print("\n".join(out[:count]))
PY
)
log "issue #$num: $title"
log "files: ${files[*]}"

# 2. Branch.
git fetch -q origin main
# shellcheck source=local/lh-branch.sh
source "$HERE/lh-branch.sh"
lh_select_branch "$LH_BRANCH" origin/main || die "not starting issue #$num on a stale branch"
# A branch already ahead of main holds a finished run (it is committed and pushed only after the
# gates pass). Stop before touching labels or files: re-running would find nothing to change and
# put status:ready back on an issue that is in review.
ahead=$(git rev-list --count "origin/main..$LH_BRANCH")
[[ "$ahead" -eq 0 ]] || die "branch $LH_BRANCH already has $ahead commit(s) ahead of main: this issue was implemented. Review it (gh pr list --repo $REPO_SLUG --head $LH_BRANCH), or delete the branch to start over (git -C $CLONE_DIR branch -D $LH_BRANCH). Nothing changed."
for pin in "${pins[@]}"; do
  read -r pin_path pin_sha <<<"$pin"
  git submodule update --init -- "$pin_path" && git -C "$pin_path" fetch -q origin \
    && git -C "$pin_path" checkout -q "$pin_sha" && git add -- "$pin_path" || die "could not bump $pin_path to $pin_sha"
  log "pin: $pin_path -> $pin_sha"
done
gh issue edit "$num" --repo "$REPO_SLUG" --add-label status:in-progress --remove-label status:ready >/dev/null 2>&1 || true
fail() {
  gh issue edit "$num" --repo "$REPO_SLUG" --add-label status:ready --remove-label status:in-progress >/dev/null 2>&1 || true
  die "$* (issue #$num set back to status:ready; branch $LH_BRANCH kept with the model's edits for inspection)"
}

read_args=(--read AGENTS.md)
for r in "${reads[@]}"; do
  [[ -n "$r" ]] || continue
  printf '%s\n' "${files[@]}" | grep -qxF "$r" || read_args+=(--read "$r")   # files being edited are not also read-only
done
# The model's process: no GitHub token, no gh login, no git credential helper, no prompts.
NOCRED=$(mktemp -d "${TMPDIR:-/tmp}/lh-nocred.XXXXXX")
RELAY_PID=
# Make the model the only one loaded, and unload it when the run ends (local/lh-model.sh); the model
# of an interactive session is not evicted unless LH_EVICT=1.
# shellcheck source=local/lh-model.sh
source "$HERE/lh-model.sh"
trap 'lh_model_release;rm -rf "$NOCRED"; [[ -z "$RELAY_PID" ]] || kill "$RELAY_PID" 2>/dev/null || true' EXIT
lh_model_acquire "$OLLAMA_MODEL" || die "cannot make '$OLLAMA_MODEL' the loaded model"
model_env() {
  env -u GH_TOKEN -u GITHUB_TOKEN -u GH_ENTERPRISE_TOKEN -u ANTHROPIC_API_KEY \
    GH_CONFIG_DIR="$NOCRED" GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/bin/false SSH_ASKPASS=/bin/false \
    GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0= \
    "$@"
}
# Aider offers every tracked path whose name appears in the conversation, and a submodule path
# ("architecture") is a directory it cannot edit: it looped on "is a directory" errors. Ignore
# submodule paths; files read from inside them (--read) still load.
: >"$CACHE/aiderignore"
[[ ! -f .gitmodules ]] || sed -n 's/^[[:space:]]*path = \(.*\)$/\/\1/p' .gitmodules >"$CACHE/aiderignore"
# Aider: fix the context at the size Ollama serves, so a request never grows the KV cache.
cat >"$CACHE/model.settings.yml" <<YML
- name: ollama_chat/$OLLAMA_MODEL
  edit_format: $LH_AIDER_EDIT_FORMAT
  extra_params:
    num_ctx: $LH_NUM_CTX
YML
[[ "$LH_THINK" == 1 ]] || echo "    think: false" >>"$CACHE/model.settings.yml"
# Aider reads a model's window from litellm metadata, and for an Ollama model it takes the
# native 262,144, so it never trimmed history or the repo map to the 65,536 Ollama serves and
# only warned at ~300k tokens. Tell it the real window.
jq -n --arg m "ollama_chat/$OLLAMA_MODEL" --argjson ctx "$LH_NUM_CTX" \
  '{($m): {max_input_tokens: $ctx, max_tokens: 8192, max_output_tokens: 8192, litellm_provider: "ollama_chat", mode: "chat"}}' \
  >"$CACHE/model.metadata.json"
# Claude Code: with LH_THINK=0 it reaches Ollama through the relay that disables thinking.
CLAUDE_BASE_URL="$OLLAMA_HOST"
if [[ "$LH_HARNESS" == claude && "$LH_THINK" == 0 ]]; then
  rm -f "$CACHE/nothink-relay.port"
  python3 -I "$HERE/lh-nothink-relay.py" "$OLLAMA_HOST" >"$CACHE/nothink-relay.port" 2>"$CACHE/nothink-relay.log" &
  RELAY_PID=$!
  for _ in $(seq 50); do [[ -s "$CACHE/nothink-relay.port" ]] && break; sleep 0.1; done
  relay_port=$(head -1 "$CACHE/nothink-relay.port" 2>/dev/null || true)
  [[ "$relay_port" =~ ^[0-9]+$ ]] || die "thinking-off relay did not start (see $CACHE/nothink-relay.log)"
  CLAUDE_BASE_URL="http://127.0.0.1:$relay_port"
  log "Claude Code reaches the model through the thinking-off relay on port $relay_port"
fi
# --no-detect-urls: Aider offers to fetch every URL in the conversation, and --yes-always accepts.
# Each clippy error ends with a link to its lint page, so a repair round pasted Clippy's lint
# documentation into the prompt: 598k tokens for a 64k window on #39, likely also the 294k on #54 (trial 2).
aider_run() {
  model_env OLLAMA_API_BASE="$OLLAMA_HOST" aider \
    --model "ollama_chat/$OLLAMA_MODEL" --model-settings-file "$CACHE/model.settings.yml" \
    --model-metadata-file "$CACHE/model.metadata.json" \
    --no-auto-commits --no-dirty-commits --no-gitignore --yes-always \
    --no-check-update --analytics-disable --no-show-model-warnings \
    --no-detect-urls --aiderignore "$CACHE/aiderignore" \
    --chat-history-file "$CACHE/${LH_BRANCH//\//_}.chat.md" --input-history-file "$CACHE/${LH_BRANCH//\//_}.input" \
    --map-tokens 1024 \
    --test-cmd "bash -o pipefail -c 'cargo test --workspace -q 2>&1 | cut -c1-300 | tail -n 60'" --auto-test \
    "${read_args[@]}" --message "$1" "${files[@]}"
}
# Claude Code: every model slot on the local model, the context it is served with, edits only,
# cargo test, build, check, clippy and fmt and make fix as the only commands: the gates the brief
# asks for, without make gates itself (fuzzing, audit), which the script runs after the model.
# Without clippy the model spent 50 of 150 turns on refused clippy calls (#61, 2026-11-05).
# The brief's files and read-only files are named in the prompt.
# --tools sends only the six tools the model needs: all built-in tools cost 15.3k tokens of the
# window per request, these six 9.0k (measured on Claude Code 2.1.318). LH_MAX_OUTPUT: see the header.
claude_run() {
  # An empty config dir: the user's plugins, skills and MCP servers alone overflow a 32k context.
  mkdir -p "$CACHE/claude-config"
  model_env CLAUDE_CONFIG_DIR="$CACHE/claude-config" \
    ANTHROPIC_BASE_URL="$CLAUDE_BASE_URL" ANTHROPIC_AUTH_TOKEN=ollama \
    ANTHROPIC_MODEL="$OLLAMA_MODEL" ANTHROPIC_DEFAULT_OPUS_MODEL="$OLLAMA_MODEL" \
    ANTHROPIC_DEFAULT_SONNET_MODEL="$OLLAMA_MODEL" ANTHROPIC_DEFAULT_HAIKU_MODEL="$LH_BG_MODEL" \
    CLAUDE_CODE_SUBAGENT_MODEL="$OLLAMA_MODEL" CLAUDE_CODE_MAX_CONTEXT_TOKENS="$LH_NUM_CTX" \
    CLAUDE_CODE_MAX_OUTPUT_TOKENS="$LH_MAX_OUTPUT" \
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
    claude -p --model "$OLLAMA_MODEL" --max-turns "$LH_MAX_TURNS" --permission-mode acceptEdits \
      --tools Read Grep Glob Edit Write Bash \
      --allowedTools Read Grep Glob Edit Write 'Bash(cargo test:*)' 'Bash(cargo build:*)' 'Bash(cargo check:*)' \
      'Bash(cargo clippy:*)' 'Bash(cargo fmt:*)' 'Bash(make fix)' <<PROMPT
$1

Files you may edit: ${files[*]}
Files to read, not edit: AGENTS.md ${reads[*]}
Run cargo test --workspace -q after each edit. Before you finish, run make fix, then
cargo clippy --workspace --all-targets -- -D warnings, and fix what remains. The script runs the
full gates (make gates) after you; you cannot run them yourself.
PROMPT
}
model_run() { if [[ "$LH_HARNESS" == claude ]]; then claude_run "$1"; else aider_run "$1"; fi; }

# shellcheck source=local/lh-prompts.sh
source "$HERE/lh-prompts.sh"
# shellcheck source=local/lh-guard.sh
source "$HERE/lh-guard.sh"
# Stop at once when a brief file holds a second copy of itself: no repair round has recovered
# from one, and its compile errors flood the next prompt (see lh-guard.sh).
no_duplicated_files() {
  local dup; dup=$(lh_duplicated_files "${files[@]}")
  [[ -z "$dup" ]] || fail "after $1, these files hold a second copy of themselves (an edit appended to an existing file): $(tr '\n' ' ' <<<"$dup")"
}
log "round 1: implementing the brief"
model_run "$(lh_implement_prompt "$brief")" || fail "$LH_HARNESS failed"
no_duplicated_files "round 1"

# 3. Gates, plus "every test the brief names exists", with up to FIX_ROUNDS repair rounds.
# shellcheck source=local/lh-brief.sh
source "$HERE/lh-brief.sh"
missing_tests() { lh_tests_in_diff missing "$(lh_brief_test_names "$brief")"; }
gates() {
  cargo fmt --all &&
  cargo fmt --all --check &&
  cargo clippy --workspace --all-targets -q -- -D warnings &&
  cargo test --workspace -q &&
  cargo deny check &&
  bash scripts/ci/unsafe-policy.sh &&
  { m=$(missing_tests); [[ -z "$m" ]] || { echo "Tests named in the brief are missing: $m"; false; }; } &&
  { d=$(lh_deleted_tests); [[ -z "$d" ]] || { echo "These tests were removed or renamed, and the brief does not allow it; put them back exactly as they were: $d"; false; }; }
}
round=0
until out=$(gates 2>&1); do
  round=$((round + 1))
  [[ $round -le $FIX_ROUNDS ]] || { printf '%s\n' "$out" | tail -60; fail "gates still failing after $FIX_ROUNDS repair rounds"; }
  log "gates failed; repair round $round"
  model_run "$(lh_repair_prompt "$brief" "$out")" || fail "$LH_HARNESS failed"
  no_duplicated_files "repair round $round"
done
log "gates pass"

# 4. Scope: only the brief's files (and Cargo.lock for dependency changes).
allowed=$(printf '%s\n' "${files[@]}" Cargo.lock; for pin in "${pins[@]}"; do echo "${pin%% *}"; done)
extra=$(git status --porcelain --untracked-files=all | awk '{print $NF}' | grep -vxF -f <(printf '%s\n' "$allowed") || true)
[[ -z "$extra" ]] || fail "changes outside the brief's files: $extra"
[[ -n "$(git status --porcelain)" ]] || fail "the model made no changes"
# A new empty file is a change to git and to the scope check, but it is no work: the diff must add lines.
git add -N . 2>/dev/null || true
added=$(git diff --numstat origin/main | awk '$1 ~ /^[0-9]+$/ {a += $1} END {print a + 0}')
[[ "$added" -gt 0 ]] || fail "the model's changes add no lines (only empty or deleted files)"

# 5. Commit, push, draft PR.
git add -- "${files[@]}"; git add -- Cargo.lock 2>/dev/null || true
# Attended: signed and signed off by the maintainer at the keyboard. Unattended (ADR-0007): neither;
# the maintainer certifies at merge.
tool="Aider"; [[ "$LH_HARNESS" == claude ]] && tool="Claude Code"
how="run by hand"; [[ "$LH_UNATTENDED" == 1 ]] && how="unattended, not yet reviewed or certified"
if [[ "$LH_UNATTENDED" == 1 ]]; then git_commit() { git -c commit.gpgsign=false commit -q "$@"; }; else git_commit() { git commit -q -s "$@"; }; fi
git_commit -F - <<MSG
$title

Implements the brief in #$num. Tests and code written by a local model
($how); gates run by lh-implement.sh before commit.

Refs #$num

Assisted-by: $tool with a local model
MSG
git push -q -u origin "$LH_BRANCH"

tests_names=$(lh_brief_test_names "$brief")
tests_found=" $(lh_tests_in_diff found "$tests_names") "
tests_report=$(for n in $tests_names; do
  if [[ "$tests_found" == *" $n "* ]]; then echo "- [x] \`$n\`"; else echo "- [ ] \`$n\`"; fi
done)
pr_url=$(gh pr list --repo "$REPO_SLUG" --head "$LH_BRANCH" --state open --json url --jq '.[0].url // empty')
if [[ -z "$pr_url" ]]; then
  # shellcheck disable=SC2016  # backticks in the PR body are literal Markdown
  pr_url=$(gh pr create --repo "$REPO_SLUG" --draft --base main --head "$LH_BRANCH" --title "$title" --body-file - <<BODY
## Intent

Implements the brief in #$num: $title.

Closes #$num

## Affected containers

$(printf '%s\n' "${files[@]}" | sed -n 's#^crates/\([^/]*\)/.*#- `\1`#p' | sort -u)

## Tests

Test names from the brief, and whether this PR adds a function with that name:

$tests_report

## Security

Written by a local model through $tool ($how); the lead reviews it against the brief before it is marked ready.

## How to verify

Gates passed locally before commit: \`cargo fmt --check\`, \`cargo clippy -D warnings\`, \`cargo test\`, \`cargo deny check\`, \`unsafe-policy\`.

## Rollback

Revert the squash commit.
BODY
)
fi
gh issue edit "$num" --repo "$REPO_SLUG" --add-label status:in-review --remove-label status:in-progress >/dev/null 2>&1 || true
log "draft PR: $pr_url"
log "next: the lead reviews it against the brief (status:in-review)"
