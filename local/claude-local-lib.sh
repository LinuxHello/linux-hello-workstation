# Shared by claude-local-cpu.sh and claude-local-gpu.sh. Source it, do not run it.
# Workstation-only: lives in linux-hello-workstation, never in the public repo.
#
# claude_local_run [claude args...]  starts Claude Code against a local Ollama model
# through Ollama's Anthropic-compatible API. Every model slot (main, Opus, Sonnet,
# Haiku, subagents) points at Ollama, so no call can reach a cloud model or bill the
# Anthropic account.
#
# The caller sets the defaults for the instance it fronts:
#   OLLAMA_HOST   model server, loopback only
#   OLLAMA_MODEL  main model
#   LH_NUM_CTX    context window the server serves OLLAMA_MODEL with; must match the
#                 model's num_ctx, or Claude Code's prompt is truncated
#   NAME          session name
# Optional for either:
#   LH_BG_MODEL   background (Haiku-slot) model (default: OLLAMA_MODEL; a second model
#                 does not fit in VRAM beside the main one and would evict or offload it)
#   CLONE_DIR     working directory (default $HOME/projects)
#   LH_LEAN       1 (default) starts without MCP servers, user settings/plugins and
#                 skills. Those add roughly 10k+ tokens to every prompt, which costs
#                 minutes on the CPU instance (about 40 tokens/s). 0 = load everything.
#   API_TIMEOUT_MS  how long Claude Code waits for a response (default 30 min; the
#                 first CPU request must process the whole prompt before any token)

claude_local_run() {
  : "${LH_BG_MODEL:=$OLLAMA_MODEL}"
  : "${CLONE_DIR:=$HOME/projects}"
  : "${LH_LEAN:=1}"
  : "${API_TIMEOUT_MS:=1800000}"
  die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
  warn() { printf 'WARNING: %s\n' "$*" >&2; }

  command -v claude >/dev/null || die "Claude Code not installed"
  command -v curl >/dev/null || die "curl not installed"
  command -v jq >/dev/null || die "jq not installed"

  # Fail closed: only a model server on this machine.
  [[ "$OLLAMA_HOST" =~ ^http://(localhost|127\.0\.0\.1|\[::1\])(:[0-9]+)?/?$ ]] \
    || die "OLLAMA_HOST must be a loopback URL, got '$OLLAMA_HOST'"
  [[ "$LH_NUM_CTX" =~ ^[0-9]+$ ]] || die "LH_NUM_CTX must be a number, got '$LH_NUM_CTX'"
  [[ "$API_TIMEOUT_MS" =~ ^[0-9]+$ ]] || die "API_TIMEOUT_MS must be a number, got '$API_TIMEOUT_MS'"

  local tags show served
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
  local quiet=(CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1) a
  for a in "$@"; do [[ "$a" == --remote-control* ]] && quiet=(); done

  # Lean prompt: no MCP servers (none are passed via --mcp-config), no user-scope
  # settings (so no user plugins, hooks or memory), no skills.
  local lean=()
  [[ "$LH_LEAN" == 0 ]] || lean=(--strict-mcp-config --setting-sources project,local --disable-slash-commands)

  exec env "${quiet[@]}" \
    ANTHROPIC_BASE_URL="$OLLAMA_HOST" \
    ANTHROPIC_AUTH_TOKEN=ollama \
    ANTHROPIC_MODEL="$OLLAMA_MODEL" \
    ANTHROPIC_DEFAULT_OPUS_MODEL="$OLLAMA_MODEL" \
    ANTHROPIC_DEFAULT_SONNET_MODEL="$OLLAMA_MODEL" \
    ANTHROPIC_DEFAULT_HAIKU_MODEL="$LH_BG_MODEL" \
    CLAUDE_CODE_SUBAGENT_MODEL="$OLLAMA_MODEL" \
    CLAUDE_CODE_MAX_CONTEXT_TOKENS="$LH_NUM_CTX" \
    API_TIMEOUT_MS="$API_TIMEOUT_MS" \
    claude --model "$OLLAMA_MODEL" --name "$NAME" "${lean[@]}" "$@"
}
