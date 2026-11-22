#!/usr/bin/env bash
# This repository is public, so what it holds must not describe the maintainer's machine
# (linux-hello AGENTS.md, invariant 8): no home or synced-folder paths, no model names, no GPU
# models. Fails and lists the lines that match. Run by make test and by CI.
#
#   scripts/check-public.sh                  the tracked files of this checkout
#   scripts/check-public.sh --history [DIR]  every commit and every commit message of the
#                                            repository in DIR (default: this checkout); used by
#                                            scripts/history-clean.sh after a rewrite
#
# It also checks the words in ${LH_PUBLIC_CHECK_WORDS:-~/.config/linux-hello/public-check-words}
# (one extended regular expression per line), such as the machine's name; that list stays private
# because it names what it guards. CI writes it from a repository secret, and skips it without one.
#
# The patterns below are written so that they do not match themselves (g[e]mma, not the plain
# word): that way this file passes its own check and a history rewrite leaves it unchanged.
set -euo pipefail
history=0
if [[ "${1:-}" == --history ]]; then history=1; shift; fi
cd "${1:-$(dirname "$0")/..}"

# Each pattern with the reason it is private.
patterns=(
  "(^|[[:space:]\"'=:(])/home/[a-z_][a-z0-9_-]*/"  # an absolute home path names the account (the test VMs' user lh is not private)
  "(^|[[:space:]\"'=:(])/Users/[A-Za-z]"           # the same on macOS
  '/srv/sy[n]c|Goog[l]eDrive|Obsidian Vault[s]'    # the synced notes folder
  '\b(g[e]mma|q[w]en|l[l]ama[0-9]|m[i]stral|m[i]xtral|d[e]epseek|p[h]i[0-9]|o[r]nith)'  # which models run here
  '\b(79[0]0 ?xtx|r[x] ?[0-9]{4}|r[t]x ?[0-9]{4}|r[a]deon|g[e]force)\b'               # which GPU is in the machine
)
words=${LH_PUBLIC_CHECK_WORDS:-${XDG_CONFIG_HOME:-$HOME/.config}/linux-hello/public-check-words}
args=()
for p in "${patterns[@]}"; do args+=(-e "$p"); done
private=0
[[ ! -s "$words" ]] || private=1

# A private word is reported by place only, never with its line: CI logs are public.
if [[ $history -eq 0 ]]; then
  hits=$(git grep -n -I -i -E "${args[@]}" -- . | grep -v '/home/lh/' || true)
  [[ $private -eq 0 ]] || hits+=$'\n'$(git grep -n -I -i -E -f "$words" -- . | cut -d: -f1-2 | sed 's/$/: (a private word)/' || true)
else
  # Every tree that ever existed, then every message (with its commit, so a hit can be found).
  hits=$(git rev-list --all | xargs -r git grep -n -I -i -E "${args[@]}" | grep -v '/home/lh/' || true)
  messages() { git rev-list --all | while read -r c; do git log -1 --format=%B "$c" | grep -q -i -E "$@" && echo "$c message"; done; true; }
  hits+=$'\n'$(messages "${args[@]}" | sed 's/$/: matches a pattern/')
  if [[ $private -eq 1 ]]; then
    hits+=$'\n'$(git rev-list --all | xargs -r git grep -n -I -i -E -f "$words" | cut -d: -f1-3 | sed 's/$/: (a private word)/' || true)
    hits+=$'\n'$(messages -f "$words" | sed 's/$/: (a private word)/')
  fi
fi

hits=$(grep -v "^$" <<<"$hits" || true)
if [[ -n "$hits" ]]; then
  printf '%s\n' "$hits"
  echo "check-public: the lines above describe this machine; move the value into ~/.config/linux-hello or local.mk" >&2
  exit 1
fi
echo "check-public: ok"
