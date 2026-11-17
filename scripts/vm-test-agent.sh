#!/usr/bin/env bash
# Install the Linux Hello Agent in the test VM exactly as a package would, and check on a real
# system bus, under an enforcing AppArmor profile and with real users, that the confinement
# files do what ADR-0014 and section 8 of the architecture say. Prints PASS or FAIL per check
# and exits non-zero if any failed. The checks are the script of the linux-hello repository,
# scripts/ci/confinement.sh, that its CI job also runs on a GitHub-hosted runner; this run adds
# other releases (Ubuntu 26.04) and a VM you can inspect.
#
#   scripts/vm-test-agent.sh        build the static binary, install, test (VM must be up: make vm-up)
#
# Needs the linux-hello clone at $CLONE_DIR, the musl target for its toolchain
# (rustup target add --toolchain <rust-toolchain.toml channel> x86_64-unknown-linux-musl), and the
# VM from scripts/vm.sh. It changes only the VM: it creates the user linuxhello, installs files
# under /usr, /etc and /var, loads the profile, and starts the unit.
set -euo pipefail
source "$(dirname "$0")/../common.sh"

vm="$(dirname "$0")/vm.sh"
sec="$CLONE_DIR/security"
target=x86_64-unknown-linux-musl
bin="$CLONE_DIR/target/$target/release/linuxhello-agent"

bash "$vm" status | grep -q '^running' || die "the VM is not running: make vm-up"
for f in "$sec/dbus/io.github.LinuxHello.Agent1.conf" "$sec/systemd/linuxhello-agent.service" \
         "$sec/systemd/linuxhello.sysusers" "$sec/apparmor/linuxhello-agent"; do
  [[ -f "$f" ]] || die "$f not found: is CLONE_DIR ($CLONE_DIR) the linux-hello clone, on a branch with security/?"
done

log "building a static binary of the Agent"
(cd "$CLONE_DIR" && cargo build --release --target "$target" -p linuxhello-agent) \
  || die "build failed (musl target missing? rustup target add --toolchain \$(grep channel rust-toolchain.toml | cut -d'\"' -f2) $target)"

log "copying the files into the VM"
bash "$vm" ssh 'rm -rf ~/agent-test && mkdir -p ~/agent-test/scripts/ci ~/agent-test/security/dbus ~/agent-test/security/systemd ~/agent-test/security/apparmor ~/agent-test/target/'"$target"'/release'
copy() { bash "$vm" ssh "cat > ~/agent-test/$2" < "$1"; }
copy "$bin" "target/$target/release/linuxhello-agent"
copy "$sec/dbus/io.github.LinuxHello.Agent1.conf" security/dbus/io.github.LinuxHello.Agent1.conf
copy "$sec/systemd/linuxhello-agent.service" security/systemd/linuxhello-agent.service
copy "$sec/systemd/linuxhello.sysusers" security/systemd/linuxhello.sysusers
copy "$sec/apparmor/linuxhello-agent" security/apparmor/linuxhello-agent
copy "$CLONE_DIR/scripts/ci/confinement.sh" scripts/ci/confinement.sh

log "installing and testing in the VM"
bash "$vm" ssh 'cd ~/agent-test && LH_CONFINEMENT_INSTALL=yes bash scripts/ci/confinement.sh'
