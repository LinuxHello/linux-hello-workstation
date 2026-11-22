#!/usr/bin/env bash
# The checks are strings run by eval, which shellcheck does not read, so it cannot see their uses.
# shellcheck disable=SC2016,SC2034
# Spike 0311 in the desktop VM: a QML greeter (scripts/spike-0311/) under greetd and cage signs a
# person in with pam_linuxhello and starts Plasma on Wayland or Weston. Each state is run as greetd
# would show it to a person, a screenshot of the VM's screen is saved, and the greeter's log
# (every message greetd passed on, with its kind) is checked. Prints PASS or FAIL per check.
#
#   scripts/vm-test-greeter.sh [DIR]   screenshots go to DIR (default ./greeter-shots)
#
# Needs the desktop VM (scripts/vm-desktop.sh) with Linux Hello installed for login: run
# scripts/vm-test-pam-sudo.sh first (it installs and sets lhpam's PIN 246810), then in the VM
# scripts/prototype/install.sh --no-build --console. With LH_SPIKE_TPM_CLEAR=yes it also clears
# the VM's software TPM to show the tpm-cleared condition, and sets lhpam's PIN again afterwards.
# It changes only the VM: greetd's configuration, and greetd is stopped at the end.
set -euo pipefail
source "$(dirname "$0")/../common.sh"
vm="$(dirname "$0")/vm.sh"
here="$(dirname "$0")/spike-0311"
out="${1:-greeter-shots}"
mkdir -p "$out"
bash "$vm" status | grep -q '^running' || die "the VM is not running: scripts/vm.sh up"

for f in greeter.py greeter.qml; do
  bash "$vm" ssh "sudo mkdir -p /usr/local/share/lh-spike && sudo tee /usr/local/share/lh-spike/$f >/dev/null" < "$here/$f"
done

fail=0
check() { if eval "$2" >/dev/null 2>&1; then echo "PASS $1"; else echo "FAIL $1"; fail=$((fail + 1)); fi; }

# One state: greetd runs the greeter with these answers; "yes" starts the named desktop after.
run() {
  local answers=$1 start=$2 desktop=$3 before=$4
  bash "$vm" ssh "bash -s" <<REMOTE
set -e
sudo loginctl terminate-user lhpam 2>/dev/null || true
sudo systemctl stop greetd 2>/dev/null || true
sudo rm -f /var/lib/linuxhello/pinlock.toml /tmp/lh-spike-greeter.log
sudo systemctl restart linuxhello-agent
$before
sudo tee /etc/greetd/config.toml >/dev/null <<TOML
[terminal]
vt = 1
[default_session]
command = "env QT_QPA_PLATFORM=wayland LH_SPIKE_USER=lhpam LH_SPIKE_ANSWERS=$answers LH_SPIKE_DELAY=12 LH_SPIKE_START=$start LH_SPIKE_DESKTOP=$desktop cage -s -- python3 /usr/local/share/lh-spike/greeter.py"
user = "_greetd"
TOML
sudo systemctl stop getty@tty1 2>/dev/null || true
sudo systemctl reset-failed greetd 2>/dev/null || true
sudo systemctl start greetd
REMOTE
}
greeter_log() { bash "$vm" ssh "cat /tmp/lh-spike-greeter.log 2>/dev/null"; }

log "right PIN, then Plasma"
run 246810 yes Plasma ""
sleep 9; bash "$vm" screenshot "$out/01-question.png" >/dev/null
sleep 45; bash "$vm" screenshot "$out/02-plasma.png" >/dev/null
l=$(greeter_log)
check "the_modules_question_reaches_the_greeter_as_secret" 'grep -q "MSG secret .PIN: ." <<<"$l"'
check "a_right_pin_signs_in_and_plasma_starts_on_wayland" 'bash "$vm" ssh "pgrep -u lhpam -x kwin_wayland && pgrep -u lhpam -x plasmashell"'

log "wrong PIN"
run 111111 "" "" ""
sleep 22; bash "$vm" screenshot "$out/03-wrong-pin.png" >/dev/null
l=$(greeter_log)
check "a_wrong_pin_is_an_error_line_and_a_failure" 'grep -q "MSG error .Wrong PIN.." <<<"$l" && grep -q "auth_error" <<<"$l"'

log "the Agent stopped"
run "" "" "" "sudo systemctl stop linuxhello-agent"
sleep 8; bash "$vm" screenshot "$out/04-agent-stopped.png" >/dev/null
l=$(greeter_log)
check "a_stopped_agent_is_said_and_the_password_is_asked" 'grep -q "MSG info .Linux Hello is not available. Use your account password.." <<<"$l" && grep -q "MSG secret .Password: ." <<<"$l"'
bash "$vm" ssh 'sudo systemctl start linuxhello-agent'

log "right PIN, then Weston"
run 246810 yes Weston ""
sleep 40; bash "$vm" screenshot "$out/05-weston.png" >/dev/null
check "another_desktop_starts_from_the_same_greeter" 'bash "$vm" ssh "pgrep -u lhpam -x weston"'

if [[ "${LH_SPIKE_TPM_CLEAR:-}" == yes ]]; then
  log "a TPM that was cleared"
  run "" "" "" "sudo tpm2_clear -c l; sudo tpm2_dictionarylockout --setup-parameters --max-tries=100 --recovery-time=10 --lockout-recovery-time=10; sudo systemctl restart linuxhello-tpm-provider linuxhello-agent; sleep 2"
  sleep 8; bash "$vm" screenshot "$out/06-tpm-cleared.png" >/dev/null
  l=$(greeter_log)
  check "a_cleared_tpm_is_an_error_line_before_anything_is_typed" 'grep -q "MSG error .The TPM no longer holds the key" <<<"$l"'
  bash "$vm" ssh 'sudo systemctl stop greetd; U=$(id -u lhpam); sudo systemctl stop linuxhello-agent; sudo rm -rf /var/lib/linuxhello/users/$U; sudo systemctl start linuxhello-agent; sleep 2; printf "246810\n246810\n" | sudo -u lhpam linuxhello-ctl pin set >/dev/null'
fi

bash "$vm" ssh 'sudo loginctl terminate-user lhpam 2>/dev/null; sudo systemctl stop greetd' || true
log "screenshots in $out"
echo "failed: $fail"
[ "$fail" -eq 0 ]
