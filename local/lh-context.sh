# Source it, do not run it. Workstation-only.
#
# lh_draft_context <clone> <text>   prints what a drafting model needs from the repository, taken from
# the files and identifiers that <text> (an issue) names: for each file its line count and an outline
# of its items, and the definition of each backticked identifier. The harness collects this so the
# model does not have to explore a repository with a window too small to compact (measured
# 2026-11-13: a 64k window overflowed on whole-file Reads and the compaction reply was cut off).
#
# LH_DRAFT_CONTEXT_BYTES   cap on the output (default 24000, about 7k tokens)
# LH_DRAFT_CONTEXT_FILES   most files outlined (default 8)

lh_draft_context() {
  local clone=$1 text=$2 cap=${LH_DRAFT_CONTEXT_BYTES:-24000} maxfiles=${LH_DRAFT_CONTEXT_FILES:-8}
  local out="" part f n id count=0
  local -a files=()

  # Files the text names, kept when they exist in the clone (by path, or by unique basename).
  local tracked
  tracked=$(git -C "$clone" ls-files 2>/dev/null || true)
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    f=${f#./}
    if [[ -f "$clone/$f" ]]; then :
    else
      mapfile -t hit < <(grep -E "(^|/)$(sed 's/[.[\*^$]/\\&/g' <<<"$f")\$" <<<"$tracked")
      [[ ${#hit[@]} -eq 1 ]] || continue
      f=${hit[0]}
    fi
    [[ " ${files[*]-} " == *" $f "* ]] || files+=("$f")
  done < <(grep -oE '[A-Za-z0-9_./-]+\.(rs|toml|sh|py|yml|yaml|service|conf|json)' <<<"$text" | awk '!s[$0]++')

  for f in "${files[@]-}"; do
    [[ -n "$f" && $count -lt $maxfiles ]] || continue
    count=$((count + 1))
    n=$(wc -l < "$clone/$f")
    out+="### $f ($n lines)"$'\n'
    case "$f" in
      *.rs|*.sh|*.py)
        out+=$(grep -nE '^[[:space:]]*(pub(\([a-z]+\))? +)?(async +|unsafe +|const +)*(fn|struct|enum|trait|impl|mod|type|static|macro_rules!|def|class) |^[[:space:]]*#\[(cfg\(test\)|test|tokio::test)\]|^[a-zA-Z_][a-zA-Z0-9_]*\(\) *\{' "$clone/$f" | head -80)$'\n' ;;
      *)
        out+=$(head -40 "$clone/$f" | nl -ba | head -40)$'\n' ;;
    esac
    out+=$'\n'
  done

  # Where the backticked identifiers are defined.
  local ids defs
  ids=$(grep -oE '`[A-Za-z_][A-Za-z0-9_]{2,}(::[A-Za-z_][A-Za-z0-9_]*)*`' <<<"$text" | tr -d '`' | sed 's/.*:://' | awk '!s[$0]++' | head -20)
  defs=""
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    defs+=$(git -C "$clone" grep -nE "^[[:space:]]*(pub(\([a-z]+\))? +)?(async +|unsafe +|const +)*(fn|struct|enum|trait|type|static|const) +$id\b" -- '*.rs' '*.sh' '*.py' 2>/dev/null | head -3)
    defs+=$'\n'
  done <<<"$ids"
  defs=$(grep -v '^$' <<<"$defs" || true)
  [[ -z "$defs" ]] || out+="### Definitions of identifiers the issue names (file:line:text)"$'\n'"$defs"$'\n'

  [[ -n "$out" ]] || { printf '(the issue names no file that exists in the repository)\n'; return 0; }
  if [[ ${#out} -gt $cap ]]; then
    printf '%s\n[... cut at %s bytes ...]\n' "${out:0:cap}" "$cap"
  else
    printf '%s' "$out"
  fi
}

# lh_brief_open_points <clone> <issue text> <brief>   prints what a lead would send a brief back for:
# hedges that leave a decision to the implementer, and names the brief cites that exist neither in the
# repository nor in the issue (new tests the brief introduces are not counted). Prints nothing when
# the brief is clean. Source lh-brief.sh first (lh_brief_test_names).
lh_brief_open_points() {
  local clone=$1 issue=$2 brief=$3 hedges names tests n
  hedges=$(grep -niE '^#+ To look up|unverified|not checked|could not (find|verify)|if (none|nothing) (exists|holds|is found)|stop and say|say so in the PR|if the (helper|store|file) (has|does) not|check `?[A-Za-z_./]+`? (for|to see)' <<<"$brief" | cut -c1-160 || true)
  [[ -z "$hedges" ]] || printf 'HEDGES (the implementer would have to decide or look this up; resolve it or take it out):\n%s\n' "$hedges"
  tests=$(lh_brief_test_names "$brief" 2>/dev/null || true)
  [[ -n "$tests" ]] || printf 'FORMAT: the harness finds no test names. In the "Properties and tests first" section list every test as a bullet that starts with its backticked name: "- `test_name`: what it checks". Prose does not count.\n'
  names=$(grep -oE '`[a-z][a-z0-9]*(_[a-z0-9]+)+`' <<<"$brief" | tr -d '`' | awk '!s[$0]++')
  local missing=""
  while IFS= read -r n; do
    [[ -n "$n" ]] || continue
    grep -qxF "$n" <<<"$tests" && continue
    grep -qF "$n" <<<"$issue" && continue
    git -C "$clone" grep -qwF -- "$n" 2>/dev/null && continue
    missing+="$n "
  done <<<"$names"
  local cross
  cross=$(printf '%s\n' "$brief" | python3 -I "$(dirname "${BASH_SOURCE[0]}")/lh-brief-checks.py" "$clone" 2>/dev/null || true)
  [[ -z "$cross" ]] || printf 'INCONSISTENT (the brief contradicts itself; make the sections agree):\n%s\n' "$cross"
  [[ -z "$missing" ]] || printf 'NAMES NOT FOUND in the repository or the issue (if the brief cites them as existing, find the real one with Grep; if it introduces them, say "new" beside each): %s\n' "$missing"
}

# lh_draft_facts <architecture repo>   prints the numbers a brief may need to name new notes: the next free
# ADR number and the highest spike, read from the repository's main (origin/main, else main), never
# from the checked-out branch. Prints nothing when there is no such repository. The pin of that
# repository inside linux-hello lags behind its main, and a model reading the pin proposed an ADR
# number that was already taken (2026-11-14).
lh_draft_facts() {
  local arch=${1:-} ref="" cand adr spike
  [[ -n "$arch" && -d "$arch/.git" ]] || return 0
  for cand in origin/main main; do
    if git -C "$arch" rev-parse --verify --quiet "$cand^{commit}" >/dev/null; then ref=$cand; break; fi
  done
  [[ -n "$ref" ]] || return 0
  adr=$(git -C "$arch" ls-tree --name-only "$ref" adr/ | sed -n 's#^adr/\([0-9]\{4\}\)-.*#\1#p' | sort | tail -1)
  spike=$(git -C "$arch" ls-tree --name-only "$ref" spikes/ | sed -n 's#^spikes/\([0-9]\{4\}\)-.*#\1#p' | sort | tail -1)
  [[ -n "$adr" || -n "$spike" ]] || return 0
  printf 'The architecture repository on %s (not whatever branch is checked out): ' "$ref"
  [[ -z "$adr" ]] || printf 'the highest ADR is %s, so the next free ADR number is %04d; ' "$adr" "$((10#$adr + 1))"
  [[ -z "$spike" ]] || printf 'the highest spike is %s, and a spike is numbered by its issue number (the spike for issue #136 is spikes/0136-<slug>.md). ' "$spike"
  printf 'Use these numbers and never guess a number.\n'
}
