#!/usr/bin/env bash
# Spike linux-hello#177 in the test VM: what authenticates the presence prompt when it runs in the
# user's session, and what can another process of the same user do against each way of telling?
# A stand-in for the Agent (root, a socket every user may connect to) reads who connects: the
# AppArmor label (SO_PEERSEC), the cgroup (/proc/<pid>/cgroup) and the user. Stand-ins for the prompt
# and for an impostor then connect in different ways. Prints PASS/FAIL per check; a check named
# *_is_possible documents something the option does not stop.
#
#   scripts/vm-test-prompt-identity.sh        VM must be up: make vm-up
#
# It changes only the VM: a user lhb with lingering, one AppArmor profile, a copy of python3.
set -euo pipefail
source "$(dirname "$0")/../common.sh"
vm="$(dirname "$0")/vm.sh"
bash "$vm" status | grep -q '^running' || die "the VM is not running: make vm-up"

bash "$vm" ssh 'sudo -H bash -s' <<'REMOTE'
set +e
fail=0
check() { if eval "$2" >/dev/null 2>&1; then echo "PASS $1"; else echo "FAIL $1"; fail=$((fail + 1)); fi; }
D=/tmp/lh-spike177; PROMPT=/usr/local/libexec/linuxhello/lh-prompt-spike
mkdir -p $D /usr/local/libexec/linuxhello; chmod 1777 $D
id lhb >/dev/null 2>&1 || useradd -m -s /usr/sbin/nologin lhb
loginctl enable-linger lhb
UB=$(id -u lhb)
for _ in $(seq 50); do [ -S /run/user/$UB/bus ] && break; sleep 0.2; done
cp /usr/bin/python3 $PROMPT
UR() { systemd-run --quiet --user -M lhb@.host "$@"; }   # start a unit in lhb's user manager, as lhb

# The stand-in for the Agent: records who connected, by every means the Agent could use.
cat > $D/server.py <<'PY'
import socket, os, struct, json
path = "/tmp/lh-spike177/prompt.sock"
try: os.unlink(path)
except FileNotFoundError: pass
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.bind(path); os.chmod(path, 0o666); s.listen(8)
log = open("/tmp/lh-spike177/log.jsonl", "a", buffering=1)
print("ready", flush=True)
while True:
    c, _ = s.accept()
    try:
        pid, uid, gid = struct.unpack("3i", c.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))
        label = c.getsockopt(socket.SOL_SOCKET, 31, 256).split(b"\0")[0].decode()   # SO_PEERSEC
        cg = open(f"/proc/{pid}/cgroup").read().strip().split(":")[-1]
        who = c.recv(64).decode().strip()
        log.write(json.dumps(dict(who=who, uid=uid, label=label, cgroup=cg,
                                  label_ok=label.startswith("lh-prompt-spike"),
                                  cgroup_ok=cg.endswith("/app.slice/lh-prompt-spike.service"))) + "\n")
        c.sendall(b"ok\n")
    except Exception as e:
        log.write(json.dumps(dict(error=str(e))) + "\n")
    finally:
        c.close()
