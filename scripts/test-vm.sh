#!/usr/bin/env bash
# Tests for scripts/vm.sh that need neither a network nor KVM: usage, status, refusals, reset.
#
#   scripts/test-vm.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
dir="$(mktemp -d)"; trap 'rm -rf "$dir"' EXIT
export LH_VM_DIR="$dir/vm"
pass=0 fail=0
ok()  { pass=$((pass + 1)); echo "ok   $1"; }
nok() { fail=$((fail + 1)); echo "FAIL $1: $2"; }

out=$(bash "$here/vm.sh" 2>&1) && ok no_argument_prints_usage_and_succeeds || nok no_argument_prints_usage_and_succeeds "$out"
grep -q 'scripts/vm.sh up' <<<"$out" && ok usage_lists_the_commands || nok usage_lists_the_commands "$out"

rc=0; bash "$here/vm.sh" frobnicate >/dev/null 2>&1 || rc=$?
[[ $rc -eq 2 ]] && ok unknown_command_exits_2 || nok unknown_command_exits_2 "exit $rc"

out=$(bash "$here/vm.sh" status 2>&1)
grep -q '^stopped' <<<"$out" && grep -q 'not downloaded' <<<"$out" && ok status_of_a_fresh_directory || nok status_of_a_fresh_directory "$out"

rc=0; out=$(bash "$here/vm.sh" up 2>&1) || rc=$?
[[ $rc -ne 0 ]] && ok up_without_an_image_is_refused || nok up_without_an_image_is_refused "exit $rc: $out"
grep -qE 'no image|not installed' <<<"$out" && ok the_refusal_says_why || nok the_refusal_says_why "$out"

rc=0; out=$(bash "$here/vm.sh" ssh true 2>&1) || rc=$?
[[ $rc -ne 0 ]] && grep -q 'not running' <<<"$out" && ok ssh_when_stopped_is_refused || nok ssh_when_stopped_is_refused "exit $rc: $out"

mkdir -p "$LH_VM_DIR/tpm"; touch "$LH_VM_DIR/disk.qcow2" "$LH_VM_DIR/ubuntu-24.04-server-cloudimg-amd64.img"
bash "$here/vm.sh" reset >/dev/null 2>&1
if [[ ! -e "$LH_VM_DIR/disk.qcow2" && ! -d "$LH_VM_DIR/tpm" && -e "$LH_VM_DIR/ubuntu-24.04-server-cloudimg-amd64.img" ]]; then
  ok reset_removes_the_disk_and_tpm_state_but_keeps_the_image
else nok reset_removes_the_disk_and_tpm_state_but_keeps_the_image "$(ls "$LH_VM_DIR")"; fi

# The cloud images are signed with the cloud-image key. The archive keyring cannot verify them
# (vm-image failed on that on 2026-11-08), so the script must name the cloud-image keyring.
if grep -q 'keyrings/ubuntu-cloudimage-keyring.gpg' "$here/vm.sh" && ! grep -q 'keyrings/ubuntu-archive-keyring.gpg' "$here/vm.sh"; then
  ok signature_is_checked_against_the_cloud_image_keyring
else nok signature_is_checked_against_the_cloud_image_keyring "vm.sh names the wrong keyring"; fi

echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
