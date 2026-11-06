#!/usr/bin/env bash
# Tests for lh_duplicated_files in local/lh-guard.sh; needs bash.
#
#   local/test-lh-guard.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=local/lh-guard.sh
source "$here/lh-guard.sh"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
pass=0 fail=0
expect() { # name, expected output, files...
  local name="$1" want="$2" got; shift 2
  got=$(lh_duplicated_files "$@")
  if [[ "$got" == "$want" ]]; then pass=$((pass + 1)); echo "ok   $name"
  else fail=$((fail + 1)); echo "FAIL $name: got [$got]"; fi
}

one='//! Queries on a loaded policy.
//!
//! More docs.

pub fn f() {}
'
printf '%s' "$one" >"$work/single.rs"
printf '%s%s' "$one" "$one" >"$work/appended.rs"
printf '%s\n%s%s' "$one" "$one" "$one" >"$work/three.rs"
printf 'use std::fs;\nuse std::fs;\n' >"$work/no_header.rs"
printf '%s// //! Queries on a loaded policy.\n' "$one" >"$work/header_quoted.rs"

expect single_copy_passes "" "$work/single.rs"
expect file_appended_to_itself_is_reported "$work/appended.rs" "$work/appended.rs"
expect three_copies_are_reported "$work/three.rs" "$work/three.rs"
expect file_without_module_header_is_not_checked "" "$work/no_header.rs"
expect header_text_inside_a_line_is_not_a_copy "" "$work/header_quoted.rs"
expect missing_file_is_skipped "" "$work/absent.rs"
expect only_the_duplicated_files_are_listed "$work/appended.rs" \
  "$work/single.rs" "$work/appended.rs" "$work/absent.rs"

echo "$pass passed, $fail failed"
[[ "$fail" == 0 ]]
