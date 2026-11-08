#!/usr/bin/env bash
# Install the Linux Hello Agent in the test VM exactly as a package would, and check on a real
# system bus, under an enforcing AppArmor profile and with real users, that the confinement
# files do what ADR-0014 and section 8 of the architecture say. Prints PASS or FAIL per check
# and exits non-zero if any failed.
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
bash "$vm" ssh 'rm -rf ~/agent-test && mkdir -p ~/agent-test'
copy() { bash "$vm" ssh "cat > ~/agent-test/$2" < "$1"; }
copy "$bin" linuxhello-agent
copy "$sec/dbus/io.github.LinuxHello.Agent1.conf" io.github.LinuxHello.Agent1.conf
copy "$sec/systemd/linuxhello-agent.service" linuxhello-agent.service
copy "$sec/systemd/linuxhello.sysusers" linuxhello.sysusers
copy "$sec/apparmor/linuxhello-agent" profile-linuxhello-agent

log "installing and testing in the VM"
bash "$vm" ssh 'bash -s' <<'REMOTE'
set +e
cd ~/agent-test
N=io.github.LinuxHello.Agent1; P=/io/github/LinuxHello/Agent1; fail=0
check() { # name, command that succeeds when the property holds
  if eval "$2" >/dev/null 2>&1; then echo "PASS $1"; else echo "FAIL $1"; fail=$((fail + 1)); fi
}
call() { sudo -u "$1" busctl --system call "${@:2}" 2>&1; }

sudo systemd-sysusers ~/agent-test/linuxhello.sysusers
sudo install -D -m755 linuxhello-agent /usr/libexec/linuxhello/linuxhello-agent
sudo install -D -m644 io.github.LinuxHello.Agent1.conf /usr/share/dbus-1/system.d/io.github.LinuxHello.Agent1.conf
sudo install -m644 profile-linuxhello-agent /etc/apparmor.d/linuxhello-agent
sudo install -m644 linuxhello-agent.service /usr/lib/systemd/system/linuxhello-agent.service
sudo apparmor_parser -r /etc/apparmor.d/linuxhello-agent
sudo systemctl reload dbus; sudo systemctl daemon-reload
sudo apt-get install -y python3-dbus python3-gi >/dev/null 2>&1
sudo systemctl stop linuxhello-agent 2>/dev/null; sudo systemctl reset-failed linuxhello-agent 2>/dev/null
T0=$(date +%s)
sudo systemctl start linuxhello-agent; sleep 1

PID=$(systemctl show -p MainPID --value linuxhello-agent)
check "unit_starts_with_the_profile_enforcing" '[ "$(systemctl is-active linuxhello-agent)" = active ] && sudo grep -qx "linuxhello-agent (enforce)" /sys/kernel/security/apparmor/profiles'
check "agent_process_runs_confined_in_enforce_mode" '[ "$(sudo cat /proc/$PID/attr/current)" = "linuxhello-agent (enforce)" ]'
check "name_is_owned_by_the_agents_user" 'busctl --system list --no-pager | grep -q "$N .*linuxhello .*linuxhello-agent.service"'
for u in lh nobody; do
  check "any_user_reaches_the_agents_methods_($u)" 'call $u $N $P $N GetState s bad | grep -q "invalid argument"'
  check "properties_are_denied_($u)" 'call $u $N $P org.freedesktop.DBus.Properties GetAll s $N | grep -q "Access denied"'
done

