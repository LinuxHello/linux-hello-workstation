#!/usr/bin/env bash
# The whole PIN chain in the test VM: the Agent, the TPM provider and `linuxhello-ctl` installed as
# packages would install them, then `pin set` and `pin change` run as an ordinary user against the
# VM's software TPM. The checks are scripts/ci/pin-chain.sh of the linux-hello repository.
#
#   scripts/vm-test-pin.sh     build, install, test (VM must be up: make vm-up)
#
# The provider links the TSS2 libraries, so it is built on this machine for the release of the VM
# and the VM must run the same release (Ubuntu 26.04; export LH_VM_RELEASE=26.04
# LH_VM_DIR=~/.local/share/linux-hello-vm-2604 LH_VM_SSH_PORT=2223). It changes only the VM.
set -euo pipefail
source "$(dirname "$0")/../common.sh"

vm="$(dirname "$0")/vm.sh"
sec="$CLONE_DIR/security"
musl=x86_64-unknown-linux-musl

bash "$vm" status | grep -q '^running' || die "the VM is not running: make vm-up"

log "building the Agent and the CLI (static) and the provider (this release)"
(cd "$CLONE_DIR" \
  && cargo build --release --target "$musl" -p linuxhello-agent -p linuxhello-ctl \
  && cargo build --release -p linuxhello-tpm-provider) || die "build failed"

log "copying the files into the VM"
bash "$vm" ssh 'rm -rf ~/pin-test && mkdir -p ~/pin-test/scripts/ci ~/pin-test/security/{dbus,systemd,apparmor,polkit} ~/pin-test/target/'"$musl"'/release ~/pin-test/target/release'
copy() { bash "$vm" ssh "cat > ~/pin-test/$2" < "$1"; }
copy "$CLONE_DIR/target/$musl/release/linuxhello-agent" "target/$musl/release/linuxhello-agent"
copy "$CLONE_DIR/target/$musl/release/linuxhello-ctl" "target/$musl/release/linuxhello-ctl"
copy "$CLONE_DIR/target/release/linuxhello-tpm-provider" target/release/linuxhello-tpm-provider
for f in dbus/io.github.LinuxHello.Agent1.conf dbus/io.github.LinuxHello.Agent1.service \
         systemd/linuxhello-agent.service systemd/linuxhello-tpm-provider.service systemd/linuxhello.sysusers \
         apparmor/linuxhello-agent apparmor/linuxhello-tpm-provider polkit/50-linuxhello-agent.rules; do
  copy "$sec/$f" "security/$f"
done
copy "$CLONE_DIR/scripts/ci/pin-chain.sh" scripts/ci/pin-chain.sh

log "installing and testing in the VM"
bash "$vm" ssh 'cd ~/pin-test && LH_CONFINEMENT_INSTALL=yes bash scripts/ci/pin-chain.sh'
