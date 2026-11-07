#!/usr/bin/env bash
# A disposable Ubuntu VM with an emulated TPM, for tests that must not touch this workstation:
# the virtual CTAP authenticator (uhid, spike 0094/#94), wrong-PIN and reset tests that would
# lock a hardware TPM (dictionary-attack lockout, ADR-0003), and anything that needs root.
#
#   scripts/vm.sh image    download and verify the Ubuntu 24.04 cloud image (once; ~600 MB)
#   scripts/vm.sh up       create a fresh disk on top of it and boot the VM; waits for ssh
#   scripts/vm.sh ssh [cmd ...]   log in (or run one command) as user lh
#   scripts/vm.sh sync     copy the linux-hello clone ($CLONE_DIR) into ~/linux-hello in the VM
#   scripts/vm.sh reset    shut down and throw the disk and the TPM state away
#   scripts/vm.sh down     shut down, keeping the disk and the TPM state
#   scripts/vm.sh status
#
# Ubuntu 24.04 is the release CI runs on. The VM has KVM, 4 CPUs, 4 GiB, a TPM 2.0 from swtpm
# (the guest sees /dev/tpm0 and /dev/tpmrm0) and a user-mode network: ssh on 127.0.0.1:$LH_VM_SSH_PORT
# only, no inbound access from the LAN. Everything lives in $LH_VM_DIR; nothing outside it changes.
# Needs: qemu-system-x86, qemu-utils, swtpm, cloud-image-utils (cloud-localds), openssh-client,
# rsync, curl, gpg (the image checksums are verified against Canonical's signing key when the
# ubuntu-keyring package is present; cloud images are signed with the cloud-image key, not the archive key).
set -euo pipefail
source "$(dirname "$0")/../common.sh"

: "${LH_VM_DIR:=${XDG_DATA_HOME:-$HOME/.local/share}/linux-hello-vm}"
: "${LH_VM_SSH_PORT:=2222}"
: "${LH_VM_CPUS:=4}"
: "${LH_VM_MEM:=4096}"
: "${LH_VM_RELEASE:=24.04}"
base_url="https://cloud-images.ubuntu.com/releases/$LH_VM_RELEASE/release"
base_img="$LH_VM_DIR/ubuntu-$LH_VM_RELEASE-server-cloudimg-amd64.img"
disk="$LH_VM_DIR/disk.qcow2"
seed="$LH_VM_DIR/seed.iso"
key="$LH_VM_DIR/id_ed25519"
tpm_dir="$LH_VM_DIR/tpm"
pidfile="$LH_VM_DIR/qemu.pid"
tpm_pidfile="$LH_VM_DIR/swtpm.pid"

