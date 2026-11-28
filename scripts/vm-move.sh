#!/usr/bin/env bash
# Moves every test VM to another root directory, for example to a disk with more room, and makes
# the new root the configured one:
#
#   scripts/vm-move.sh /srv/vm/linux-hello      (or: make vm-move TO=/srv/vm/linux-hello)
#
# It moves each VM directory under the current root (scripts/vm-config.sh root), every
# linux-hello-vm* directory, to the same name under the new root. A VM's disk records the absolute
# path of the image it was made on (and the desktop VM's image that of the 26.04 image), so after
# the move each disk and image that points into the old root is pointed at the same file in the
# new one (qemu-img rebase -u, which changes only that path). Last it writes LH_VM_ROOT=<new root>
# into the configuration file (~/.config/linux-hello/vm.env), keeping its other lines.
#
# Refuses, before anything moves, when a VM is running (scripts/vm.sh down first), when a VM's
# name is already taken under the new root, or when the new root is not an absolute path. A move
# to another file system copies first and removes the old directory only after the copy.
# Needs qemu-img.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/../common.sh"
source "$here/vm-config.sh"

to="${1:?usage: scripts/vm-move.sh /new/root}"
[[ "$to" == /* ]] || die "the new root must be an absolute path, not '$to'"
to="${to%/}"
from="${LH_VM_ROOT%/}"
command -v qemu-img >/dev/null || die "qemu-img not installed (sudo apt install qemu-utils)"

alive() { [[ -f "$1" ]] && kill -0 "$(cat "$1")" 2>/dev/null; }

shopt -s nullglob
vms=()
for dir in "$from"/linux-hello-vm*/; do vms+=("$(basename "$dir")"); done

if [[ "$from" != "$to" ]]; then
  for name in "${vms[@]}"; do
    if alive "$from/$name/qemu.pid" || alive "$from/$name/swtpm.pid"; then
      die "$name is running: stop it first (LH_VM_NAME=$name scripts/vm.sh down)"
    fi
    [[ ! -e "$to/$name" ]] || die "$to/$name exists already; nothing was moved"
  done
  mkdir -p "$to" 2>/dev/null || die "cannot create $to: sudo install -d -o $USER $to"
  [[ -w "$to" ]] || die "$to is not writable for you: sudo chown $USER $to"
  for name in "${vms[@]}"; do
    log "moving $name ($(du -sh "$from/$name" | cut -f1)) to $to"
    mv "$from/$name" "$to/$name"
  done
  for name in "${vms[@]}"; do
    for file in "$to/$name"/*.qcow2 "$to/$name"/*.img; do
      backing="$(qemu-img info -U "$file" 2>/dev/null | sed -n 's/^backing file: //p' | sed 's/ (actual path: .*)$//')"
      [[ "$backing" == "$from"/* ]] || continue
      new="$to/${backing#"$from"/}"
      [[ -f "$new" ]] || die "$file is made on $backing, which is not at $new after the move"
      qemu-img rebase -u -F qcow2 -b "$new" "$file"
      log "$file now points at $new"
    done
  done
fi

conf="$(lh_vm_conf_file)"
mkdir -p "$(dirname "$conf")"
if [[ -f "$conf" ]] && grep -q '^[[:space:]]*LH_VM_ROOT[[:space:]]*=' "$conf"; then
  sed -i "s#^[[:space:]]*LH_VM_ROOT[[:space:]]*=.*#LH_VM_ROOT=$to#" "$conf"
else
  printf '# Where the Linux Hello test VMs live (scripts/vm-config.sh).\nLH_VM_ROOT=%s\n' "$to" >> "$conf"
fi
log "$conf: LH_VM_ROOT=$to"
if [[ "$from" == "$to" ]]; then log "the VMs are already in $to"; else log "moved ${#vms[@]} VM(s): ${vms[*]:-none}"; fi
