#!/usr/bin/env bash
# Create the implementer's settings file from local/implementer.env.example. Idempotent: an
# existing file is never changed. Reads no secrets and calls no remote service; it only asks the
# model server on loopback which models it has.
#
#   scripts/implementer-env.sh
#
# The file lands at ${LH_ENV_FILE:-${XDG_CONFIG_HOME:-~/.config}/linux-hello/implementer.env} with
# mode 600. Values the script can know are filled in: this checkout, the linux-hello clone, and the
# model given as OLLAMA_MODEL=<model:tag> when you run it (no model name is built in: which models
# run here is a detail of the machine). Everything else keeps the example's default.
set -euo pipefail
source "$(dirname "$0")/../common.sh"

root="$(cd "$(dirname "$0")/.." && pwd)"
example="$root/local/implementer.env.example"
env_file="${LH_ENV_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/linux-hello/implementer.env}"
host="${OLLAMA_HOST:-http://127.0.0.1:11434}"
model="${OLLAMA_MODEL:-}"

[[ -f "$example" ]] || die "$example not found"

if [[ -e "$env_file" ]]; then
  log "$env_file exists; left unchanged"
  exit 0
fi

# The example's placeholders become real values; each key appears once in the example.
dir="$(dirname "$env_file")"
mkdir -p "$dir"
tmp="$(mktemp "$dir/.implementer.env.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
chmod 600 "$tmp"
while IFS= read -r line; do
  case "$line" in
    LH_TOOLING_DIR=*) line="LH_TOOLING_DIR=$root" ;;
    CLONE_DIR=*)      line="CLONE_DIR=$CLONE_DIR" ;;
    OLLAMA_MODEL=*)   [[ -z "$model" ]] || line="OLLAMA_MODEL=$model" ;;
    LH_BG_MODEL=*)    [[ -z "$model" ]] || line="LH_BG_MODEL=$model" ;;
  esac
  printf '%s\n' "$line"
done <"$example" >"$tmp"
mv -n "$tmp" "$env_file"
[[ -e "$tmp" ]] && die "$env_file appeared while this ran; left it unchanged"
trap - EXIT
log "created $env_file (mode 600)"

# A placeholder left in the file would be used literally by the loop.
if grep -nE '^[A-Z_]+=.*<[^>]*>' "$env_file"; then
  log "WARN: the lines above still hold a placeholder; edit $env_file"
fi

# Say whether the server on loopback has the model. Informational only.
if [[ -n "$model" ]] && command -v curl >/dev/null && command -v jq >/dev/null && [[ "$host" == http://127.0.0.1:* || "$host" == http://localhost:* ]]; then
  if tags="$(curl -fsS --max-time 3 "$host/api/tags" 2>/dev/null)"; then
    if jq -e --arg m "$model" '.models | map(.name) | index($m)' >/dev/null <<<"$tags"; then
      log "model $model is available at $host"
    else
      log "WARN: $host does not list $model; set OLLAMA_MODEL in $env_file. It has:"
      jq -r '.models[].name' <<<"$tags" | sed 's/^/    /'
    fi
  else
    log "note: no model server answered at $host, so the model was not checked"
  fi
fi
