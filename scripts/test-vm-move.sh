#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034 # the checks are strings that check() evals, which read rc and out
# Tests for scripts/vm-config.sh (where the VMs live) and scripts/vm-move.sh (moving them), with
# small qcow2 files in a temporary directory: no network, no KVM. Needs qemu-img.
#
#   scripts/test-vm-move.sh
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
pass=0 fail=0
ok()  { pass=$((pass + 1)); echo "ok   $1"; }
nok() { fail=$((fail + 1)); echo "FAIL $1: $2"; }
check() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else nok "$1" "$2"; fi; }
command -v qemu-img >/dev/null || { echo "qemu-img not installed (sudo apt install qemu-utils)"; exit 1; }

export HOME="$work/home" XDG_CONFIG_HOME="" XDG_DATA_HOME=""
unset LH_VM_ROOT LH_VM_CONF LH_VM_DIR LH_VM_NAME
conf="$HOME/.config/linux-hello/vm.env"
mkdir -p "$HOME"
root() { bash "$here/vm-config.sh" root; }

check "without_a_config_the_root_is_local_share" '[ "$(root)" = "$HOME/.local/share" ]'
mkdir -p "$(dirname "$conf")"
printf '# a comment\nLH_VM_ROOT=/srv/vm/lh\n' > "$conf"
check "the_config_file_sets_the_root" '[ "$(root)" = /srv/vm/lh ]'
printf 'LH_VM_ROOT = "/srv/vm/quoted"  \n' > "$conf"
check "quotes_and_blanks_around_the_value_are_dropped" '[ "$(root)" = /srv/vm/quoted ]'
check "the_environment_overrides_the_config" '[ "$(LH_VM_ROOT=/other bash "$here/vm-config.sh" root)" = /other ]'
printf 'LH_VM_ROOT=relative/dir\n' > "$conf"
check "a_relative_root_is_refused" '! root'
printf 'LH_VM_ROOT=$(touch %s/ran)\n' "$work" > "$conf"
root >/dev/null 2>&1
check "the_config_file_is_not_run" '[ ! -e "$work/ran" ]'
printf 'LH_VM_ROOT=/srv/vm/lh\n' > "$conf"
check "vm_sh_puts_a_vm_under_the_root_by_its_name" 'LH_VM_NAME=linux-hello-vm-2604 bash "$here/vm.sh" status | grep -qx "directory: /srv/vm/lh/linux-hello-vm-2604"'
check "vm_sh_default_name_is_linux_hello_vm" 'bash "$here/vm.sh" status | grep -qx "directory: /srv/vm/lh/linux-hello-vm"'
check "an_explicit_lh_vm_dir_still_wins" 'LH_VM_DIR=/elsewhere/vm bash "$here/vm.sh" status | grep -qx "directory: /elsewhere/vm"'
check "the_makefile_uses_the_root" '[ "$(make -s -C "$here/.." vm-root VM_RELEASE=26.04 | cut -d" " -f1)" = /srv/vm/lh ]'

# Two VMs under the old root: a 24.04 VM whose disk is made on its image, and a desktop VM whose
# image is itself made on the 26.04 VM's image, as the real desktop VM is.
old="$work/old" new="$work/new"
printf 'LH_VM_ROOT=%s\nOTHER=kept\n' "$old" > "$conf"
mkdir -p "$old/linux-hello-vm" "$old/linux-hello-vm-2604" "$old/linux-hello-vm-2604-desktop" "$old/linux-hello"
qemu-img create -q -f qcow2 "$old/linux-hello-vm/ubuntu-24.04-server-cloudimg-amd64.img" 16M
qemu-img create -q -f qcow2 -b "$old/linux-hello-vm/ubuntu-24.04-server-cloudimg-amd64.img" -F qcow2 "$old/linux-hello-vm/disk.qcow2" 32M
qemu-img create -q -f qcow2 "$old/linux-hello-vm-2604/ubuntu-26.04-server-cloudimg-amd64.img" 16M
qemu-img create -q -f qcow2 -b "$old/linux-hello-vm-2604/ubuntu-26.04-server-cloudimg-amd64.img" -F qcow2 "$old/linux-hello-vm-2604-desktop/ubuntu-26.04-server-cloudimg-amd64.img" 16M
qemu-img create -q -f qcow2 -b "$old/linux-hello-vm-2604-desktop/ubuntu-26.04-server-cloudimg-amd64.img" -F qcow2 "$old/linux-hello-vm-2604-desktop/disk.qcow2" 32M
mkdir -p "$old/linux-hello-vm/tpm"; echo state > "$old/linux-hello-vm/tpm/tpm2-00.permall"

# A running VM: a pid file with a live process.
sleep 30 & live=$!
echo "$live" > "$old/linux-hello-vm/qemu.pid"
check "a_running_vm_is_refused" '! bash "$here/vm-move.sh" "$new"'
check "and_nothing_moved" '[ -d "$old/linux-hello-vm" ] && [ ! -e "$new/linux-hello-vm" ]'
kill "$live" 2>/dev/null; wait "$live" 2>/dev/null; rm -f "$old/linux-hello-vm/qemu.pid"

mkdir -p "$new/linux-hello-vm-2604"
check "a_name_taken_under_the_new_root_is_refused" '! bash "$here/vm-move.sh" "$new"'
check "and_nothing_moved_either" '[ -d "$old/linux-hello-vm" ] && [ ! -e "$new/linux-hello-vm" ]'
rmdir "$new/linux-hello-vm-2604"

check "a_relative_new_root_is_refused" '! bash "$here/vm-move.sh" relative/new'

bash "$here/vm-move.sh" "$new" >/dev/null 2>&1; rc=$?
check "the_move_succeeds" '[ $rc -eq 0 ]'
check "every_vm_directory_is_under_the_new_root" '[ -d "$new/linux-hello-vm" ] && [ -d "$new/linux-hello-vm-2604" ] && [ -d "$new/linux-hello-vm-2604-desktop" ]'
check "the_old_vm_directories_are_gone" '[ ! -e "$old/linux-hello-vm" ] && [ ! -e "$old/linux-hello-vm-2604-desktop" ]'
check "a_directory_that_is_not_a_vm_stays" '[ -d "$old/linux-hello" ] && [ ! -e "$new/linux-hello" ]'
check "the_tpm_state_moved_with_its_vm" 'grep -qx state "$new/linux-hello-vm/tpm/tpm2-00.permall"'
check "the_disk_points_at_its_image_in_the_new_root" 'qemu-img info "$new/linux-hello-vm/disk.qcow2" | grep -qx "backing file: $new/linux-hello-vm/ubuntu-24.04-server-cloudimg-amd64.img"'
check "the_whole_desktop_chain_opens_from_the_new_root" 'qemu-img info --backing-chain "$new/linux-hello-vm-2604-desktop/disk.qcow2" >/dev/null && ! qemu-img info --backing-chain "$new/linux-hello-vm-2604-desktop/disk.qcow2" | grep -q "$old"'
check "the_config_names_the_new_root" '[ "$(root)" = "$new" ]'
check "the_config_keeps_its_other_lines" 'grep -qx OTHER=kept "$conf"'
check "vm_sh_finds_the_moved_vm" 'bash "$here/vm.sh" status | grep -qv "not downloaded"'

out="$(bash "$here/vm-move.sh" "$new" 2>&1)"
check "moving_to_the_same_root_changes_nothing" 'grep -q "already in" <<<"$out" && [ -d "$new/linux-hello-vm" ]'

echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
