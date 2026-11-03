#!/usr/bin/env bash
# Run Claude Code against a local Ollama model through Ollama's Anthropic-compatible API.
# Workstation-only: lives in the bootstrap folder, never in the public repo. UNTESTED.
#
#   OLLAMA_MODEL=<model:tag> claude-local.sh [claude args...]
#
# Optional: OLLAMA_HOST (default http://localhost:11434), CLONE_DIR (default the linux-hello clone).
set -euo pipefail
: "${OLLAMA_HOST:=http://localhost:11434}"
: "${CLONE_DIR:=$HOME/projects/LinuxHello/linux-hello}"
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[[ -n "${OLLAMA_MODEL:-}" ]] || die "set OLLAMA_MODEL to a pulled model with tool calling, e.g. OLLAMA_MODEL=qwen3-coder:30b"
command -v claude >/dev/null || die "Claude Code not installed"
command -v curl >/dev/null || die "curl not installed"
command -v jq >/dev/null || die "jq not installed"

tags=$(curl -fsS --max-time 5 "$OLLAMA_HOST/api/tags") || die "Ollama not reachable at $OLLAMA_HOST"
jq -e --arg m "$OLLAMA_MODEL" '.models[] | select(.name == $m)' <<<"$tags" >/dev/null \
  || die "model '$OLLAMA_MODEL' not pulled on $OLLAMA_HOST (ollama pull $OLLAMA_MODEL)"

cd "$CLONE_DIR"
# Point every model slot at the local model so nothing falls back to a cloud model name,
# and switch off non-essential traffic (telemetry, update checks).
unset ANTHROPIC_API_KEY
exec env \
  ANTHROPIC_BASE_URL="$OLLAMA_HOST" \
  ANTHROPIC_AUTH_TOKEN=ollama \
  ANTHROPIC_MODEL="$OLLAMA_MODEL" \
  ANTHROPIC_DEFAULT_OPUS_MODEL="$OLLAMA_MODEL" \
  ANTHROPIC_DEFAULT_SONNET_MODEL="$OLLAMA_MODEL" \
  ANTHROPIC_DEFAULT_HAIKU_MODEL="$OLLAMA_MODEL" \
  CLAUDE_CODE_SUBAGENT_MODEL="$OLLAMA_MODEL" \
  CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
  claude --model "$OLLAMA_MODEL" "$@"
