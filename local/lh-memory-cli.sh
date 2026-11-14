#!/usr/bin/env bash
# The maintainer's entry to local/lh-memory.py: reads ~/.config/linux-hello/memory.env and uses the
# virtualenv `make memory-venv` makes (else python3). The tier is LH_MEMORY_TIER, default public.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
envfile=${LH_MEMORY_ENV:-$HOME/.config/linux-hello/memory.env}
# shellcheck source=/dev/null  # the maintainer's own settings file
if [[ -f "$envfile" ]]; then set -a; source "$envfile"; set +a; fi
py=${LH_MEMORY_PYTHON:-$HOME/.local/share/linux-hello/venv/bin/python}
[[ -x "$py" ]] || py=python3
exec "$py" "$here/lh-memory.py" "$@"
