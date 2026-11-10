#!/usr/bin/env bash
# One tick of the unattended implementer loop (ADR-0007). Workstation-only. UNTESTED against a
# live model. Run by lh-implementer.timer as the dedicated implementer user, or by hand.
#
#   lh-implement-next.sh
#
# Each tick: take the lock; skip if the GPU is busy; pick the first status:ready issue in backlog
# order (the public repository's scripts/backlog/backlog.sh: priority, no open blocker, lowest
# number) that has an implementation brief; clean the clone; run lh-implement.sh unattended with a timeout.
# On failure the issue goes back to status:ready; after LH_MAX_ATTEMPTS failures it goes to
# status:blocked with a comment holding the scrubbed tail of the log.
#
# Settings come from the environment file (LH_ENV_FILE, default
# ${XDG_CONFIG_HOME:-~/.config}/linux-hello/implementer.env; example: implementer.env.example).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '==> %s\n' "$*"; }

env_file="${LH_ENV_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/linux-hello/implementer.env}"
# shellcheck source=local/lh-env.sh
source "$HERE/lh-env.sh"
lh_load_env "$env_file"
: "${CLONE_DIR:=$HOME/projects/LinuxHello/linux-hello}"
: "${REPO_SLUG:=LinuxHello/linux-hello}"
: "${OLLAMA_HOST:=http://127.0.0.1:11434}"
if [[ -z "${OLLAMA_MODEL:-}" ]]; then
  [[ -f "$env_file" ]] && die "set OLLAMA_MODEL in $env_file"
  die "$env_file does not exist: run 'make implementer-env' to create it, then check OLLAMA_MODEL in it"
fi
: "${LH_BG_MODEL:=$OLLAMA_MODEL}"
: "${LH_MAX_ATTEMPTS:=3}"
: "${LH_RUN_TIMEOUT:=2h}"
: "${LH_BUSY_CHECK:=}"
: "${LH_STATE_DIR:=${XDG_STATE_HOME:-$HOME/.local/state}/linux-hello-implementer}"
: "${LH_IMPLEMENT:=$HERE/lh-implement.sh}"
: "${LH_RESET:=$HERE/lh-reset.sh}"
# Backlog order comes from the public repository, so the loop and `make next` agree.
: "${LH_BACKLOG:=$CLONE_DIR/scripts/backlog/backlog.sh}"
# Nobody reviews an unattended run before it commits, so it never signs off (ADR-0007).
export LH_UNATTENDED=1
# Each issue gets its own branch issue-<n>; a fixed LH_BRANCH is for attended trials only.
unset LH_BRANCH
export CLONE_DIR REPO_SLUG OLLAMA_HOST OLLAMA_MODEL LH_BG_MODEL

[[ "$LH_MAX_ATTEMPTS" =~ ^[1-9][0-9]*$ ]] || die "LH_MAX_ATTEMPTS must be a positive number"
for c in gh jq curl flock timeout; do command -v "$c" >/dev/null || die "$c not installed"; done
gh auth status >/dev/null 2>&1 || die "gh not authenticated for $(id -un)"

mkdir -p "$LH_STATE_DIR/attempts" "$LH_STATE_DIR/logs"
exec 9>"$LH_STATE_DIR/lock"
flock -n 9 || { log "another run holds the lock; nothing to do"; exit 0; }

# 1. The GPU is free: no model loaded other than ours, and the optional busy hook says not busy.
loaded=$(curl -fsS --max-time 5 "$OLLAMA_HOST/api/ps" | jq -r '.models[]? | .name // .model') \
  || die "model server not reachable at $OLLAMA_HOST"
others=$(grep -vxF -e "$OLLAMA_MODEL" -e "$LH_BG_MODEL" <<<"$loaded" | grep -v '^$' || true)
[[ -z "$others" ]] || { log "GPU busy: another model is loaded; trying again next tick"; exit 0; }
if [[ -n "$LH_BUSY_CHECK" ]] && bash -c "$LH_BUSY_CHECK"; then
  log "GPU busy (LH_BUSY_CHECK); trying again next tick"; exit 0
