#!/usr/bin/env bash
# Follow-up of spike linux-hello#177 in the test VM: can the Agent, which is not root, get the presence
# prompt into the user's session in a way that a same-user impostor cannot copy? The idea tested: a
# system unit template linuxhello-prompt@<uid>.service that runs the prompt as that user, started
# by the Agent through systemd and a narrow polkit rule. The prompt then sits in a system cgroup
# that the user cannot write to. Prints PASS/FAIL per check; a check named *_is_possible documents
# something the idea does not stop.
#
#   scripts/vm-test-prompt-launch.sh        VM must be up: make vm-up
#
# It changes only the VM: users lhagent and lhb, a unit template, a polkit rule, an AppArmor profile.
set -euo pipefail
source "$(dirname "$0")/../common.sh"
vm="$(dirname "$0")/vm.sh"
bash "$vm" status | grep -q '^running' || die "the VM is not running: make vm-up"

bash "$vm" ssh 'sudo -H bash -s' <<'REMOTE'
set +e
fail=0
check() { if eval "$2" >/dev/null 2>&1; then echo "PASS $1"; else echo "FAIL $1"; fail=$((fail + 1)); fi; }
D=/tmp/lh-spike177b; PROMPT=/usr/local/libexec/linuxhello/lh-prompt-spike
mkdir -p $D /usr/local/libexec/linuxhello; chmod 1777 $D
id lhb >/dev/null 2>&1 || useradd -m -s /usr/sbin/nologin lhb
id lhagent >/dev/null 2>&1 || useradd -r -M -s /usr/sbin/nologin lhagent
loginctl enable-linger lhb
UB=$(id -u lhb)
for _ in $(seq 50); do [ -S /run/user/$UB/bus ] && break; sleep 0.2; done
cp /usr/bin/python3 $PROMPT

# The stand-in for the Agent: records the user, the AppArmor label and the cgroup of each peer.
cat > $D/server.py <<'PY'
import socket, os, struct, json
path = "/tmp/lh-spike177b/prompt.sock"
try: os.unlink(path)
except FileNotFoundError: pass
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.bind(path); os.chmod(path, 0o666); s.listen(8)
log = open("/tmp/lh-spike177b/log.jsonl", "a", buffering=1)
while True:
    c, _ = s.accept()
    try:
        pid, uid, gid = struct.unpack("3i", c.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))
        label = c.getsockopt(socket.SOL_SOCKET, 31, 256).split(b"\0")[0].decode()
        cg = open(f"/proc/{pid}/cgroup").read().strip().split(":")[-1]
        who = c.recv(64).decode().strip()
        log.write(json.dumps(dict(who=who, uid=uid, label=label, cgroup=cg,
                                  label_ok=label.startswith("lh-prompt-spike"),
                                  cgroup_ok=cg == f"/system.slice/system-linuxhello\\x2dprompt.slice/linuxhello-prompt@{uid}.service")) + "\n")
        c.sendall(b"ok\n")
    except Exception as e:
        log.write(json.dumps(dict(error=str(e))) + "\n")
    finally:
        c.close()
PY
# The prompt: connects to the Agent, then tries the user's display socket (a stand-in for Wayland).
cat > $D/prompt.py <<'PY'
import socket, sys, time, os
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.connect("/tmp/lh-spike177b/prompt.sock")
s.sendall(b"legit"); s.recv(8)
display = os.environ["XDG_RUNTIME_DIR"] + "/" + os.environ["WAYLAND_DISPLAY"]
d = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
try:
    d.connect(display); d.sendall(b"hello"); out = "display reached"
except OSError as e:
    out = f"display refused: {e}"
