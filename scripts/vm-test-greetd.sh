#!/usr/bin/env bash
# Spike 0311 of the architecture repository, the protocol half: does greetd, the small login
# service Linux Hello's own login screen is to use, pass pam_linuxhello's question and lines to the
# greeter with their kind? A minimal greeter in Python (standard library only) speaks greetd's
# socket protocol (greetd-ipc(7)) and plays a person: a wrong PIN, an empty answer, the Agent
# stopped, the right PIN. Prints PASS or FAIL per check and every message greetd passed on.
#
#   scripts/vm-test-greetd.sh   VM up, the prototype installed and lhpam's PIN set first:
#                               make vm-test-pam-sudo (it sets lhpam's PIN 246810)
#
# It changes only the VM: installs greetd from the Ubuntu archive, sets a test password for lhpam,
# points greetd's greeter at a stand-in, and at the end restores greetd's PAM file and disables
# greetd. Not covered: a real QML greeter, a display, starting Plasma or another desktop.
set -euo pipefail
source "$(dirname "$0")/../common.sh"
vm="$(dirname "$0")/vm.sh"
bash "$vm" status | grep -q '^running' || die "the VM is not running: make vm-up"

bash "$vm" ssh 'bash -s' <<'REMOTE'
set -u
fail=0
check() { if eval "$2" >/dev/null 2>&1; then echo "PASS $1"; else echo "FAIL $1"; fail=$((fail + 1)); fi; }

sudo DEBIAN_FRONTEND=noninteractive apt-get install -y greetd >/dev/null 2>&1
echo "greetd $(dpkg-query -W -f='${Version}' greetd)"
echo "greeter user in the shipped config: $(sudo grep -E '^\s*user' /etc/greetd/config.toml | head -1)"
echo "shipped PAM file:"; sudo cat /etc/pam.d/greetd | sed 's/^/  | /'

# The test user and its PIN (246810) come from scripts/ci/pam-sudo.sh; give it a test password.
PASS=greetd-spike-pass
echo "lhpam:$PASS" | sudo chpasswd

# Linux Hello's login line first, then the rest of greetd's own file.
sudo cp /etc/pam.d/greetd /etc/pam.d/greetd.orig 2>/dev/null || true
# greetd's file includes login, which already has the installer's Linux Hello line; check it.
echo "login's Linux Hello line: $(grep pam_linuxhello /etc/pam.d/login)"

# A "greeter" that only writes greetd's socket path for the test and waits.
sudo tee /usr/local/bin/lh-spike-greeter >/dev/null <<'G'
#!/bin/sh
echo "$GREETD_SOCK" > /tmp/greetd-sock
exec sleep infinity
G
sudo chmod 755 /usr/local/bin/lh-spike-greeter
sudo sed -i 's|^command *=.*|command = "/usr/local/bin/lh-spike-greeter"|' /etc/greetd/config.toml
sudo rm -f /tmp/greetd-sock
sudo systemctl restart greetd
for _ in $(seq 20); do [ -s /tmp/greetd-sock ] && break; sleep 0.5; done
check "greetd_started_the_greeter_with_a_socket" '[ -s /tmp/greetd-sock ]'
export SOCK=$(cat /tmp/greetd-sock)

cat > /tmp/greeter.py <<'PY'
import json, os, socket, struct, sys
def talk(s, msg):
    data = json.dumps(msg).encode()
    s.sendall(struct.pack("=I", len(data)) + data)
    n = struct.unpack("=I", s.recv(4, socket.MSG_WAITALL))[0]
    return json.loads(s.recv(n, socket.MSG_WAITALL))
answers = sys.argv[1:]          # one answer per secret/visible question, in order
s = socket.socket(socket.AF_UNIX); s.connect(os.environ["SOCK"])
r = talk(s, {"type": "create_session", "username": "lhpam"})
while r.get("type") == "auth_message":
    kind, text = r["auth_message_type"], r["auth_message"]
    print(f"MSG {kind}: {text!r}", flush=True)
    if kind in ("secret", "visible"):
        r = talk(s, {"type": "post_auth_message_response", "response": answers.pop(0) if answers else ""})
    else:
        r = talk(s, {"type": "post_auth_message_response"})
print("END", json.dumps(r), flush=True)
if r.get("type") == "success" and os.environ.get("START") == "yes":
    r = talk(s, {"type": "start_session", "cmd": ["/bin/sleep", "20"], "env": []})
    print("START", json.dumps(r), flush=True)
else:
    talk(s, {"type": "cancel_session"})
PY

run() { sudo SOCK="$SOCK" python3 /tmp/greeter.py "$@" 2>&1; }

echo "--- wrong PIN"; out=$(run 111111); echo "$out"
check "a_wrong_pin_is_an_error_line_then_a_failure" 'grep -q "^MSG error: .Wrong PIN" <<<"$out" && grep -q "^END .*auth_error" <<<"$out"'
check "a_wrong_pin_does_not_fall_through_to_the_password" '! grep -q "^MSG secret: .Password" <<<"$out"'

echo "--- empty answer"; out=$(run "" "$PASS"); echo "$out"
check "an_empty_answer_falls_through_to_the_password" 'grep -q "^MSG secret: .Password" <<<"$out" && grep -q "^END .*\"success\"" <<<"$out"'

echo "--- Agent stopped"; sudo systemctl stop linuxhello-agent
out=$(run "$PASS"); echo "$out"; sudo systemctl start linuxhello-agent
check "with_the_agent_stopped_the_password_works" 'grep -q "^MSG secret: .Password" <<<"$out" && grep -q "^END .*\"success\"" <<<"$out"'

echo "--- right PIN"; out=$(run 246810); echo "$out"
check "the_modules_own_question_reaches_the_greeter_as_secret" 'grep -q "^MSG secret: .PIN" <<<"$out"'
check "a_right_pin_signs_in" 'grep -q "^END .*\"success\"" <<<"$out"'
sudo pkill -f lh-spike-greeter; sleep 3
loginctl list-sessions --no-legend; sudo journalctl -u greetd -n 15 --no-pager | cut -c1-200
# Not a check yet: greetd starts the scheduled session only once the greeter exits, and in the run
# of 2026-11-22 no session of lhpam appeared after the stand-in was killed (greetd restarted it).
echo "INFO sessions after start_session: $(loginctl list-sessions --no-legend | grep -c lhpam) of lhpam"

# Put greetd back as it was and stop it; the VM has no display to show it on.
sudo cp /etc/pam.d/greetd.orig /etc/pam.d/greetd
sudo systemctl stop greetd
sudo systemctl disable --now greetd >/dev/null 2>&1
echo "failed: $fail"
[ "$fail" -eq 0 ]
REMOTE
