#!/usr/bin/env bash
# Run Claude Code against a local Ollama model through Ollama's Anthropic-compatible API.
# Workstation-only: lives in linux-hello-workstation, never in the public repo.
#
#   claude-local.sh [claude args...]          e.g. claude-local.sh --remote-control
#
# Every model slot (main, Opus, Sonnet, Haiku, subagents) points at Ollama, so no call can
# reach a cloud model or bill the Anthropic account. Use this instead of a bare `claude`.
#
# Optional:
#   OLLAMA_MODEL  main model (default gemma4-26b-64k)
#   LH_BG_MODEL   background (Haiku-slot) model (default: OLLAMA_MODEL; a second model
#                 does not fit in VRAM beside gemma4-26b-64k and would evict or offload it)
#   LH_NUM_CTX    context window the server serves OLLAMA_MODEL with (default 65536);
#                 must match the model's num_ctx, or Claude Code's prompt is truncated
#   OLLAMA_HOST   model server, loopback only (default http://localhost:11434)
#   CLONE_DIR     working directory (default the linux-hello clone)
set -euo pipefail
: "${OLLAMA_HOST:=http://localhost:11434}"
: "${OLLAMA_MODEL:=gemma4-26b-64k}"
: "${LH_BG_MODEL:=$OLLAMA_MODEL}"
: "${LH_NUM_CTX:=65536}"
: "${CLONE_DIR:=$HOME/projects/LinuxHello/linux-hello}"
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }

command -v claude >/dev/null || die "Claude Code not installed"
command -v curl >/dev/null || die "curl not installed"
command -v jq >/dev/null || die "jq not installed"

# Fail closed: only a model server on this machine.
[[ "$OLLAMA_HOST" =~ ^http://(localhost|127\.0\.0\.1|\[::1\])(:[0-9]+)?/?$ ]] \
  || die "OLLAMA_HOST must be a loopback URL, got '$OLLAMA_HOST'"
[[ "$LH_NUM_CTX" =~ ^[0-9]+$ ]] || die "LH_NUM_CTX must be a number, got '$LH_NUM_CTX'"

tags=$(curl -fsS --max-time 5 "$OLLAMA_HOST/api/tags") || die "Ollama not reachable at $OLLAMA_HOST"
pulled() { jq -e --arg m "$1" '.models[] | select(.name == $m or .name == ($m + ":latest"))' <<<"$tags" >/dev/null; }
pulled "$OLLAMA_MODEL" || die "model '$OLLAMA_MODEL' not on $OLLAMA_HOST (ollama pull / ollama create)"
pulled "$LH_BG_MODEL" || die "background model '$LH_BG_MODEL' not on $OLLAMA_HOST"

# The window Claude Code assumes must equal the window Ollama serves.
show=$(curl -fsS --max-time 10 "$OLLAMA_HOST/api/show" -d "$(jq -n --arg m "$OLLAMA_MODEL" '{model: $m}')") \
  || die "cannot read model details for '$OLLAMA_MODEL'"
served=$(jq -r '.parameters // ""' <<<"$show" | awk '$1 == "num_ctx" {print $2; exit}')
if [[ -z "$served" ]]; then
  warn "'$OLLAMA_MODEL' sets no num_ctx; Ollama's default window may be smaller than $LH_NUM_CTX"
elif [[ "$served" != "$LH_NUM_CTX" ]]; then
  die "'$OLLAMA_MODEL' serves num_ctx $served but LH_NUM_CTX is $LH_NUM_CTX; set LH_NUM_CTX=$served"
fi

cd "$CLONE_DIR"
# Drop any cloud credentials and provider switches inherited from the shell.
unset ANTHROPIC_API_KEY CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY
# Switch off telemetry and update checks, except with --remote-control, which itself
# talks to claude.ai (prompts and output only; model calls still go to Ollama).
quiet=(CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1)
for a in "$@"; do [[ "$a" == --remote-control* ]] && quiet=(); done
exec env "${quiet[@]}" \
  ANTHROPIC_BASE_URL="$OLLAMA_HOST" \
  ANTHROPIC_AUTH_TOKEN=ollama \
  ANTHROPIC_MODEL="$OLLAMA_MODEL" \
  ANTHROPIC_DEFAULT_OPUS_MODEL="$OLLAMA_MODEL" \
  ANTHROPIC_DEFAULT_SONNET_MODEL="$OLLAMA_MODEL" \
  ANTHROPIC_DEFAULT_HAIKU_MODEL="$LH_BG_MODEL" \
  CLAUDE_CODE_SUBAGENT_MODEL="$OLLAMA_MODEL" \
  CLAUDE_CODE_MAX_CONTEXT_TOKENS="$LH_NUM_CTX" \
  claude --model "$OLLAMA_MODEL" "$@"
