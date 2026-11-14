# shellcheck shell=bash
# Checks the model's edits between rounds; sourced, not run. Tested by local/test-lh-guard.sh.
#
#   lh_duplicated_files <file>...    the files that hold a second copy of themselves, one per line
#
# Aider's diff format creates a file from an edit block with an empty SEARCH section; when the
# model resends an existing file that way, Aider appends it to the file instead of refusing.
# That left query.rs as three copies of itself on #40, merge.rs twice on #62 and restrict.rs
# appended to itself on #61 (2026-11-05). A repair round never recovered: the duplicate's
# compile errors went back into the prompt (123k tokens for a 64k window on #40).
# Trace of a copy: the file's first line, a Rust module's "//!" header, appears again later.
# Files that are missing or do not start with "//!" are not checked.

lh_duplicated_files() {
  local f first
  for f in "$@"; do
    [[ -f "$f" ]] || continue
    first=$(head -n 1 -- "$f")
    [[ "$first" == '//!'* ]] || continue
    if (( $(grep -cxF -- "$first" "$f") > 1 )); then printf '%s\n' "$f"; fi
  done
}
