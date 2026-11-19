#!/usr/bin/env bash
# Install the Linux Hello TPM provider in the test VM exactly as a package would, and check, on the VM's
# own TPM interface (/dev/tpmrm0, a software TPM), under an enforcing AppArmor profile and with real
# users, that only the Agent's user is served, that the TPM tells a right PIN from a wrong one and that
# the profile denies the provider nothing it needs. Prints PASS or FAIL per check and exits non-zero if
# any failed. The checks are the script of the linux-hello repository, scripts/ci/provider-confinement.sh.
#
#   scripts/vm-test-provider.sh        build the provider, install, test (VM must be up: make vm-up)
#
# The provider is a dynamic binary (it links the TSS2 libraries), unlike the static Agent, so it must be
# built on the release of the machine it runs on. This script therefore refuses a VM whose release is not
# the one of this workstation (its glibc must not be older than the one the binary was built with), and
# says so; Ubuntu 24.04 is not covered from a newer host.
#
# Needs the linux-hello clone at $CLONE_DIR (on a branch with security/systemd/linuxhello-tpm-provider.service),
# libtss2-dev and clang here (make tpm-dev-deps), and the VM from scripts/vm.sh. It changes only the VM:
# it creates the users linuxhello, linuxhello-tpm and lh, installs files under /usr and /etc, loads the
# profile, starts the unit, and changes the VM's TPM dictionary-attack parameters.
set -euo pipefail
source "$(dirname "$0")/../common.sh"

vm="$(dirname "$0")/vm.sh"
sec="$CLONE_DIR/security"
bin="$CLONE_DIR/target/release/linuxhello-tpm-provider"

bash "$vm" status | grep -q '^running' || die "the VM is not running: make vm-up"
for f in "$sec/systemd/linuxhello-tpm-provider.service" "$sec/systemd/linuxhello.sysusers" \
         "$sec/apparmor/linuxhello-tpm-provider" "$CLONE_DIR/scripts/ci/provider-confinement.sh"; do
  [[ -f "$f" ]] || die "$f not found: is CLONE_DIR ($CLONE_DIR) the linux-hello clone, on a branch with the provider's unit?"
done

host_glibc="$(ldd --version | head -1 | grep -oE '[0-9]+\.[0-9]+$')"
vm_glibc="$(bash "$vm" ssh 'ldd --version | head -1' | grep -oE '[0-9]+\.[0-9]+$')"
if [[ "$(printf '%s\n%s\n' "$vm_glibc" "$host_glibc" | sort -V | head -1)" != "$host_glibc" && "$host_glibc" != "$vm_glibc" ]]; then
  die "the VM has glibc $vm_glibc and this machine $host_glibc: a binary built here would not run there. Use a VM of this machine's release (LH_VM_RELEASE)."
fi

log "building the provider (dynamic, glibc $host_glibc)"
(cd "$CLONE_DIR" && cargo build --release -p linuxhello-tpm-provider) || die "build failed (make tpm-dev-deps?)"

log "copying the files into the VM"
bash "$vm" ssh 'rm -rf ~/provider-test && mkdir -p ~/provider-test/scripts/ci ~/provider-test/security/systemd ~/provider-test/security/apparmor ~/provider-test/target/release'
copy() { bash "$vm" ssh "cat > ~/provider-test/$2" < "$1"; }
copy "$bin" target/release/linuxhello-tpm-provider
copy "$sec/systemd/linuxhello-tpm-provider.service" security/systemd/linuxhello-tpm-provider.service
copy "$sec/systemd/linuxhello.sysusers" security/systemd/linuxhello.sysusers
copy "$sec/apparmor/linuxhello-tpm-provider" security/apparmor/linuxhello-tpm-provider
copy "$CLONE_DIR/scripts/ci/provider-confinement.sh" scripts/ci/provider-confinement.sh

log "installing and testing in the VM"
bash "$vm" ssh 'cd ~/provider-test && LH_CONFINEMENT_INSTALL=yes bash scripts/ci/provider-confinement.sh'
