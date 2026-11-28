#!/usr/bin/env bash
# Where the test VMs live. Every VM has a directory of its own (image, disk, TPM state, ssh key)
# under one root directory, named after the VM:
#
#   <root>/linux-hello-vm                Ubuntu 24.04
#   <root>/linux-hello-vm-2604           Ubuntu 26.04
#   <root>/linux-hello-vm-2604-desktop   Ubuntu 26.04 with Plasma
#
# The root is, in this order: $LH_VM_ROOT from the environment; LH_VM_ROOT in the configuration
# file ${LH_VM_CONF:-${XDG_CONFIG_HOME:-~/.config}/linux-hello/vm.env}; ~/.local/share. The VMs
# take tens of GB, so put the root on a disk with room, for example:
#
#   mkdir -p ~/.config/linux-hello && echo 'LH_VM_ROOT=/srv/vm/linux-hello' > ~/.config/linux-hello/vm.env
#
# The file is read, not run: only lines LH_VM_ROOT=<absolute path> count, and a relative path or
# any other value stops with an error. scripts/vm-move.sh moves VMs that already exist.
# A root outside the home directory needs one line for swtpm's AppArmor profile, which otherwise
# lets the TPM emulator write under the home directory only (vm.sh up prints the two commands).
#
#   source scripts/vm-config.sh     sets LH_VM_ROOT (vm.sh and the other scripts do this)
#   scripts/vm-config.sh root       prints it (the Makefile uses this)

# lh_vm_conf_file: the configuration file's path.
lh_vm_conf_file() { printf '%s\n' "${LH_VM_CONF:-${XDG_CONFIG_HOME:-$HOME/.config}/linux-hello/vm.env}"; }

# lh_vm_root: prints the root directory, or fails with a message on a bad configuration file.
lh_vm_root() {
  if [[ -n "${LH_VM_ROOT:-}" ]]; then printf '%s\n' "$LH_VM_ROOT"; return 0; fi
  local conf value=
  conf="$(lh_vm_conf_file)"
  if [[ -f "$conf" ]]; then
    value="$(sed -n 's/^[[:space:]]*LH_VM_ROOT[[:space:]]*=[[:space:]]*//p' "$conf" | tail -1)"
    value="${value%"${value##*[![:space:]]}"}"   # trailing blanks
    value="${value#[\"\']}"; value="${value%[\"\']}"   # one pair of quotes
    value="${value/#\~/$HOME}"
    if [[ -n "$value" && "$value" != /* ]]; then
      echo "ERROR: LH_VM_ROOT in $conf must be an absolute path, not '$value'" >&2
      return 1
    fi
  fi
  printf '%s\n' "${value:-${XDG_DATA_HOME:-$HOME/.local/share}}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    root) lh_vm_root ;;
    conf) lh_vm_conf_file ;;
    *) sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'; [[ -z "${1:-}" ]] ;;
  esac
else
  LH_VM_ROOT="$(lh_vm_root)" || exit 1
fi
