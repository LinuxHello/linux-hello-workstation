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
: "${LH_UNATTENDED:=0}"
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
[[ "$LH_NUM_CTX" =~ ^[0-9]+$ && "$LH_MAX_TURNS" =~ ^[0-9]+$ ]] || die "LH_NUM_CTX and LH_MAX_TURNS must be numbers"
[[ "$LH_UNATTENDED" == 0 || "$LH_UNATTENDED" == 1 ]] || die "LH_UNATTENDED must be 0 or 1"
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
mapfile -t files < <(python3 - "$brief" <<'PY'
import re, sys
text = sys.argv[1]
m = re.search(r"\*\*Files:\*\*(.*?)(?:\n\*\*[A-Z]|\Z)", text, re.S)
seen = []
for p in re.findall(r"`([A-Za-z0-9_./-]+\.(?:rs|toml|md|txt|yml|yaml|json))`", m.group(1) if m else ""):
    if "/" in p or p.endswith(".toml"):
        if p not in seen: seen.append(p)
print("\n".join(seen))
PY
)
[[ ${#files[@]} -gt 0 && ${#files[@]} -le 5 ]] || die "brief must list 1-5 files under **Files:**, found ${#files[@]}"
mapfile -t reads < <(python3 - "$brief" <<'PY'
import os, re, sys
out = []
for p in re.findall(r"(?:\.\./)*([a-z0-9_-]+(?:/[A-Za-z0-9_.-]+)+\.(?:rs|toml|md))", sys.argv[1]):
    if os.path.isfile(p) and os.path.getsize(p) < 20000 and p not in out: out.append(p)
print("\n".join(out[:3]))
PY
)
log "issue #$num: $title"
log "files: ${files[*]}"

# 2. Branch.
git fetch -q origin main
# shellcheck source=local/lh-branch.sh
source "$HERE/lh-branch.sh"
lh_select_branch "$LH_BRANCH" origin/main || die "not starting issue #$num on a stale branch"
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
trap 'rm -rf "$NOCRED"' EXIT
model_env() {
  env -u GH_TOKEN -u GITHUB_TOKEN -u GH_ENTERPRISE_TOKEN -u ANTHROPIC_API_KEY \
    GH_CONFIG_DIR="$NOCRED" GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/bin/false SSH_ASKPASS=/bin/false \
    GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0= \
    "$@"
}
# Aider: fix the context at the size Ollama serves, so a request never grows the KV cache.
cat >"$CACHE/model.settings.yml" <<YML
- name: ollama_chat/$OLLAMA_MODEL
  edit_format: diff
  extra_params:
    num_ctx: $LH_NUM_CTX
YML
aider_run() {
  model_env OLLAMA_API_BASE="$OLLAMA_HOST" aider \
    --model "ollama_chat/$OLLAMA_MODEL" --model-settings-file "$CACHE/model.settings.yml" \
    --no-auto-commits --no-dirty-commits --no-gitignore --yes-always \
    --no-check-update --analytics-disable --no-show-model-warnings \
    --chat-history-file "$CACHE/${LH_BRANCH//\//_}.chat.md" --input-history-file "$CACHE/${LH_BRANCH//\//_}.input" \
    --map-tokens 1024 \
    --test-cmd "cargo test --workspace -q" --auto-test \
    "${read_args[@]}" --message "$1" "${files[@]}"
}
# Claude Code: every model slot on the local model, the context it is served with, edits only,
# cargo as the only command. The brief's files and read-only files are named in the prompt.
claude_run() {
  # An empty config dir: the user's plugins, skills and MCP servers alone overflow a 32k context.
  mkdir -p "$CACHE/claude-config"
  model_env CLAUDE_CONFIG_DIR="$CACHE/claude-config" \
    ANTHROPIC_BASE_URL="$OLLAMA_HOST" ANTHROPIC_AUTH_TOKEN=ollama \
    ANTHROPIC_MODEL="$OLLAMA_MODEL" ANTHROPIC_DEFAULT_OPUS_MODEL="$OLLAMA_MODEL" \
    ANTHROPIC_DEFAULT_SONNET_MODEL="$OLLAMA_MODEL" ANTHROPIC_DEFAULT_HAIKU_MODEL="$LH_BG_MODEL" \
    CLAUDE_CODE_SUBAGENT_MODEL="$OLLAMA_MODEL" CLAUDE_CODE_MAX_CONTEXT_TOKENS="$LH_NUM_CTX" \
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
    claude -p --model "$OLLAMA_MODEL" --max-turns "$LH_MAX_TURNS" --permission-mode acceptEdits \
      --allowedTools Read Grep Glob Edit Write 'Bash(cargo test:*)' 'Bash(cargo build:*)' 'Bash(cargo check:*)' <<PROMPT
$1

Files you may edit: ${files[*]}
Files to read, not edit: AGENTS.md ${reads[*]}
Run cargo test --workspace -q after each edit.
PROMPT
}
model_run() { if [[ "$LH_HARNESS" == claude ]]; then claude_run "$1"; else aider_run "$1"; fi; }

log "round 1: implementing the brief"
model_run "You are the implementer for Linux Hello. Implement exactly this brief. Write the brief's tests first, then the code. Edit only the files you were given. Follow AGENTS.md (read-only). No unsafe code, no unwrap() or expect() outside tests, no new dependencies beyond those the brief names.

$brief" || fail "$LH_HARNESS failed"

# 3. Gates, plus "every test the brief names exists", with up to FIX_ROUNDS repair rounds.
missing_tests() {
  python3 - "$brief" <<'PY'
import re, subprocess, sys
m = re.search(r"\*\*Tests first\*\*(.*?)(?:\n\*\*[A-Z]|\Z)", sys.argv[1], re.S)
names = [n for n in re.findall(r"`([a-z][a-z0-9_]+)`", m.group(1) if m else "") if n.count("_") >= 2]
subprocess.run(["git", "add", "-N", "."], check=False)
diff = subprocess.run(["git", "diff", "origin/main"], capture_output=True, text=True).stdout
print(" ".join(n for n in dict.fromkeys(names) if not re.search(r"^\+\s*fn " + re.escape(n) + r"\s*\(", diff, re.M)))
PY
}
gates() {
  cargo fmt --all &&
  cargo fmt --all --check &&
  cargo clippy --workspace --all-targets -q -- -D warnings &&
  cargo test --workspace -q &&
  cargo deny check &&
  bash scripts/ci/unsafe-policy.sh &&
  { m=$(missing_tests); [[ -z "$m" ]] || { echo "Tests named in the brief are missing: $m"; false; }; }
}
round=0
until out=$(gates 2>&1); do
  round=$((round + 1))
  [[ $round -le $FIX_ROUNDS ]] || { printf '%s\n' "$out" | tail -60; fail "gates still failing after $FIX_ROUNDS repair rounds"; }
  log "gates failed; repair round $round"
  model_run "The gates failed. Fix the cause in the files you were given; do not weaken tests, lints or checks.

$(printf '%s\n' "$out" | tail -80)" || fail "$LH_HARNESS failed"
done
log "gates pass"

# 4. Scope: only the brief's files (and Cargo.lock for dependency changes).
allowed=$(printf '%s\n' "${files[@]}" Cargo.lock)
extra=$(git status --porcelain --untracked-files=all | awk '{print $NF}' | grep -vxF -f <(printf '%s\n' "$allowed") || true)
[[ -z "$extra" ]] || fail "changes outside the brief's files: $extra"
[[ -n "$(git status --porcelain)" ]] || fail "the model made no changes"

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

tests_report=$(python3 - "$brief" <<'PY'
import re, subprocess, sys
m = re.search(r"\*\*Tests first\*\*(.*?)(?:\n\*\*[A-Z]|\Z)", sys.argv[1], re.S)
names = []
for n in re.findall(r"`([a-z][a-z0-9_]+)`", m.group(1) if m else ""):
    if n.count("_") >= 2 and n not in names: names.append(n)
diff = subprocess.run(["git", "diff", "origin/main...HEAD"], capture_output=True, text=True).stdout
for n in names:
    found = re.search(r"^\+\s*fn " + re.escape(n) + r"\s*\(", diff, re.M)
    print(f"- [{'x' if found else ' '}] `{n}`")
PY
)
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
