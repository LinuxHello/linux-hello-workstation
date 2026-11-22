#!/usr/bin/env bash
# Claude Code against the CPU-only Ollama instance (:11435).
# Workstation-only: lives in linux-hello-workstation, never in the public repo.
#
#   claude-local-cpu.sh [claude args...]
#
# The model and its window come from LH_MODEL_CPU and LH_CTX_CPU in
# ~/.config/linux-hello/models.env (local/models.env.example); OLLAMA_MODEL and LH_NUM_CTX override them.
# Slow by design; the first request processes the whole prompt, later ones reuse the cached
# prefix. Shared logic and the optional variables are documented in claude-local-lib.sh.
set -euo pipefail
models_env=${LH_MODELS_ENV:-${XDG_CONFIG_HOME:-$HOME/.config}/linux-hello/models.env}
# shellcheck disable=SC1090
[[ ! -f "$models_env" ]] || source "$models_env"
: "${OLLAMA_HOST:=http://localhost:11435}"
: "${OLLAMA_MODEL:=${LH_MODEL_CPU:-}}"
: "${LH_NUM_CTX:=${LH_CTX_CPU:-131072}}"
[[ -n "$OLLAMA_MODEL" ]] || { echo "claude-local-cpu: LH_MODEL_CPU is not set in $models_env (see local/models.env.example)" >&2; exit 1; }
: "${NAME:=CPU}"
# shellcheck source=claude-local-lib.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/claude-local-lib.sh"
claude_local_run "$@"
