# shellcheck shell=bash
# Loads the implementer's settings; sourced, not run. Tested by local/test-lh-env.sh.
# Workstation-only: lives in linux-hello-workstation, never in the public repo.
#
#   lh_load_env [file]   exports every NAME=value line of the file (default
#                        ${XDG_CONFIG_HOME:-~/.config}/linux-hello/implementer.env) that the caller
#                        has not set already, so `OLLAMA_MODEL=x make implement` and HARNESS= win
#                        over the file. Values are read as text, never run or expanded: no shell
#                        executes anything in the file through this function. Lines that are not
#                        NAME=value with NAME in capitals, digits and underscores are skipped.
#                        A missing file is not an error.

lh_load_env() {
  local file=${1:-${XDG_CONFIG_HOME:-$HOME/.config}/linux-hello/implementer.env} line name value
  [[ -f "$file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^([A-Z][A-Z0-9_]*)=(.*)$ ]] || continue
    name=${BASH_REMATCH[1]} value=${BASH_REMATCH[2]}
    [[ -v "$name" ]] && continue
    if [[ "$value" =~ ^\"(.*)\"$ || "$value" =~ ^\'(.*)\'$ ]]; then value=${BASH_REMATCH[1]}; fi
    export "$name=$value"
  done < "$file"
}
