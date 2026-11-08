#!/usr/bin/env bash
# Spike 0007 at runtime: from inside real PAM stacks, which bus can a process reach? A probe, run by
# pam_exec, calls the Agent on the system bus and tries the logged-in user's session bus. Two
# contexts are driven: root as the PAM caller (pamtester; the SDDM helper and login do the same),
# and sudo (real uid the user, effective uid 0). Prints PASS or FAIL per check and exits non-zero if
# any failed. The checks state what the spike's desk research claimed; a FAIL is a finding.
#
#   scripts/vm-test-pam.sh     VM must be up with the Agent installed: make vm-up vm-test-agent
#
# It changes only the VM: installs pamtester, a PAM service lh-spike, a probe, a throwaway user
# lhpam (the VM's own user lh keeps its passwordless sudo), a password and a sudoers rule for it, and adds one pam_exec line to /etc/pam.d/sudo (restored at the
# end). Not covered: the SDDM greeter, the lock screen and a real console login.
set -euo pipefail
source "$(dirname "$0")/../common.sh"
vm="$(dirname "$0")/vm.sh"
bash "$vm" status | grep -q '^running' || die "the VM is not running: make vm-up"

bash "$vm" ssh 'bash -s' <<'REMOTE'
set +e
fail=0
check() { if eval "$2" >/dev/null 2>&1; then echo "PASS $1"; else echo "FAIL $1"; fail=$((fail + 1)); fi; }
systemctl is-active --quiet linuxhello-agent || { echo "the Agent is not running in the VM: make vm-test-agent first"; exit 2; }
sudo apt-get install -y pamtester >/dev/null 2>&1
sudo id lhpam >/dev/null 2>&1 || sudo useradd -m -s /bin/bash lhpam
LHUID=$(id -u lhpam)
BUS=unix:path=/run/user/$LHUID/bus

# The user's session bus, as a logged-in user would have it.
sudo loginctl enable-linger lhpam
sudo systemctl start user@$LHUID.service
for _ in $(seq 60); do [ -S /run/user/$LHUID/bus ] && break; sleep 0.5; done
check "the_users_session_bus_exists" 'sudo test -S /run/user/$LHUID/bus'

# The probe pam_exec runs. $1 names the context. It records the process's uids as the kernel has
# them (Uid: real effective saved fs) and which buses answer.
sudo tee /usr/local/bin/lh-pam-probe >/dev/null <<PROBE
#!/bin/bash
out=/tmp/lh-probe.\$1.log
{
  echo "uids: \$(grep '^Uid:' /proc/self/status | cut -f2- | tr '\\t' ' ')"
  if busctl --system call io.github.LinuxHello.Agent1 /io/github/LinuxHello/Agent1 io.github.LinuxHello.Agent1 GetState s bad 2>&1 | grep -q "invalid argument"; then echo system=reached; else echo system=failed; fi
  if DBUS_SESSION_BUS_ADDRESS=$BUS busctl --user list --no-pager >/dev/null 2>/tmp/lh-probe.\$1.err; then echo session=reached; else echo "session=refused (\$(head -c 120 /tmp/lh-probe.\$1.err))"; fi
} > \$out
exit 0
PROBE
sudo chmod 755 /usr/local/bin/lh-pam-probe
printf 'auth optional pam_exec.so quiet /usr/local/bin/lh-pam-probe root\nauth required pam_permit.so\naccount required pam_permit.so\n' | sudo tee /etc/pam.d/lh-spike >/dev/null

# Context 1: root calls PAM (pamtester).
sudo rm -f /tmp/lh-probe.root.log
sudo pamtester lh-spike lhpam authenticate >/dev/null 2>&1
echo "INFO root context: $(tr '\n' ' ' < /tmp/lh-probe.root.log)"
check "root_context_runs_the_probe_as_uid_0" 'grep -q "uids: 0 0 0 0" /tmp/lh-probe.root.log'
check "root_context_reaches_the_agent_on_the_system_bus" 'grep -q "system=reached" /tmp/lh-probe.root.log'
check "root_context_is_refused_on_the_users_session_bus" 'grep -q "session=refused" /tmp/lh-probe.root.log'

# Context 2: sudo (real uid lhpam, effective uid 0). pam_exec runs its command with the caller's
# real uid by default and with the effective uid under "seteuid"; both are probed.
sudo cp /etc/pam.d/sudo /etc/pam.d/sudo.lh-orig
sudo sed -i '0,/^@include common-auth/s//auth optional pam_exec.so quiet \/usr\/local\/bin\/lh-pam-probe sudo-real\nauth optional pam_exec.so quiet seteuid \/usr\/local\/bin\/lh-pam-probe sudo-euid\n@include common-auth/' /etc/pam.d/sudo
echo 'lhpam:lhprobe' | sudo chpasswd
echo 'lhpam ALL=(ALL) ALL' | sudo tee /etc/sudoers.d/90-lhpam-probe >/dev/null; sudo chmod 440 /etc/sudoers.d/90-lhpam-probe
sudo rm -f /tmp/lh-probe.sudo-real.log /tmp/lh-probe.sudo-euid.log
sudo -u lhpam bash -c 'echo lhprobe | sudo -S -k -p "" true' >/dev/null 2>&1
echo "INFO sudo, real uid:      $(tr '\n' ' ' < /tmp/lh-probe.sudo-real.log)"
echo "INFO sudo, effective uid: $(tr '\n' ' ' < /tmp/lh-probe.sudo-euid.log)"
echo "INFO sudo is: $(sudo -V 2>&1 | head -1)"
check "sudo_context_reaches_the_agent_on_the_system_bus_with_either_uid" 'grep -q "system=reached" /tmp/lh-probe.sudo-real.log && grep -q "system=reached" /tmp/lh-probe.sudo-euid.log'
check "sudo_context_with_effective_uid_0_is_refused_on_the_users_session_bus" 'grep -q "^uids: .* 0 " /tmp/lh-probe.sudo-euid.log && grep -q "session=refused" /tmp/lh-probe.sudo-euid.log'
check "sudo_context_with_the_users_real_uid_reaches_its_session_bus" 'grep -q "^uids: $LHUID " /tmp/lh-probe.sudo-real.log && grep -q "session=reached" /tmp/lh-probe.sudo-real.log'

# Control: the user itself reaches its own session bus.
check "the_user_itself_reaches_its_session_bus" 'sudo -u lhpam env DBUS_SESSION_BUS_ADDRESS=$BUS busctl --user list --no-pager'

sudo mv /etc/pam.d/sudo.lh-orig /etc/pam.d/sudo
sudo rm -f /etc/sudoers.d/90-lhpam-probe /etc/pam.d/lh-spike
sudo loginctl disable-linger lhpam
sudo -n true && echo "INFO the VM's sudo is as before"
[ "$fail" -eq 0 ] && echo "ALL PASSED" || echo "$fail FAILED"
exit "$fail"
REMOTE
