#!/usr/bin/env bash
# Install Aider for the current user (no root). Idempotent. Workstation-only.
#
# Aider supports Python 3.8-3.13; the system Python here is newer. uv installs Aider into its own
# environment with a uv-managed Python 3.12, independent of the system Python and of any active
# virtualenv. If uv is missing, it is installed into a private venv first.
set -euo pipefail
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '\033[1m==> %s\033[0m\n' "$*"; }
PATH="$HOME/.local/bin:$PATH"
TOOLS="${XDG_CACHE_HOME:-$HOME/.cache}/linux-hello-aider/uv-venv"

if command -v aider >/dev/null && aider --version >/dev/null 2>&1; then
  log "aider already installed: $(aider --version | head -1)"; exit 0
fi

uv_bin=$(command -v uv || true)
if [[ -z "$uv_bin" ]]; then
  log "installing uv into $TOOLS (private venv, system Python untouched)"
  command -v python3 >/dev/null || die "python3 not found"
  [[ -x "$TOOLS/bin/uv" ]] || { python3 -m venv "$TOOLS" && "$TOOLS/bin/python" -m pip install -q --upgrade pip uv; }
  uv_bin="$TOOLS/bin/uv"
fi

log "installing aider with a uv-managed Python 3.12"
# Run outside any active virtualenv so uv does not pick it up.
env -u VIRTUAL_ENV "$uv_bin" tool install --force --python 3.12 --with pip aider-chat@latest
command -v aider >/dev/null || die "aider installed but not on PATH; add ~/.local/bin to PATH"
log "$(aider --version | head -1)"