ID=$(python3 -c 'import hashlib;d=hashlib.sha256();d.update(b"io.github.LinuxHello.PromptId1")
for a in ["vmtest","tty2","s9"]:
    d.update(len(a).to_bytes(8,"big"));d.update(a.encode())
print(d.hexdigest())')
LHUID=$(id -u lh)
check "a_user_opens_a_prompt_for_itself" 'call lh $N $P $N OpenPrompt sx $ID $LHUID; [ $? -eq 0 ]'
check "the_user_reads_its_own_prompt" 'call lh $N $P $N GetState s $ID | grep -q idle'
for op in "GetState s $ID" "Subscribe s $ID" "ReportState ssas $ID State 1 scanning"; do
  check "another_user_is_refused_(${op%% *})" 'call nobody $N $P $N $op | grep -q "Access denied"'
done
check "another_user_cannot_open_a_prompt_for_someone_else" 'call nobody $N $P $N OpenPrompt sx $(echo $ID | tr 0-9a-f 1-9a-f0) $LHUID | grep -q "Access denied"'
check "another_user_cannot_take_the_name" 'call nobody org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus RequestName su $N 0 | grep -q "Access denied"'

# A subscriber hears the Agent's real signal; a bystander and two forgers cause nothing.
cat > /tmp/flow.py <<'PY'
import sys, dbus, dbus.mainloop.glib
from gi.repository import GLib
dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
role, prompt = sys.argv[1], sys.argv[2]
N, P = "io.github.LinuxHello.Agent1", "/io/github/LinuxHello/Agent1"
bus = dbus.SystemBus()
bus.add_signal_receiver(lambda *a, member=None, **k: print(role, "HEARD", member, [str(x) for x in a], flush=True),
                        dbus_interface=N, member_keyword="member")
if role == "subscriber":
    dbus.Interface(bus.get_object(N, P), N).Subscribe(prompt)
loop = GLib.MainLoop(); GLib.timeout_add(6000, loop.quit); loop.run()
PY
chmod 644 /tmp/flow.py
sudo -u lh python3 /tmp/flow.py subscriber $ID > /tmp/sub.out 2>&1 &
sudo -u nobody python3 /tmp/flow.py bystander $ID > /tmp/by.out 2>&1 &
sleep 2
sudo -u nobody busctl --system emit $P $N State ss $ID forged-by-nobody >/dev/null 2>&1
sudo -u lh busctl --system emit $P $N State ss $ID forged-by-lh >/dev/null 2>&1
call lh $N $P $N ReportState ssas $ID State 1 scanning >/dev/null
wait
check "a_subscriber_hears_the_agents_signal" 'grep -c "HEARD State .*scanning" /tmp/sub.out | grep -qx 1'
check "forged_signals_reach_nobody" '! grep -q forged /tmp/sub.out /tmp/by.out'
check "a_bystander_hears_nothing" '! grep -q HEARD /tmp/by.out'

# Fail closed: the unit must refuse to start unless the profile is loaded and enforcing.
sudo systemctl stop linuxhello-agent; sudo systemctl reset-failed linuxhello-agent 2>/dev/null
sudo apparmor_parser -r -C /etc/apparmor.d/linuxhello-agent
sudo systemctl start linuxhello-agent >/dev/null 2>&1
check "the_unit_refuses_to_start_with_the_profile_in_complain_mode" '[ "$(systemctl is-active linuxhello-agent)" != active ]'
sudo systemctl stop linuxhello-agent; sudo systemctl reset-failed linuxhello-agent 2>/dev/null
sudo apparmor_parser -R /etc/apparmor.d/linuxhello-agent
sudo systemctl start linuxhello-agent >/dev/null 2>&1
check "the_unit_refuses_to_start_with_the_profile_not_loaded" '[ "$(systemctl is-active linuxhello-agent)" != active ]'
sudo systemctl stop linuxhello-agent; sudo systemctl reset-failed linuxhello-agent 2>/dev/null
sudo apparmor_parser -r /etc/apparmor.d/linuxhello-agent; sudo systemctl start linuxhello-agent; sleep 1
check "the_unit_starts_again_once_the_profile_is_enforcing" '[ "$(systemctl is-active linuxhello-agent)" = active ]'

# No AppArmor denial except the probes of this test (the Properties calls that the policy refuses).
D=$(sudo journalctl -k --no-pager --since "@$T0" | grep "apparmor=\"DENIED\"" | grep "linuxhello-agent" | grep -vc "interface=\"org.freedesktop.DBus.Properties\"")
check "apparmor_denies_nothing_the_agent_needs" '[ "$D" = 0 ]'
SC=$(systemd-analyze security linuxhello-agent --no-pager 2>&1 | tail -1)
echo "INFO $SC"
[ "$fail" -eq 0 ] && echo "ALL PASSED" || echo "$fail FAILED"
exit "$fail"
REMOTE
