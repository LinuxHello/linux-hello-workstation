#!/usr/bin/env bash
set -x
# Claude Code against the GPU Ollama instance (:11434, gemma4-26b-64k on the 7900XTX).
# Workstation-only: lives in linux-hello-workstation, never in the public repo.
#
#   claude-local-gpu.sh [claude args...]
#
# 64k is the largest window that fits ~20.6 GiB of usable VRAM with the model;
# the 128k variant runs on the CPU instance (claude-local-cpu.sh). Shared logic
# and the optional variables are documented in claude-local-lib.sh.
set -euo pipefail
: "${OLLAMA_HOST:=http://localhost:11434}"
: "${OLLAMA_MODEL:=gemma4-26b-64k}"
: "${LH_NUM_CTX:=65536}"
: "${NAME:=GPU}"
# shellcheck source=claude-local-lib.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/claude-local-lib.sh"
claude_local_run "$@"
