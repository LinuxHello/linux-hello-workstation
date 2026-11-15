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

# Shape of the #89 brief: a "### 3. Properties and tests first" heading, test fns in a code block.
b89='### 2. Files

- `crates/x/src/lib.rs`: the tests.

### 3. Properties and tests first

The property: names. Write both tests first.

```rust
#[test]
fn agent_names_use_the_reserved_prefix() {
    assert!(true);
}

#[test]
fn agent_names_are_the_ones_in_adr_0012() {
    assert!(true);
}
```

Keep `object_path_matches_bus_name` as it is.

### 4. Constraints

- `some_constraint_name` is not a test.'
expect heading_with_tests_first_and_fns_in_a_code_block "$b89" 'agent_names_use_the_reserved_prefix
agent_names_are_the_ones_in_adr_0012'

# Shape of the #95 brief: the same heading, tests as bullets, for a shell test file.
b95='### 3. Properties and tests first

Then one `check` line per case:

- `docs_only_change_is_docs`: `rust=false` for `docs/adr/0001-x.md`.
- `any_code_path_is_code`: `rust=true` for each of `Cargo.lock`, `architecture`.

### 4. Constraints

- `fail_closed_rule` is not a test.'
expect heading_with_bullet_names_for_a_shell_test_file "$b95" 'docs_only_change_is_docs
any_code_path_is_code'

# A bold paragraph inside a headed tests section must not end it (the live brief for #103 lost all its
# test names that way and the named-tests gate checked nothing).
bold='### 3. Properties and tests first

**Building a value.** A note in bold before the list.

- `first_named_test`: does one thing.
- `second_named_test`: does another.

**Another bold note** after the list.

- `third_named_test`: still in the section.

### 4. Constraints

- `not_a_test_name` is a constraint.'
expect bold_paragraphs_do_not_end_a_headed_section "$bold" 'first_named_test
second_named_test
third_named_test'

expect brief_without_tests_first_names_no_tests '**Goal:** `not_a_test_name` here.' ''

# lh_tests_in_diff: Rust fn, shell function and quoted case name are found; a mere mention is not.
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
( cd "$work" && git init -q -b main && git config user.email a@b && git config user.name n \
  && echo base > f && git add f && git commit -qm base && git update-ref refs/remotes/origin/main HEAD \
  && printf '%s\n' 'fn rust_test_name() {}' 'shell_test_name() {' 'check "quoted_case_name" x' '// mentions only_mentioned_name' > t.txt ) >/dev/null
got=$(cd "$work" && lh_tests_in_diff found "rust_test_name shell_test_name quoted_case_name only_mentioned_name")
if [[ "$got" == "rust_test_name shell_test_name quoted_case_name" ]]; then ok fn_function_and_quoted_names_are_found
else nok fn_function_and_quoted_names_are_found "got [$got]"; fi
got=$(cd "$work" && lh_tests_in_diff missing "rust_test_name only_mentioned_name absent_name")
if [[ "$got" == "only_mentioned_name absent_name" ]]; then ok a_mention_or_absence_is_missing
else nok a_mention_or_absence_is_missing "got [$got]"; fi

# A placeholder that already exists and is enabled (its #[ignore] removed, the fn line unchanged) counts;
# one that stays ignored does not.
( cd "$work" && git checkout -q -- . 2>/dev/null; git clean -fdq
  printf '%s\n' '/// P-04' '#[test]' '#[ignore = "placeholder"]' 'fn enabled_placeholder_name() {' '    unimplemented!();' '}' '' '#[test]' '#[ignore = "placeholder"]' 'fn still_ignored_name() {' '    unimplemented!();' '}' > ph.rs
  git add ph.rs && git commit -qm placeholders && git update-ref refs/remotes/origin/main HEAD
  printf '%s\n' '/// P-04' '#[test]' 'fn enabled_placeholder_name() {' '    assert!(true);' '}' '' '#[test]' '#[ignore = "placeholder"]' 'fn still_ignored_name() {' '    unimplemented!();' '}' > ph.rs ) >/dev/null 2>&1
