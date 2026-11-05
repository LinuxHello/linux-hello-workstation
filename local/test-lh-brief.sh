#!/usr/bin/env bash
# Tests for lh_brief_test_names in local/lh-brief.sh; needs bash and python3.
#
#   local/test-lh-brief.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=local/lh-brief.sh
source "$here/lh-brief.sh"

pass=0 fail=0
ok()  { pass=$((pass + 1)); echo "ok   $1"; }
nok() { fail=$((fail + 1)); echo "FAIL $1: $2"; }
expect() { # name, brief, expected names (one per line)
  local got; got=$(lh_brief_test_names "$2")
  if [[ "$got" == "$3" ]]; then ok "$1"; else nok "$1" "got [$(tr '\n' ' ' <<<"$got")]"; fi
}

# Shape of the #61 brief: keys named in a bullet's description are not tests (2026-11-05,
# Aider run 3 failed on face_requires_ir, require_hardware_tpm, require_second_credential).
b61='**Goal:** combine layers.

**Tests first** (in `restrict.rs`; names state the property):
- `conflicting_admin_files_resolve_to_most_restrictive`: `min_length` 8 vs 10; `face_requires_ir` false vs true; `require_hardware_tpm` and `require_second_credential` true.
- `key_set_in_one_layer_only_is_kept`: `a` sets `pin.expiry_days = 90`.
- `required_against_disallowed_is_a_conflict`: `uppercase` "required" vs "disallowed".

Build layers in tests with `parse_layer_from_toml_string`.

**Constraints:**
- `some_constraint_name` is not a test.'
expect keys_in_a_bullet_description_are_not_test_names "$b61" 'conflicting_admin_files_resolve_to_most_restrictive
key_set_in_one_layer_only_is_kept
required_against_disallowed_is_a_conflict'

# Shape of the #62 brief: "In `file`:" before the name, and nested bullets.
b62='**Tests first** (names state the property):
- In `defaults.rs`: `default_layer_matches_policy_semantics` (every value above).
- In `merge.rs`, with layers built by `parse_layer_from_toml` from TOML strings:
  - `no_layers_give_the_defaults`: `merge(&[], None)` gives `default_layer_value`.
  - `user_cannot_override_admin_setting`: admin `min_length = 4` gives `pin.min_length` managed.

**Constraints:** none.'
expect name_after_in_file_and_nested_bullets_are_test_names "$b62" 'default_layer_matches_policy_semantics
no_layers_give_the_defaults
user_cannot_override_admin_setting'

# Shape of the #38 brief: several names at the head of one bullet, or one before a parenthesis.
b38='**Tests first** (in `merge.rs`):
- `user_can_tighten_a_default`, `user_cannot_loosen_a_default`
- `user_cannot_override_admin_setting` (admin loosens `min_length` to 4, `lockout_attempts_value` unchanged)
- `pin_is_always_allowed` and `biometrics_disabled_leaves_only_pin`'
expect several_names_at_a_bullet_head_are_all_test_names "$b38" 'user_can_tighten_a_default
user_cannot_loosen_a_default
user_cannot_override_admin_setting
pin_is_always_allowed
biometrics_disabled_leaves_only_pin'

expect brief_without_tests_first_names_no_tests '**Goal:** `not_a_test_name` here.' ''

echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
