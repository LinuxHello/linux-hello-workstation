# Model lifecycle for the local scripts; sourced, not run. Tested by local/test-lh-model.sh.
# Workstation-only: lives in linux-hello-workstation, never in the public repo.
#
# One GPU holds one big model at a time. A script that needs a model makes it the only one loaded
# (lh_model_acquire) and unloads it when it is done (lh_model_release), so the next script, or an
# interactive session, starts from free VRAM. Ollama itself loads and unloads models on demand; this
# adds the three things it cannot know: which role needs which model, that a session of yours may be
# using the model another script wants to evict, and that a model this script loaded should not stay
# in VRAM for the 30 minutes of its keep-alive.
#
#   lh_role <implement|draft>   sets OLLAMA_MODEL and LH_NUM_CTX for the role from the models file
#   lh_model_acquire <model>    make <model> the only one loaded; refuses to evict a model that an
#                               interactive Claude Code session uses, unless LH_EVICT=1
#   lh_model_release            unload what lh_model_acquire loaded (a model that was already loaded
#                               stays loaded)
#
# Settings, in ${LH_MODELS_ENV:-~/.config/linux-hello/models.env} (see local/models.env.example):
#   LH_MODEL_IMPLEMENT / LH_CTX_IMPLEMENT   the implementer's model and the window it is served with
#   LH_MODEL_DRAFT / LH_CTX_DRAFT           the model that drafts briefs and ADRs
#   OLLAMA_HOST     model server, loopback only (default http://127.0.0.1:11434)
#   LH_EVICT        1 = unload a model even when an interactive session uses it (default 0)

: "${OLLAMA_HOST:=http://127.0.0.1:11434}"
LH_LOADED_BY_US=""

lh_model_die() { printf 'ERROR: %s\n' "$*" >&2; return 1; }

# POST a JSON body to the model server's /api/generate (an empty prompt loads or unloads a model).
lh_model_post() {
  [[ "$OLLAMA_HOST" =~ ^http://(127\.0\.0\.1|localhost|\[::1\]):[0-9]+$ ]] \
    || { lh_model_die "OLLAMA_HOST must be loopback, got '$OLLAMA_HOST'"; return; }
  curl -fsS --max-time "${LH_MODEL_TIMEOUT:-600}" "$OLLAMA_HOST/api/generate" -d "$1" >/dev/null
}

# The names of the models loaded now, one per line.
lh_models_loaded() {
  curl -fsS --max-time 10 "$OLLAMA_HOST/api/ps" | jq -r '.models[].name'
}

# Whether an interactive Claude Code session is running on <model> (claude-local-*.sh passes --model).
lh_session_uses() {
  pgrep -f -- "claude --model $1( |\$)" >/dev/null 2>&1
}

lh_model_unload() {
  lh_model_post "$(jq -n --arg m "$1" '{model: $m, keep_alive: 0}')"
}

lh_model_acquire() {
  local target=$1 loaded m
  loaded=$(lh_models_loaded) || { lh_model_die "model server not reachable at $OLLAMA_HOST"; return; }
  while IFS= read -r m; do
    [[ -n "$m" && "$m" != "$target" ]] || continue
    if [[ "${LH_EVICT:-0}" != 1 ]] && lh_session_uses "$m"; then
      lh_model_die "'$m' is in use by an interactive session; close it, or run with LH_EVICT=1 to unload it"
      return
    fi
    printf 'unloading %s to make room for %s\n' "$m" "$target" >&2
    lh_model_unload "$m" || { lh_model_die "could not unload '$m'"; return; }
  done <<<"$loaded"
  if grep -qxF "$target" <<<"$loaded"; then
    return 0
  fi
  printf 'loading %s\n' "$target" >&2
  lh_model_post "$(jq -n --arg m "$target" '{model: $m, keep_alive: "30m"}')" \
    || { lh_model_die "could not load '$target'"; return; }
  LH_LOADED_BY_US=$target
}

lh_model_release() {
  [[ -n "$LH_LOADED_BY_US" ]] || return 0
  printf 'unloading %s\n' "$LH_LOADED_BY_US" >&2
  lh_model_unload "$LH_LOADED_BY_US" || true
  LH_LOADED_BY_US=""
}

lh_role() {
  local role=${1:-} file=${LH_MODELS_ENV:-${XDG_CONFIG_HOME:-$HOME/.config}/linux-hello/models.env}
  # shellcheck disable=SC1090
  [[ ! -f "$file" ]] || source "$file"
  : "${LH_MODEL_IMPLEMENT:=gemma4-26b-64k:latest}" "${LH_CTX_IMPLEMENT:=65536}"
  : "${LH_MODEL_DRAFT:=qwen38-27b-text-32k:latest}" "${LH_CTX_DRAFT:=32768}"
  case "$role" in
    implement) OLLAMA_MODEL=$LH_MODEL_IMPLEMENT LH_NUM_CTX=$LH_CTX_IMPLEMENT ;;
    draft)     OLLAMA_MODEL=$LH_MODEL_DRAFT LH_NUM_CTX=$LH_CTX_DRAFT ;;
    *) lh_model_die "unknown role '$role' (implement or draft)"; return ;;
  esac
}
