# Source it, do not run it. Workstation-only. The harness side of the shared memory (ADR-0019).
#
# lh_memory_recall <clone> <text>   prints what the memory holds on <text> as a prompt section, or
# nothing when no memory is set up or it cannot be read. A drafting run never fails because of it.
#
# The tier is fixed here: a drafting agent writes public artefacts, so it recalls at the public tier
# whatever LH_MEMORY_TIER says in the environment or in memory.env. Only a harness for an agent that
# does not write to public repositories may set another tier, by its own code, not by configuration.
#
# Settings: ~/.config/linux-hello/memory.env (local/memory.env.example), LH_MEMORY_PYTHON (default: the
# virtualenv `make memory-venv` makes, else python3), LH_MEMORY_RECALL_K (default 6).

lh_memory_recall() {
  local clone=$1 text=$2 here py out
  here=$(dirname "${BASH_SOURCE[0]}")
  # shellcheck disable=SC1090
  [[ ! -f "${LH_MEMORY_ENV:-$HOME/.config/linux-hello/memory.env}" ]] || source "${LH_MEMORY_ENV:-$HOME/.config/linux-hello/memory.env}"
  [[ -d "${LH_MEMORY_DIR:-$HOME/.local/share/linux-hello/memory}/public" ]] || return 0
  py=${LH_MEMORY_PYTHON:-}
  [[ -n "$py" ]] || { py=$HOME/.local/share/linux-hello/venv/bin/python; [[ -x "$py" ]] || py=python3; }
  if ! out=$(LH_MEMORY_TIER=public "$py" "$here/lh-memory.py" query "${text:0:2000}" --k "${LH_MEMORY_RECALL_K:-6}" --clone "$clone" 2>&1); then
    printf 'WARNING: the memory could not be read, continuing without it: %s\n' "$(tail -1 <<<"$out")" >&2
    return 0
  fi
  [[ "$out" != "(the memory has nothing on this)" ]] || return 0
  printf '%s\n' "$out"
}
