#!/usr/bin/env bash
# Tests for the shared memory (ADR-0019): the unit tests of local/lhmem, then the CLI end to end on the
# JSON-lines backend with a stub embedding server. The LanceDB store is tested only when lancedb is
# installed. Needs bash, python3, git.
#
#   local/test-lh-memory.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
work=$(mktemp -d)
srv=""
trap '[[ -z "$srv" ]] || kill "$srv" 2>/dev/null || true; rm -rf "$work"' EXIT
pass=0 fail=0
check() { if [[ "$2" == 0 ]]; then pass=$((pass + 1)); echo "ok   $1"; else fail=$((fail + 1)); echo "FAIL $1"; fi; }

py=${LH_MEMORY_PYTHON:-$HOME/.local/share/linux-hello/venv/bin/python}; [[ -x "$py" ]] || py=python3
if PYTHONPATH="$here" "$py" -B -m unittest -q test_lhmem > "$work/unit.log" 2>&1; then
  check "unit_tests_of_lhmem_pass ($(grep -Eo 'Ran [0-9]+ tests' "$work/unit.log"))" 0
else
  check "unit_tests_of_lhmem_pass" 1; cat "$work/unit.log"
fi

mkdir -p "$work/srv" "$work/repo" "$work/vault/Sub" "$work/vault/.obsidian"
python3 "$here/stub-ollama.py" "$work/srv" & srv=$!
for _ in $(seq 50); do [[ -s "$work/srv/port" ]] && break; sleep 0.1; done
port=$(cat "$work/srv/port")
export LH_MEMORY_DIR="$work/mem" LH_MEMORY_BACKEND=jsonl LH_EMBED_HOST="http://127.0.0.1:$port" \
  LH_EMBED_MODEL=hash-test
lm() { python3 "$here/lh-memory.py" "$@"; }

git -C "$work/repo" init -q -b main
printf 'pub fn record_uid() {}\n' > "$work/repo/lib.rs"
git -C "$work/repo" add -A
git -C "$work/repo" -c user.name=t -c user.email=t@example.org -c commit.gpgsign=false commit -q -m x
printf -- '---\nstatus: draft\ndate: 2026-01-02\n---\n# Policy\n\nCall `set_user_policy_verified` after record_uid.\n' > "$work/vault/Sub/Policy.md"
printf 'editor state about record_uid\n' > "$work/vault/.obsidian/x.md"
export LH_MEMORY_REPOS="public:$work/repo" LH_MEMORY_NOTES="$work/vault"

lm index > "$work/index.out" 2>&1
check "index_reports_the_repository_and_the_notes" "$(grep -q 'repo repo (public)' "$work/index.out" && grep -q 'notes vault (private)' "$work/index.out"; echo $?)"
check "private_notes_are_in_the_private_directory_only" "$(grep -q 'Policy.md' "$work/mem/private/rows.jsonl" && ! grep -q 'Policy.md' "$work/mem/public/rows.jsonl"; echo $?)"
check "the_vaults_editor_state_is_not_indexed" "$(! grep -q 'editor state' "$work/mem/private/rows.jsonl"; echo $?)"

LH_MEMORY_TIER=public lm query "record_uid" --clone "$work/repo" > "$work/q.out"
check "a_public_query_finds_the_code" "$(grep -q 'code | lib.rs' "$work/q.out"; echo $?)"
check "a_public_query_never_returns_the_notes" "$(! grep -q 'set_user_policy_verified' "$work/q.out"; echo $?)"
LH_MEMORY_TIER=private lm query "record_uid set_user_policy_verified" --clone "$work/repo" > "$work/q.out"
check "a_private_query_returns_the_notes_after_the_code" "$([[ "$(grep -n '^\[' "$work/q.out" | head -1 | grep -c 'code')" == 1 ]] && grep -q 'note | Sub/Policy.md' "$work/q.out"; echo $?)"
check "a_cited_name_the_repository_lacks_is_marked" "$(grep -q 'NOT IN REPOSITORY: set_user_policy_verified' "$work/q.out"; echo $?)"
check "the_note_status_and_date_are_shown" "$(grep -q '2026-01-02 | draft' "$work/q.out"; echo $?)"

lm index > "$work/index2.out" 2>&1
check "a_second_index_pass_changes_nothing" "$(grep -q 'added.: 0, .changed.: 0' "$work/index2.out"; echo $?)"
LH_MEMORY_TIER=public lm stats > "$work/stats.out"
check "stats_for_a_public_caller_do_not_mention_the_private_store" "$(! grep -q private "$work/stats.out"; echo $?)"

id=$(LH_MEMORY_TIER=public lm remember "an agent concluded x" --agent draft --run r1 --issue 1)
check "a_remembered_row_is_unverified_until_promoted" "$(LH_MEMORY_TIER=public lm query "agent concluded" | grep -q UNVERIFIED; echo $?)"
LH_MEMORY_TIER=public lm promote "$id" --by maintainer
check "a_promoted_row_loses_the_unverified_mark" "$(! LH_MEMORY_TIER=public lm query "agent concluded" | grep -q UNVERIFIED; echo $?)"

# The default location is the LanceDB volume, in its own directory (ADR-0019; the volume is a required
# mount, encrypted, and AnythingLLM mounts only its own subdirectory of it). Nothing is created here.
got=$(env -u LH_MEMORY_DIR python3 -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("lhm", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print(m.memory_dir())' "$here/lh-memory.py")
check "the_default_memory_directory_is_on_the_lancedb_volume" "$([[ "$got" == /var/lib/lancedb/knowledge ]]; echo $?)"
check "the_recall_helper_defaults_to_the_same_directory" "$(grep -q 'LH_MEMORY_DIR:-/var/lib/lancedb/knowledge' "$here/lh-memory.sh"; echo $?)"
check "the_example_config_defaults_to_the_same_directory" "$(grep -q '^LH_MEMORY_DIR=/var/lib/lancedb/knowledge' "$here/memory.env.example"; echo $?)"

if "$py" -c 'import lancedb' 2>/dev/null; then
  lmlance() { "$py" "$here/lh-memory.py" "$@"; }
  LH_MEMORY_DIR="$work/lance" LH_MEMORY_BACKEND=lancedb lmlance index > "$work/lance.out" 2>&1
  check "lancedb_backend_indexes_and_answers" "$(LH_MEMORY_DIR="$work/lance" LH_MEMORY_BACKEND=lancedb LH_MEMORY_TIER=public lmlance query record_uid | grep -q 'code | lib.rs'; echo $?)"
else
  echo "skip lancedb backend: lancedb is not installed (make memory-venv)"
fi

echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
