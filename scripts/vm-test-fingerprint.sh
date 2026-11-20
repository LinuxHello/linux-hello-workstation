#!/usr/bin/env bash
# The fingerprint method against the real fprintd in the test VM: installs fprintd (apt, in the VM),
# gives it libfprint's virtual fingerprint device, installs the Agent as a package would, enrols a
# virtual finger and runs a match, a mismatch and a cancel through `Authenticate`. The checks are
# scripts/ci/fingerprint-real.sh of the linux-hello repository.
#
#   scripts/vm-test-fingerprint.sh     build, install, test (VM must be up: make vm-up)
#
# It changes only the VM, and downloads only into it: fprintd and python3-dbus from the VM's Ubuntu
# archive. Run it on a release for which the Agent's static build is fine (any).
set -euo pipefail
source "$(dirname "$0")/../common.sh"

vm="$(dirname "$0")/vm.sh"
sec="$CLONE_DIR/security"
musl=x86_64-unknown-linux-musl

bash "$vm" status | grep -q '^running' || die "the VM is not running: make vm-up"

log "building the Agent (static)"
(cd "$CLONE_DIR" && cargo build --release --target "$musl" -p linuxhello-agent) || die "build failed"

log "copying the files into the VM"
bash "$vm" ssh 'rm -rf ~/fp-test && mkdir -p ~/fp-test/scripts/ci ~/fp-test/security/{dbus,systemd,apparmor,polkit} ~/fp-test/target/'"$musl"'/release'
copy() { bash "$vm" ssh "cat > ~/fp-test/$2" < "$1"; }
copy "$CLONE_DIR/target/$musl/release/linuxhello-agent" "target/$musl/release/linuxhello-agent"
for f in dbus/io.github.LinuxHello.Agent1.conf dbus/io.github.LinuxHello.Agent1.service \
         systemd/linuxhello-agent.service systemd/linuxhello.sysusers \
         apparmor/linuxhello-agent polkit/50-linuxhello-agent.rules; do
  copy "$sec/$f" "security/$f"
done
copy "$CLONE_DIR/scripts/ci/fingerprint-real.sh" scripts/ci/fingerprint-real.sh

log "installing and testing in the VM"
bash "$vm" ssh 'cd ~/fp-test && LH_CONFINEMENT_INSTALL=yes bash scripts/ci/fingerprint-real.sh'
