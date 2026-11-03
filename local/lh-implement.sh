#!/usr/bin/env bash
# Implementer step of the agent loop (ADR-0004): a local model, through Aider, implements one issue
# from its brief. Workstation-only. UNTESTED against a live model.
#
#   lh-implement.sh <issue>
#
# The model only edits code. This script does everything else deterministically:
#   1. reads the issue's "## Implementation brief" and the files it lists;
#   2. runs Aider on exactly those files (plus AGENTS.md and any repo file the brief names, read-only),
#      with cargo test after each edit;
#   3. runs the gates, giving the model up to two more rounds with the failure output;
#   4. refuses changes outside the brief's files;
#   5. commits (signed, signed-off), pushes branch issue-<n>, opens a draft PR.
set -euo pipefail
: "${CLONE_DIR:=$HOME/projects/LinuxHello/linux-hello}"
: "${REPO_SLUG:=LinuxHello/linux-hello}"
: "${OLLAMA_HOST:=http://127.0.0.1:11434}"
: "${OLLAMA_MODEL:=qwen38-27b-text-32k}"
: "${FIX_ROUNDS:=2}"
HERE="$(cd "$(dirname "$0")" && pwd)"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/linux-hello-aider"
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '\033[1m==> %s\033[0m\n' "$*"; }

num=${1:-}; [[ "$num" =~ ^[0-9]+$ ]] || die "usage: $0 <issue>"
[[ -d "$HOME/.cargo/bin" ]] && PATH="$HOME/.cargo/bin:$PATH"
[[ -d "$HOME/.local/bin" ]] && PATH="$HOME/.local/bin:$PATH"
for c in aider gh git jq python3 cargo curl; do command -v "$c" >/dev/null || die "$c not installed (aider: bash $HERE/install-aider.sh)"; done
gh auth status >/dev/null 2>&1 || die "gh not authenticated"
[[ "$OLLAMA_HOST" =~ ^http://(127\.0\.0\.1|localhost):[0-9]+$ ]] || die "OLLAMA_HOST must be loopback, got '$OLLAMA_HOST'"
curl -fsS --max-time 5 "$OLLAMA_HOST/api/tags" | jq -e --arg m "$OLLAMA_MODEL" '.models[] | select(.name == $m or .model == $m)' >/dev/null \
  || die "model '$OLLAMA_MODEL' not available on $OLLAMA_HOST"
cd "$CLONE_DIR"
[[ "$(git config --get commit.gpgsign || true)" == "true" ]] || die "commit signing is not enabled in $CLONE_DIR"
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
if git show-ref -q --verify "refs/heads/issue-$num"; then git switch -q "issue-$num"; else git switch -q --no-track -c "issue-$num" origin/main; fi
gh issue edit "$num" --repo "$REPO_SLUG" --add-label status:in-progress --remove-label status:ready >/dev/null 2>&1 || true
fail() {
  gh issue edit "$num" --repo "$REPO_SLUG" --add-label status:ready --remove-label status:in-progress >/dev/null 2>&1 || true
  die "$* (issue #$num set back to status:ready; branch issue-$num kept with the model's edits for inspection)"
}

read_args=(--read AGENTS.md)
for r in "${reads[@]}"; do
  [[ -n "$r" ]] || continue
  printf '%s\n' "${files[@]}" | grep -qxF "$r" || read_args+=(--read "$r")   # files being edited are not also read-only
done
aider_run() {
  OLLAMA_API_BASE="$OLLAMA_HOST" aider \
    --model "ollama_chat/$OLLAMA_MODEL" --model-settings-file "$HERE/aider.model.settings.yml" \
    --no-auto-commits --no-dirty-commits --no-gitignore --yes-always \
    --no-check-update --analytics-disable --no-show-model-warnings \
    --chat-history-file "$CACHE/issue-$num.chat.md" --input-history-file "$CACHE/issue-$num.input" \
    --map-tokens 1024 \
    --test-cmd "cargo test --workspace -q" --auto-test \
    "${read_args[@]}" --message "$1" "${files[@]}"
}

log "round 1: implementing the brief"
aider_run "You are the implementer for Linux Hello. Implement exactly this brief. Write the brief's tests first, then the code. Edit only the files you were given. Follow AGENTS.md (read-only). No unsafe code, no unwrap() or expect() outside tests, no new dependencies beyond those the brief names.

$brief" || fail "aider failed"

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
  aider_run "The gates failed. Fix the cause in the files you were given; do not weaken tests, lints or checks.

$(printf '%s\n' "$out" | tail -80)" || fail "aider failed"
done
log "gates pass"

# 4. Scope: only the brief's files (and Cargo.lock for dependency changes).
allowed=$(printf '%s\n' "${files[@]}" Cargo.lock)
extra=$(git status --porcelain --untracked-files=all | awk '{print $NF}' | grep -vxF -f <(printf '%s\n' "$allowed") || true)
[[ -z "$extra" ]] || fail "changes outside the brief's files: $extra"
[[ -n "$(git status --porcelain)" ]] || fail "the model made no changes"

# 5. Commit, push, draft PR.
git add -- "${files[@]}"; git add -- Cargo.lock 2>/dev/null || true
git commit -q -s -F - <<MSG
$title

Implements the brief in #$num. Tests and code written by a local model;
gates run by lh-implement.sh before commit.

Refs #$num

Assisted-by: Aider with a local model
MSG
git push -q -u origin "issue-$num"

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
pr_url=$(gh pr list --repo "$REPO_SLUG" --head "issue-$num" --state open --json url --jq '.[0].url // empty')
if [[ -z "$pr_url" ]]; then
  # shellcheck disable=SC2016  # backticks in the PR body are literal Markdown
  pr_url=$(gh pr create --repo "$REPO_SLUG" --draft --base main --head "issue-$num" --title "$title" --body-file - <<BODY
## Intent

Implements the brief in #$num: $title.

Closes #$num

## Affected containers

$(printf '%s\n' "${files[@]}" | sed -n 's#^crates/\([^/]*\)/.*#- `\1`#p' | sort -u)

## Tests

Test names from the brief, and whether this PR adds a function with that name:

$tests_report

## Security

Written by a local model through Aider; the lead reviews it against the brief before it is marked ready.

## How to verify

Gates passed locally before commit: \`cargo fmt --check\`, \`cargo clippy -D warnings\`, \`cargo test\`, \`cargo deny check\`, \`unsafe-policy\`.

## Rollback

Revert the squash commit.
BODY
)
fi
gh issue edit "$num" --repo "$REPO_SLUG" --add-label status:in-review --remove-label status:in-progress >/dev/null 2>&1 || true
log "draft PR: $pr_url"
log "next: bash $HERE/lh-agent.sh review ${pr_url##*/}"
