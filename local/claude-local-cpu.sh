#!/usr/bin/env bash
# Claude Code against the CPU-only Ollama instance (:11435, gemma4-26b-128k).
# Workstation-only: lives in linux-hello-workstation, never in the public repo.
#
#   claude-local-cpu.sh [claude args...]
#
# Slow by design (~40 tokens/s prompt processing, ~4 tokens/s generation); the first
# request processes the whole prompt, later ones reuse the cached prefix. Shared
# logic and the optional variables are documented in claude-local-lib.sh.
set -euo pipefail
: "${OLLAMA_HOST:=http://localhost:11435}"
: "${OLLAMA_MODEL:=gemma4-26b-128k}"
: "${LH_NUM_CTX:=131072}"
: "${NAME:=CPU}"
# shellcheck source=claude-local-lib.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/claude-local-lib.sh"
claude_local_run "$@"