got=$(cd "$work" && lh_tests_in_diff found "enabled_placeholder_name still_ignored_name")
if [[ "$got" == "enabled_placeholder_name" ]]; then ok an_enabled_placeholder_counts_and_an_ignored_one_does_not
else nok an_enabled_placeholder_counts_and_an_ignored_one_does_not "got [$got]"; fi

# lh_deleted_tests: a removed or renamed test is reported; an edited one and a new one are not.
( cd "$work" && git checkout -q -- . 2>/dev/null; git clean -fdq
  printf '%s\n' '#[test]' '#[ignore = "p"]' 'fn kept_placeholder() {}' '' '#[test]' '#[ignore = "p"]' 'fn removed_placeholder() {}' '' '#[test]' 'fn renamed_old() {}' '' '#[test]' 'fn edited() { assert!(true); }' '' 'fn helper() {}' > dt.rs
  git add dt.rs && git commit -qm dt && git update-ref refs/remotes/origin/main HEAD
  printf '%s\n' '#[test]' '#[ignore = "p"]' 'fn kept_placeholder() {}' '' '#[test]' 'fn renamed_new() {}' '' '#[test]' 'fn edited() { assert!(false || true); }' '' '#[test]' 'fn added() {}' > dt.rs ) >/dev/null 2>&1
got=$(cd "$work" && lh_deleted_tests)
if [[ "$got" == "removed_placeholder renamed_old" ]]; then ok removed_and_renamed_tests_are_reported_but_edited_and_new_are_not
else nok removed_and_renamed_tests_are_reported_but_edited_and_new_are_not "got [$got]"; fi

# The bold-key form the lead writes: "**Properties and tests first.**" (a trailing period or colon is allowed),
# ended by the next bold key. #132's brief used it, so the harness saw no test names (2026-11-14).
b_bold=$'## Implementation brief\n\n**Goal.** Do it.\n\n**Properties and tests first.**\n\n- `secrets_never_appear_in_logs_errors_or_audit`: enabled and real.\n- `every_unlock_signature_pin_change_and_reset_is_audited`: enabled for the events that exist.\n\n**Constraints (quoted):**\n\n- `not_a_test_name` is a key.\n'
expect a_bold_key_properties_and_tests_first_is_found "$b_bold" $'secrets_never_appear_in_logs_errors_or_audit\nevery_unlock_signature_pin_change_and_reset_is_audited'
b_colon=$'## Implementation brief\n\n**Properties and tests first:**\n\n- `a_test_with_a_colon`: x\n\n**Files:**\n\n- `src/x.rs`\n'
expect a_bold_key_with_a_colon_is_found "$b_colon" "a_test_with_a_colon"