fi

# 2. The first status:ready issue in backlog order that has an implementation brief.
[[ -f "$LH_BACKLOG" ]] || die "$LH_BACKLOG missing; update the clone ($CLONE_DIR) to a main that has it"
ready=$(REPO_SLUG="$REPO_SLUG" bash "$LH_BACKLOG" order ready) || die "backlog order failed"
issue=""
for n in $ready; do
  if [[ "$(gh issue view "$n" --repo "$REPO_SLUG" --json body,comments \
            --jq '[.body] + [.comments[].body] | any(test("(?m)^## Implementation brief"))')" == true ]]; then
    issue=$n; break
  fi
done
[[ -n "$issue" ]] || { log "no status:ready issue with a brief; nothing to do"; exit 0; }

# 3. A clean clone on an up-to-date main (lh-reset.sh keeps a rescue copy of anything it removes).
bash "$LH_RESET" -y --main >/dev/null

# 4. Implement, counting attempts per issue.
count_file="$LH_STATE_DIR/attempts/$issue"
attempt=$(( $(cat "$count_file" 2>/dev/null || echo 0) + 1 ))
echo "$attempt" >"$count_file"
run_log="$LH_STATE_DIR/logs/issue-$issue-$(date -u +%Y%m%dT%H%M%SZ).log"
log "issue #$issue, attempt $attempt of $LH_MAX_ATTEMPTS; log: $run_log"
rc=0
timeout --kill-after=5m "$LH_RUN_TIMEOUT" bash "$LH_IMPLEMENT" "$issue" >"$run_log" 2>&1 || rc=$?
if [[ $rc == 0 ]]; then
  rm -f "$count_file"
  log "issue #$issue: draft pull request opened"
  exit 0
fi

# 5. Failure. lh-implement.sh returns the issue to status:ready itself, but not when it was killed.
gh issue edit "$issue" --repo "$REPO_SLUG" --add-label status:ready --remove-label status:in-progress >/dev/null 2>&1 || true
reason="exit status $rc"; [[ $rc == 124 || $rc == 137 ]] && reason="timed out after $LH_RUN_TIMEOUT"
if (( attempt < LH_MAX_ATTEMPTS )); then
  log "issue #$issue failed ($reason); back to status:ready"
  exit 1
fi

# The comment is public: no paths, user or host names, model names or endpoints (invariant 8).
scrub() {
  local s; s=$(sed 's/\x1b\[[0-9;]*m//g')
  local pairs=("$CLONE_DIR" "<clone>" "$LH_STATE_DIR" "<state>" "$HOME" "~" \
               "$OLLAMA_HOST" "<model-server>" "$OLLAMA_MODEL" "<model>" "$LH_BG_MODEL" "<model>" \
               "$(hostname 2>/dev/null || echo localhost)" "<host>" "$(id -un)" "<user>")
  local i
  for ((i = 0; i < ${#pairs[@]}; i += 2)); do
    [[ -n "${pairs[i]}" ]] && s=${s//"${pairs[i]}"/"${pairs[i+1]}"}
  done
  printf '%s\n' "$s"
}
tail_log=$(tail -n 40 "$run_log" | scrub)
gh issue edit "$issue" --repo "$REPO_SLUG" --add-label status:blocked --remove-label status:ready >/dev/null
gh issue comment "$issue" --repo "$REPO_SLUG" --body-file - >/dev/null <<BODY
The unattended implementer failed this issue $attempt times (last: $reason) and stopped retrying it (status:blocked, ADR-0007). The lead diagnoses it; the brief may need rewriting or splitting.

<details><summary>Last 40 lines of the last run</summary>

\`\`\`text
$tail_log
\`\`\`

</details>
BODY
rm -f "$count_file"
log "issue #$issue blocked after $attempt attempts ($reason)"
exit 1
