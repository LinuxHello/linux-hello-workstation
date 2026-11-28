#!/usr/bin/env bash
# The PAM module in real sudo in the test VM: builds the Agent, the CLI, the TPM provider and the
# PAM module, copies them with the security files and the prototype installer into the VM, and
# runs scripts/ci/pam-sudo.sh of the linux-hello repository there (it installs with
# scripts/prototype/install.sh --no-build and drives sudo -S with a PIN, a wrong PIN, an empty
# answer and a stopped Agent).
#
#   scripts/vm-test-pam-sudo.sh     build, install, test (VM must be up: make vm-up)
#
# The provider and the PAM module link system libraries (TSS2, libpam), so they are built on this
# machine for the release of the VM, and the VM must run the same release (Ubuntu 26.04: export
# LH_VM_RELEASE=26.04 LH_VM_NAME=linux-hello-vm-2604 LH_VM_SSH_PORT=2223). It changes
# only the VM.
set -euo pipefail
source "$(dirname "$0")/../common.sh"

vm="$(dirname "$0")/vm.sh"
musl=x86_64-unknown-linux-musl
t=pam-sudo-test

bash "$vm" status | grep -q '^running' || die "the VM is not running: make vm-up"
[[ -f "$CLONE_DIR/scripts/ci/pam-sudo.sh" ]] || die "$CLONE_DIR has no scripts/ci/pam-sudo.sh (CLONE_DIR=<a checkout with the PAM module>)"

log "building the Agent and the CLI (static), the provider and the PAM module (this release)"
(cd "$CLONE_DIR" \
  && cargo build --release --target "$musl" -p linuxhello-agent -p linuxhello-ctl \
  && cargo build --release -p linuxhello-tpm-provider -p pam-linuxhello) || die "build failed"

log "copying the files into the VM"
bash "$vm" ssh "rm -rf ~/$t && mkdir -p ~/$t/scripts/ci ~/$t/scripts/prototype ~/$t/security/{dbus,systemd,apparmor,polkit} ~/$t/plasma/autostart ~/$t/target/$musl/release ~/$t/target/release"
copy() { bash "$vm" ssh "cat > ~/$t/$2" < "$CLONE_DIR/$1"; }
copy "target/$musl/release/linuxhello-agent" "target/$musl/release/linuxhello-agent"
copy "target/$musl/release/linuxhello-ctl" "target/$musl/release/linuxhello-ctl"
copy target/release/linuxhello-tpm-provider target/release/linuxhello-tpm-provider
copy target/release/libpam_linuxhello.so target/release/libpam_linuxhello.so
for f in dbus/io.github.LinuxHello.Agent1.conf dbus/io.github.LinuxHello.Agent1.service \
         systemd/linuxhello-agent.service systemd/linuxhello-tpm-provider.service systemd/linuxhello.sysusers \
         apparmor/linuxhello-agent apparmor/linuxhello-tpm-provider polkit/50-linuxhello-agent.rules; do
  copy "security/$f" "security/$f"
done
# The reset action and the notification's autostart entry, where the checkout has them (the installer
# of linux-hello from #333 and #334 on installs both).
for f in security/polkit/io.github.LinuxHello.policy plasma/autostart/linuxhello-notify.desktop; do
  [[ -f "$CLONE_DIR/$f" ]] && copy "$f" "$f"
done
for f in scripts/ci/pam-sudo.sh scripts/prototype/install.sh scripts/prototype/uninstall.sh; do copy "$f" "$f"; done

log "installing and testing in the VM"
bash "$vm" ssh "cd ~/$t && chmod +x target/$musl/release/* target/release/linuxhello-tpm-provider && LH_CONFINEMENT_INSTALL=yes bash scripts/ci/pam-sudo.sh"