# lh_brief_files: the files the brief lets the implementer edit. The forms the lead writes: "**Files:**", a
# "### 2. Files" heading, and a bold key that goes on after "Files" ("**Files (at most three, all listed):**",
# #132, 2026-11-14: the implementer found 0 files and failed twice, which counts toward blocking the issue).
files_of() { ( cd "$work" && lh_brief_files "$1" | tr '\n' ' ' ); }
f_plain=$'## Implementation brief\n**Files:**\n- `crates/a/src/x.rs`: one\n- `docs/y.md`: two\n\n**Properties and tests first.**\n- `some_test_name_here`: a\n'
f_head=$'## Implementation brief\n### 2. Files\n\n- `crates/a/src/x.rs`: one\n- Never edit `crates/other/z.yml`.\n\n### 3. Properties and tests first\n'
f_paren=$'## Implementation brief\n\n**Files (at most three, all listed):**\n\n1. `crates/a/tests/p.rs` — the placeholders.\n2. `docs/security/properties.md` — two rows.\n3. `crates/a/src/audit.rs` — doc comments only.\n\n**Properties and tests first.**\n\n- `a_test_name_here`: x\n'
f_unit=$'## Implementation brief\n### 2. Files\n\n- `security/systemd/a.service`: lines\n- `security/dbus/io.x.Agent1.service` (new): the activation file\n- `security/dbus/p.conf`: policy\n- `crates/a/tests/p.rs`: tests\n\n### 3. Properties and tests first\n'
f_none=$'## Implementation brief\n**Goal.** Do it.\n'
[[ "$(files_of "$f_plain")" == "crates/a/src/x.rs docs/y.md " ]] && ok files_after_a_plain_bold_key_are_found || nok files_after_a_plain_bold_key_are_found "got [$(files_of "$f_plain")]"
[[ "$(files_of "$f_head")" == "crates/a/src/x.rs " ]] && ok files_under_a_heading_are_found_and_a_prose_mention_is_not || nok files_under_a_heading_are_found_and_a_prose_mention_is_not "got [$(files_of "$f_head")]"
[[ "$(files_of "$f_paren")" == "crates/a/tests/p.rs docs/security/properties.md crates/a/src/audit.rs " ]] && ok files_after_a_bold_key_with_words_and_a_numbered_list_are_found || nok files_after_a_bold_key_with_words_and_a_numbered_list_are_found "got [$(files_of "$f_paren")]"
[[ "$(files_of "$f_unit")" == "security/systemd/a.service security/dbus/io.x.Agent1.service security/dbus/p.conf crates/a/tests/p.rs " ]] && ok unit_activation_and_conf_files_are_found_as_editable_files || nok unit_activation_and_conf_files_are_found_as_editable_files "got [$(files_of "$f_unit")]"
[[ -z "$(files_of "$f_none")" ]] && ok a_brief_without_a_files_section_has_no_files || nok a_brief_without_a_files_section_has_no_files "got [$(files_of "$f_none")]"

# lh_brief_already_implemented: true only when every test the brief names is already on main and none of
# them is an ignored placeholder (enabling a placeholder is work to do). Such a brief describes work that
# merged; running the implementer on it only finds nothing to change (#132, 2026-11-14).
( cd "$work" && git checkout -q -- . 2>/dev/null; git clean -fdq
  printf '%s\n' '#[test]' 'fn already_done_one() {}' '' '#[test]' 'fn already_done_two() {}' '' '#[test]' '#[ignore = "p"]' 'fn open_placeholder_one() {}' > ai.rs
  git add ai.rs && git commit -qm ai && git update-ref refs/remotes/origin/main HEAD ) >/dev/null 2>&1
b_all=$'## Implementation brief\n### 3. Properties and tests first\n- `already_done_one`: a\n- `already_done_two`: b\n'
b_mix=$'## Implementation brief\n### 3. Properties and tests first\n- `already_done_one`: a\n- `brand_new_test`: b\n'
b_ph=$'## Implementation brief\n### 3. Properties and tests first\n- `open_placeholder_one`: enable it\n'
b_none=$'## Implementation brief\n### 1. Goal\nDo it.\n'
implemented() { ( cd "$work" && lh_brief_already_implemented "$1" ); }
if implemented "$b_all"; then ok a_brief_whose_tests_all_exist_on_main_is_already_implemented; else nok a_brief_whose_tests_all_exist_on_main_is_already_implemented "returned 1"; fi
if ! implemented "$b_mix"; then ok a_brief_with_one_new_test_is_not_implemented; else nok a_brief_with_one_new_test_is_not_implemented "returned 0"; fi
if ! implemented "$b_ph"; then ok a_brief_that_enables_an_ignored_placeholder_is_not_implemented; else nok a_brief_that_enables_an_ignored_placeholder_is_not_implemented "returned 0"; fi
if ! implemented "$b_none"; then ok a_brief_naming_no_tests_is_never_called_implemented; else nok a_brief_naming_no_tests_is_never_called_implemented "returned 0"; fi
if ! LH_ALLOW_EXISTING_TESTS=1 implemented "$b_all"; then ok LH_ALLOW_EXISTING_TESTS_turns_the_check_off; else nok LH_ALLOW_EXISTING_TESTS_turns_the_check_off "returned 0"; fi

echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