open("/tmp/lh-spike177b/prompt.display", "w").write(out)
time.sleep(30)
PY
# A fake display of the user, as a compositor would offer in the user's runtime directory.
cat > $D/display.py <<'PY'
import socket, os, sys
p = sys.argv[1]
try: os.unlink(p)
except FileNotFoundError: pass
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.bind(p); s.listen(2)
c, _ = s.accept(); open("/tmp/lh-spike177b/display.got", "wb").write(c.recv(16))
PY
cat > $D/client.py <<'PY'
import socket, sys, os
who = sys.argv[1]
if len(sys.argv) > 2:
    try:
        with open(sys.argv[2], "w") as f:
            f.write(str(os.getpid()))
        print("moved", flush=True)
    except OSError as e:
        print("move refused:", e, flush=True)
        sys.exit(0)
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.connect("/tmp/lh-spike177b/prompt.sock")
s.sendall(who.encode()); s.recv(8)
PY
cat > /etc/apparmor.d/lh-prompt-spike <<'PROFILE'
abi <abi/4.0>,
include <tunables/global>
profile lh-prompt-spike /usr/local/libexec/linuxhello/lh-prompt-spike flags=(attach_disconnected) {
  include <abstractions/base>
  include <abstractions/python>
  /usr/local/libexec/linuxhello/lh-prompt-spike mr,
  /usr/bin/python3* mr,
  /tmp/lh-spike177b/** rw,
  /run/user/*/* rw,
  /proc/*/cgroup r,
  /dev/null rw,
  unix (create, connect, send, receive) type=stream,
}
PROFILE
apparmor_parser -r /etc/apparmor.d/lh-prompt-spike

# The unit template: one prompt per user, run as that user, outside the user's own systemd.
cat > /etc/systemd/system/linuxhello-prompt@.service <<UNIT
[Unit]
Description=Linux Hello presence prompt for user %i (spike)
[Service]
User=%i
Environment=XDG_RUNTIME_DIR=/run/user/%i
Environment=WAYLAND_DISPLAY=wayland-spike
ExecStart=$PROMPT $D/prompt.py
NoNewPrivileges=yes
PrivateNetwork=yes
UNIT
# The narrow polkit rule: the Agent's user may start and stop this template, for an ordinary user (a number of 1000 or more), and nothing else.
cat > /etc/polkit-1/rules.d/60-linuxhello-prompt-spike.rules <<'RULE'
polkit.addRule(function(action, subject) {
  if (action.id == "org.freedesktop.systemd1.manage-units" && subject.user == "lhagent") {
    var unit = action.lookup("unit"), verb = action.lookup("verb");
    if (/^linuxhello-prompt@[1-9][0-9]{3,}\.service$/.test(unit) && (verb == "start" || verb == "stop")) {
      return polkit.Result.YES;
    }
  }
});
RULE
systemctl daemon-reload; systemctl restart polkit; sleep 1

pkill -f "$D/server.py"; pkill -f "$D/display.py"; : > $D/log.jsonl; rm -f $D/prompt.display $D/display.got
python3 $D/server.py > $D/server.out 2>&1 &
sudo -u lhb python3 $D/display.py /run/user/$UB/wayland-spike > $D/display.out 2>&1 &
for _ in $(seq 20); do [ -S $D/prompt.sock ] && [ -S /run/user/$UB/wayland-spike ] && break; sleep 0.2; done
last() { tail -n 1 $D/log.jsonl; }
field() { last | python3 -c "import sys,json; print(json.load(sys.stdin)['$1'])"; }
as_agent() { sudo -u lhagent "$@"; }
export SYSTEMD_PAGER=

# 1. The Agent's user starts the prompt for one user, through systemd, with no root.
as_agent systemctl start linuxhello-prompt@$UB.service > $D/start.out 2>&1
check "the_agents_user_can_start_the_prompt_unit_for_a_user" '[ "$(systemctl is-active linuxhello-prompt@$UB.service)" = active ]'
sleep 2
echo "INFO prompt: $(last)"
check "the_prompt_runs_as_the_user_with_the_label_and_a_system_cgroup" '[ "$(field uid)" = $UB ] && [ "$(field label_ok)" = True ] && [ "$(field cgroup_ok)" = True ]'
echo "INFO display: $(cat $D/prompt.display 2>&1)"
check "the_prompt_reaches_the_users_display_socket_from_a_system_unit" 'grep -q "display reached" $D/prompt.display && [ "$(cat $D/display.got)" = hello ]'

# 2. The Agent's user may do nothing else.
as_agent systemctl restart ssh.service > $D/other.out 2>&1
check "the_agents_user_cannot_restart_another_unit" 'grep -qi "authentication\|denied\|not authorized\|interactive" $D/other.out'
as_agent systemctl start linuxhello-prompt@0.service > $D/root.out 2>&1
echo "INFO start for uid 0: $(head -c 200 $D/root.out | tr '\n' ' ') active=$(systemctl is-active linuxhello-prompt@0.service)"
check "the_rule_does_not_let_the_agent_start_a_prompt_for_root" '[ "$(systemctl is-active linuxhello-prompt@0.service)" != active ]'
systemctl stop linuxhello-prompt@0.service

# 3. The user cannot start or stop the prompt, and cannot move into its cgroup.
sudo -u lhb systemctl start linuxhello-prompt@$UB.service > $D/user-start.out 2>&1
sudo -u lhb systemctl stop linuxhello-prompt@$UB.service > $D/user-stop.out 2>&1
check "the_user_cannot_stop_the_prompt_unit_through_systemd" '[ "$(systemctl is-active linuxhello-prompt@$UB.service)" = active ]'
CG="/sys/fs/cgroup/system.slice/system-linuxhello\\x2dprompt.slice/linuxhello-prompt@$UB.service"
echo "INFO system cgroup: $(stat -c '%U:%G %a' $CG/cgroup.procs)"
sudo -u lhb python3 $D/client.py moved-from-session $CG/cgroup.procs > $D/move1.out 2>&1
echo "INFO from a login session: $(head -1 $D/move1.out)"
check "a_same_user_process_cannot_enter_the_prompts_system_cgroup_from_a_login_session" 'grep -q "move refused" $D/move1.out'
systemd-run --quiet --user -M lhb@.host --unit=lh-impostor-unit --wait --pipe /usr/bin/python3 $D/client.py moved-from-manager $CG/cgroup.procs > $D/move2.out 2>&1
echo "INFO from the user manager: $(grep -h "move\|refused" $D/move2.out | head -1)"
check "a_same_user_process_cannot_enter_the_prompts_system_cgroup_from_the_user_manager" 'grep -q "move refused" $D/move2.out'


# 4. The impostors of the first spike, now against a system cgroup.
sudo -u lhb aa-exec -p lh-prompt-spike /usr/bin/python3 $D/client.py aa-exec >/dev/null 2>&1
echo "INFO aa-exec impostor: $(last)"
check "a_same_user_process_can_take_the_label_but_not_the_system_cgroup" '[ "$(field who)" = aa-exec ] && [ "$(field label_ok)" = True ] && [ "$(field cgroup_ok)" = False ]'
systemd-run --quiet --user -M lhb@.host --unit=lh-prompt-lookalike --wait --property=Type=oneshot /usr/bin/aa-exec -p lh-prompt-spike /usr/bin/python3 $D/client.py lookalike >/dev/null 2>&1
check "a_unit_in_the_users_manager_with_the_prompts_name_and_label_fails_the_system_cgroup_check" '[ "$(field who)" = lookalike ] && [ "$(field cgroup_ok)" = False ]'

# 5. What the user can still do to its own prompt.
PID=$(systemctl show -p MainPID --value linuxhello-prompt@$UB.service)
sudo -u lhb kill -0 $PID > $D/kill.out 2>&1
check "the_user_can_signal_its_own_prompt_so_it_can_end_it_is_possible" '[ ! -s $D/kill.out ]'
sudo -u lhb python3 -c "open('/proc/$PID/mem','rb')" > $D/mem.out 2>&1
check "the_user_cannot_open_the_prompts_memory" 'grep -q "Permission denied" $D/mem.out'
systemctl stop linuxhello-prompt@$UB.service

pkill -f "$D/server.py"; pkill -f "$D/display.py"
rm -f /etc/polkit-1/rules.d/60-linuxhello-prompt-spike.rules /etc/systemd/system/linuxhello-prompt@.service
systemctl daemon-reload; systemctl restart polkit
[ "$fail" -eq 0 ] && echo "ALL PASSED" || echo "$fail FAILED"
exit "$fail"
REMOTE