PY
# A client: connects and says who it claims to be. Optional second argument: a cgroup.procs file it
# first writes its own pid to (an impostor moving itself into the prompt's cgroup).
cat > $D/client.py <<'PY'
import socket, sys, os, time
who = sys.argv[1]
if len(sys.argv) > 2:
    try:
        with open(sys.argv[2], "w") as f:
            f.write(str(os.getpid()))
        print("moved", flush=True)
    except OSError as e:
        print("move refused:", e, flush=True)
        sys.exit(0)
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.connect("/tmp/lh-spike177/prompt.sock")
s.sendall(who.encode()); s.recv(8)
PY
# A holder: stays alive in a unit so that its cgroup exists; not dumpable, with a socket pair.
cat > $D/holder.py <<'PY'
import ctypes, socket, time, os
ctypes.CDLL(None).prctl(4, 0, 0, 0, 0)   # PR_SET_DUMPABLE = 0
a, b = socket.socketpair()
open("/tmp/lh-spike177/holder.pid", "w").write(f"{os.getpid()} {a.fileno()}")
time.sleep(25)
PY
# What a same-user process tries against a process that holds a descriptor: take it with pidfd_getfd.
cat > $D/thief.py <<'PY'
import ctypes, os, sys
pid, fd = map(int, open("/tmp/lh-spike177/holder.pid").read().split())
pidfd = os.pidfd_open(pid)
libc = ctypes.CDLL(None, use_errno=True)
r = libc.syscall(438, pidfd, fd, 0)   # pidfd_getfd
print("taken" if r >= 0 else f"refused: errno {ctypes.get_errno()}")
PY
cat > /etc/apparmor.d/lh-prompt-spike <<'PROFILE'
abi <abi/4.0>,
include <tunables/global>
profile lh-prompt-spike /usr/local/libexec/linuxhello/lh-prompt-spike {
  include <abstractions/base>
  include <abstractions/python>
  /usr/local/libexec/linuxhello/lh-prompt-spike mr,
  /usr/bin/python3* mr,
  /tmp/lh-spike177/** rw,
  /proc/*/cgroup r,
  /sys/fs/cgroup/** rw,
  unix (create, connect, send, receive) type=stream,
}
PROFILE
apparmor_parser -r /etc/apparmor.d/lh-prompt-spike

pkill -f "$D/server.py"; : > $D/log.jsonl; rm -f $D/move-* $D/holder.pid
python3 $D/server.py > $D/server.out 2>&1 &
for _ in $(seq 20); do [ -S $D/prompt.sock ] && break; sleep 0.2; done
last() { tail -n 1 $D/log.jsonl; }
field() { last | python3 -c "import sys,json; print(json.load(sys.stdin)['$1'])"; }

# 1. The prompt as the design starts it: a unit in the user's manager, running the confined binary.
UR --unit=lh-prompt-spike --property=Type=oneshot --property=RemainAfterExit=no --wait $PROMPT $D/client.py legit >/dev/null 2>&1
echo "INFO legit prompt: $(last)"
check "the_prompt_started_in_the_user_manager_has_the_label_and_the_cgroup" '[ "$(field label_ok)" = True ] && [ "$(field cgroup_ok)" = True ] && [ "$(field uid)" = $UB ]'

# 2. An impostor with no profile, started like any program of the user.
sudo -u lhb python3 $D/client.py plain >/dev/null 2>&1
echo "INFO plain impostor: $(last)"
check "a_same_user_process_without_the_label_is_refused_by_the_label_check" '[ "$(field who)" = plain ] && [ "$(field label_ok)" = False ]'
check "a_same_user_process_outside_the_unit_is_refused_by_the_cgroup_check" '[ "$(field cgroup_ok)" = False ]'
check "any_process_of_the_user_can_connect_to_a_socket_that_every_user_may_reach" '[ "$(field uid)" = $UB ]'

# 3. An impostor that asks for the profile itself.
sudo -u lhb aa-exec -p lh-prompt-spike /usr/bin/python3 $D/client.py aa-exec >/dev/null 2>&1
echo "INFO aa-exec impostor: $(last)"
check "a_same_user_process_can_take_the_label_with_aa_exec_and_pass_the_label_check_is_possible" '[ "$(field who)" = aa-exec ] && [ "$(field label_ok)" = True ]'
check "the_label_taker_still_fails_the_cgroup_check" '[ "$(field cgroup_ok)" = False ]'

# 4. An impostor that moves itself into the prompt's cgroup. The prompt's unit is kept alive.
UR --unit=lh-prompt-spike /usr/bin/python3 -c 'import time; time.sleep(20)'
sleep 1
CG=/sys/fs/cgroup/user.slice/user-$UB.slice/user@$UB.service/app.slice/lh-prompt-spike.service
echo "INFO prompt cgroup: $(stat -c '%U:%G %a' $CG/cgroup.procs 2>&1)"
sudo -u lhb python3 $D/client.py moved-from-session $CG/cgroup.procs > $D/move1.out 2>&1
echo "INFO from a session scope: $(head -1 $D/move1.out)"
check "a_same_user_process_in_a_login_session_cannot_enter_the_prompts_cgroup" 'grep -q "move refused" $D/move1.out'
UR --unit=lh-impostor-unit --wait --property=Type=oneshot /usr/bin/python3 $D/client.py moved-from-manager $CG/cgroup.procs > /dev/null 2>&1
echo "INFO from the user manager: $(last)"
check "a_same_user_process_started_by_the_user_manager_can_enter_the_prompts_cgroup_and_pass_the_cgroup_check_is_possible" '[ "$(field who)" = moved-from-manager ] && [ "$(field cgroup_ok)" = True ]'
check "that_impostor_still_lacks_the_label" '[ "$(field label_ok)" = False ]'

# 5. Both together: moved into the cgroup and wearing the profile.
UR --unit=lh-impostor-both --wait --property=Type=oneshot /usr/bin/aa-exec -p lh-prompt-spike /usr/bin/python3 $D/client.py both $CG/cgroup.procs > /dev/null 2>&1
echo "INFO label and cgroup together: $(last)"
check "a_same_user_process_can_pass_the_label_and_the_cgroup_check_together_is_possible" '[ "$(field who)" = both ] && [ "$(field label_ok)" = True ] && [ "$(field cgroup_ok)" = True ]'
systemctl --user -M lhb@.host stop lh-prompt-spike >/dev/null 2>&1

# 6. A descriptor handed to the prompt by whoever starts it cannot be taken by a same-user process.
UR --unit=lh-descriptor-holder /usr/bin/python3 $D/holder.py
for _ in $(seq 20); do [ -s $D/holder.pid ] && break; sleep 0.2; done
OUT=$(sudo -u lhb python3 $D/thief.py 2>&1); echo "INFO thief: $OUT"
check "a_same_user_process_cannot_take_a_descriptor_from_the_prompt_with_pidfd_getfd" 'echo "$OUT" | grep -q refused'
echo "INFO ptrace_scope: $(cat /proc/sys/kernel/yama/ptrace_scope)"
systemctl --user -M lhb@.host stop lh-descriptor-holder >/dev/null 2>&1

pkill -f "$D/server.py"
[ "$fail" -eq 0 ] && echo "ALL PASSED" || echo "$fail FAILED"
exit "$fail"
REMOTE