need() { command -v "$1" >/dev/null || die "$1 not installed ($2)"; }
running() { [[ -f "$pidfile" ]] && kill -0 "$(cat "$pidfile")" 2>/dev/null; }
ssh_opts=(-i "$key" -p "$LH_VM_SSH_PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o LogLevel=ERROR -o ConnectTimeout=5)

cmd_image() {
  need curl "sudo apt install curl"; need sha256sum "coreutils"
  mkdir -p "$LH_VM_DIR"
  local name; name="$(basename "$base_img")"
  log "fetching the checksums for $name"
  curl --proto '=https' --tlsv1.2 -fsSL "$base_url/SHA256SUMS" -o "$LH_VM_DIR/SHA256SUMS"
  if [[ -f /usr/share/keyrings/ubuntu-cloudimage-keyring.gpg ]] && command -v gpgv >/dev/null; then
    curl --proto '=https' --tlsv1.2 -fsSL "$base_url/SHA256SUMS.gpg" -o "$LH_VM_DIR/SHA256SUMS.gpg"
    gpgv --keyring /usr/share/keyrings/ubuntu-cloudimage-keyring.gpg "$LH_VM_DIR/SHA256SUMS.gpg" "$LH_VM_DIR/SHA256SUMS" 2>/dev/null \
      || die "the signature on SHA256SUMS does not verify; not using this download"
    log "SHA256SUMS signature verified"
  else
    log "no ubuntu-cloudimage-keyring or gpgv: the checksum comes over HTTPS only (sudo apt install ubuntu-keyring gpgv)"
  fi
  want="$(awk -v n="*$name" '$2 == n {print $1}' "$LH_VM_DIR/SHA256SUMS")"
  [[ -n "$want" ]] || die "$name is not in SHA256SUMS"
  if [[ -f "$base_img" ]] && [[ "$(sha256sum "$base_img" | cut -d' ' -f1)" == "$want" ]]; then
    log "$base_img is present and matches"; return 0
  fi
  log "downloading $base_url/$name"
  curl --proto '=https' --tlsv1.2 -fL --progress-bar "$base_url/$name" -o "$base_img.part"
  [[ "$(sha256sum "$base_img.part" | cut -d' ' -f1)" == "$want" ]] || { rm -f "$base_img.part"; die "checksum mismatch; download discarded"; }
  mv "$base_img.part" "$base_img"
  log "image ready: $base_img"
}

cmd_up() {
  need qemu-system-x86_64 "sudo apt install qemu-system-x86"; need qemu-img "sudo apt install qemu-utils"
  need swtpm "sudo apt install swtpm swtpm-tools"; need cloud-localds "sudo apt install cloud-image-utils"
  need ssh "sudo apt install openssh-client"
  [[ -f "$base_img" ]] || die "no image: run scripts/vm.sh image first"
  [[ -r /dev/kvm && -w /dev/kvm ]] || die "/dev/kvm is not accessible to $USER (add yourself to the kvm group)"
  running && { log "already running (ssh port $LH_VM_SSH_PORT)"; return 0; }
  mkdir -p "$LH_VM_DIR" "$tpm_dir"
  [[ -f "$key" ]] || ssh-keygen -q -t ed25519 -N '' -C linux-hello-vm -f "$key"
  if [[ ! -f "$disk" ]]; then
    log "creating a fresh 20 GiB disk on top of the image"
    qemu-img create -q -f qcow2 -b "$base_img" -F qcow2 "$disk" 20G
    cat >"$LH_VM_DIR/user-data" <<EOF
#cloud-config
users:
  - name: lh
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - $(cat "$key.pub")
package_update: true
packages: [build-essential, pkg-config, libtss2-dev, clang, libclang-dev, tpm2-tools, rsync, git, curl, udev]
# The cloud image's kernel has no uhid module; it is in linux-modules-extra (found on the first boot, 2026-11-08).
runcmd:
  - [bash, -c, "apt-get install -y linux-modules-extra-\$(uname -r) && modprobe uhid && echo uhid > /etc/modules-load.d/uhid.conf"]
EOF
    printf 'instance-id: lh-vm-%s\nlocal-hostname: lh-vm\n' "$(date +%s)" >"$LH_VM_DIR/meta-data"
    cloud-localds "$seed" "$LH_VM_DIR/user-data" "$LH_VM_DIR/meta-data"
  fi
  log "starting the software TPM"
  swtpm socket --tpmstate dir="$tpm_dir" --ctrl type=unixio,path="$LH_VM_DIR/swtpm.sock" \
    --tpm2 --daemon --pid file="$tpm_pidfile" --flags not-need-init,startup-clear
  log "booting (KVM, $LH_VM_CPUS CPUs, $LH_VM_MEM MiB, ssh on 127.0.0.1:$LH_VM_SSH_PORT)"
  qemu-system-x86_64 -enable-kvm -cpu host -smp "$LH_VM_CPUS" -m "$LH_VM_MEM" \
    -drive file="$disk",if=virtio,format=qcow2 -drive file="$seed",if=virtio,format=raw,readonly=on \
    -netdev user,id=n0,hostfwd=tcp:127.0.0.1:"$LH_VM_SSH_PORT"-:22 -device virtio-net-pci,netdev=n0 \
    -chardev socket,id=chrtpm,path="$LH_VM_DIR/swtpm.sock" -tpmdev emulator,id=tpm0,chardev=chrtpm \
    -device tpm-tis,tpmdev=tpm0 \
    -display none -serial file:"$LH_VM_DIR/console.log" -pidfile "$pidfile" -daemonize
  log "waiting for ssh (first boot installs packages: a few minutes)"
  for _ in $(seq 120); do
    ssh "${ssh_opts[@]}" lh@127.0.0.1 true 2>/dev/null && { log "up: scripts/vm.sh ssh"; return 0; }
    sleep 3
  done
  die "ssh did not come up; see $LH_VM_DIR/console.log"
}

cmd_ssh() { running || die "not running: scripts/vm.sh up"; ssh "${ssh_opts[@]}" lh@127.0.0.1 "$@"; }

cmd_sync() {
  running || die "not running: scripts/vm.sh up"
  need rsync "sudo apt install rsync"
  [[ -d "$CLONE_DIR" ]] || die "$CLONE_DIR is not a directory"
  rsync -a --delete --exclude target --exclude .git -e "ssh ${ssh_opts[*]}" "$CLONE_DIR/" lh@127.0.0.1:linux-hello/
  log "copied $CLONE_DIR to ~/linux-hello in the VM (no .git, no target)"
}

stop_vm() {
  if running; then kill "$(cat "$pidfile")" 2>/dev/null || true; fi
  [[ -f "$tpm_pidfile" ]] && kill "$(cat "$tpm_pidfile")" 2>/dev/null || true
  rm -f "$pidfile" "$tpm_pidfile" "$LH_VM_DIR/swtpm.sock"
}
cmd_down() { stop_vm; log "stopped (disk and TPM state kept)"; }
cmd_reset() {
  stop_vm
  rm -rf "$disk" "$seed" "$tpm_dir" "$LH_VM_DIR/user-data" "$LH_VM_DIR/meta-data" "$LH_VM_DIR/console.log"
  log "disk, seed and TPM state removed; the downloaded image is kept"
}
cmd_status() {
  if running; then echo "running, ssh port $LH_VM_SSH_PORT"; else echo "stopped"; fi
  [[ -f "$base_img" ]] && echo "image: $base_img" || echo "image: not downloaded"
}

case "${1:-}" in
  image) cmd_image ;;
  up) cmd_up ;;
  ssh) shift; cmd_ssh "$@" ;;
  sync) cmd_sync ;;
  down) cmd_down ;;
  reset) cmd_reset ;;
  status) cmd_status ;;
  *) sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; [[ -z "${1:-}" || "$1" == help ]] || exit 2 ;;
esac
