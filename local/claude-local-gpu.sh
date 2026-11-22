#!/usr/bin/env bash
set -x
# Claude Code against the GPU Ollama instance (:11434).
# Workstation-only: lives in linux-hello-workstation, never in the public repo.
#
#   claude-local-gpu.sh [claude args...]
#
# The model and its window come from LH_MODEL_GPU and LH_CTX_GPU in
# ~/.config/linux-hello/models.env (local/models.env.example); OLLAMA_MODEL and LH_NUM_CTX override them.
# The window is the largest that fits the GPU's memory with the model; a larger window runs on
# the CPU instance (claude-local-cpu.sh). Shared logic and the optional variables are documented
# in claude-local-lib.sh.
set -euo pipefail
models_env=${LH_MODELS_ENV:-${XDG_CONFIG_HOME:-$HOME/.config}/linux-hello/models.env}
# shellcheck disable=SC1090
[[ ! -f "$models_env" ]] || source "$models_env"
: "${OLLAMA_HOST:=http://localhost:11434}"
: "${OLLAMA_MODEL:=${LH_MODEL_GPU:-}}"
: "${LH_NUM_CTX:=${LH_CTX_GPU:-65536}}"
[[ -n "$OLLAMA_MODEL" ]] || { echo "claude-local-gpu: LH_MODEL_GPU is not set in $models_env (see local/models.env.example)" >&2; exit 1; }
: "${NAME:=GPU}"
# shellcheck source=claude-local-lib.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/claude-local-lib.sh"
claude_local_run "$@"
