#!/usr/bin/env bash
# Spike linux-hello#138 in the test VM: can the virtual FIDO device be bound to one user and one
# session? The probe of scripts/uhid-probe.rs stands in for the helper. Prints PASS/FAIL per check
# and INFO lines for what was measured. Exits non-zero if a check failed.
#
#   scripts/vm-test-uhid-session.sh        VM must be up: make vm-up
#
# It changes only the VM: users lhctap and lhb, two udev rules, the probe binary. It reverts the rules.
# Needs the uhid kernel module (linux-modules-extra-<kernel>) in the VM; the script loads it.
set -euo pipefail
source "$(dirname "$0")/../common.sh"
vm="$(dirname "$0")/vm.sh"
here="$(cd "$(dirname "$0")" && pwd)"
bash "$vm" status | grep -q '^running' || die "the VM is not running: make vm-up"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
log "building the probe (static, musl)"
(cd "$CLONE_DIR" && rustc --edition 2021 -O --target x86_64-unknown-linux-musl -o "$work/uhid-probe" "$here/uhid-probe.rs") \
  || die "build failed (musl target missing? see scripts/vm-test-agent.sh)"
bash "$vm" ssh 'cat > ~/uhid-probe' < "$work/uhid-probe"

bash "$vm" ssh 'sudo -H bash -s' <<'REMOTE'
set +e
fail=0
check() { if eval "$2" >/dev/null 2>&1; then echo "PASS $1"; else echo "FAIL $1"; fail=$((fail + 1)); fi; }
P=/usr/local/libexec/linuxhello/uhid-probe
install -D -m755 /home/lh/uhid-probe $P
modprobe uhid || { apt-get install -y -q linux-modules-extra-$(uname -r) >/dev/null 2>&1; modprobe uhid; }
id lhctap >/dev/null 2>&1 || useradd -r -M -s /usr/sbin/nologin lhctap
id lhb >/dev/null 2>&1 || useradd -m -s /usr/sbin/nologin lhb
UA=$(id -u lh); UB=$(id -u lhb)
R1=/etc/udev/rules.d/70-lh-uhid.rules; R2=/etc/udev/rules.d/71-lh-session-key.rules
rm -f $R1 $R2
echo 'KERNEL=="uhid", GROUP="lhctap", MODE="0660"' > $R1
reload() { udevadm control --reload; udevadm trigger --subsystem-match=misc --action=add; udevadm settle; sleep 1; }
reload
now() { date +%s.%N; }
# The hidraw node whose uniq string names the user: /dev/hidrawN.
node_of() { for d in /sys/class/hidraw/hidraw*; do grep -q "HID_UNIQ=linuxhello-uid-$1\$" $d/device/uevent 2>/dev/null && echo /dev/$(basename $d) && return; done; }
wait_node() { for _ in $(seq 50); do n=$(node_of $1); [ -n "$n" ] && { echo $n; return; }; sleep 0.1; done; }
wait_gone() { for _ in $(seq 100); do [ -z "$(node_of $1)" ] && return 0; sleep 0.02; done; return 1; }
can_open() { sudo -u $1 python3 -c 'import os,sys; os.close(os.open(sys.argv[1], os.O_RDWR))' $2; }
helper() { sudo -u lhctap $P owned "$@" >/dev/null 2>&1 & echo $!; }
tags() { udevadm info -q property -n $1 | grep -E "^(TAGS|CURRENT_TAGS)=" | tr '\n' ' '; }

# 1. What a distribution gives the node when nothing special is configured.
H=$(helper $UA 30); N=$(wait_node $UA)
echo "INFO default node: $(stat -c '%U:%G %a' $N) $(tags $N) $(udevadm info -q property -n $N | grep ID_SECURITY_TOKEN)"
check "by_default_the_node_is_tagged_for_the_seat_user" 'tags $N | grep -q uaccess'
pkill -9 -f "uhid-probe owned"; wait_gone $UA

# 2. One udev rule keyed on the per-device uniq string: the owner is the named uid, nobody else.
cat > $R2 <<'RULE'
# Linux Hello: a virtual security key belongs to the user named in its uniq string, not to the seat.
SUBSYSTEM=="hidraw", IMPORT{parent}="HID_UNIQ"
SUBSYSTEM=="hidraw", ENV{HID_UNIQ}=="linuxhello-uid-*", IMPORT{program}="/bin/sh -c 'echo LH_UID=$${HID_UNIQ#linuxhello-uid-}'", OWNER="$env{LH_UID}", GROUP="root", MODE="0600", TAG-="uaccess"
RULE
reload
H=$(helper $UA 30); N=$(wait_node $UA)
echo "INFO rule node: $(stat -c '%U:%G %a' $N) $(tags $N)"
check "the_node_is_owned_by_the_named_user_and_closed_to_everyone_else" '[ "$(stat -c "%u %a" $N)" = "$UA 600" ]'
check "the_node_is_not_tagged_for_the_seat" '! udevadm info -q property -n $N | grep "^CURRENT_TAGS=" | grep -q uaccess'
check "the_node_is_still_a_security_token_for_snap_browsers" 'udevadm info -q property -n $N | grep -q "^ID_SECURITY_TOKEN=1" && tags $N | grep -q snap_firefox_firefox'
check "the_named_user_can_open_the_node" 'can_open lh $N'
check "a_second_user_cannot_open_the_node" '! can_open lhb $N'
check "the_helper_itself_cannot_open_the_node_it_made" '! can_open lhctap $N'

# 3. Two users at once: each node is its own.
H2=$(helper $UB 30); N2=$(wait_node $UB)
check "a_second_user_gets_a_second_node_owned_by_that_user" '[ -n "$N2" ] && [ "$N2" != "$N" ] && [ "$(stat -c %u $N2)" = "$UB" ]'
check "the_first_user_cannot_open_the_second_users_node" '! can_open lh $N2'
check "the_second_user_cannot_open_the_first_users_node" '! can_open lhb $N'
pkill -9 -f "uhid-probe owned"; wait_gone $UA; wait_gone $UB

# 4. Removal: when the helper dies, and on request.
H=$(helper $UA 30); N=$(wait_node $UA)
T=$(now); pkill -9 -f "uhid-probe owned"; wait_gone $UA; R=$?; E=$(now)
echo "INFO helper killed: node gone after $(awk -v a=$T -v b=$E 'BEGIN{printf "%.2f", b-a}') s"
check "a_killed_helper_takes_its_node_with_it_within_a_second" '[ $R = 0 ] && awk -v a=$T -v b=$E "BEGIN{exit !(b-a<1)}"'
H=$(helper $UA 2); N=$(wait_node $UA)
T=$(now); wait_gone $UA; R=$?; E=$(now)
echo "INFO explicit destroy: node gone $(awk -v a=$T -v b=$E 'BEGIN{printf "%.2f", b-a}') s after the wait began (helper lived 2 s)"
check "an_explicit_destroy_removes_the_node" '[ $R = 0 ]'

# 5. Lock: a controller (root here; the Agent in the design) watches the session's LockedHint and ends
#    the device.
cat > /tmp/lh-controller.py <<'PY'
import os, sys, time, dbus, dbus.mainloop.glib
from gi.repository import GLib
pid = int(sys.argv[1])
dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
bus = dbus.SystemBus()
mgr = dbus.Interface(bus.get_object("org.freedesktop.login1", "/org/freedesktop/login1"), "org.freedesktop.login1.Manager")
path = str(mgr.GetSession(sys.argv[2]))
def changed(iface, props, inval):
    if iface == "org.freedesktop.login1.Session" and (props.get("LockedHint") or props.get("Active") == False):
        os.kill(pid, 9)
        print("signal at", time.time(), flush=True)
        loop.quit()
bus.add_signal_receiver(changed, "PropertiesChanged", "org.freedesktop.DBus.Properties", "org.freedesktop.login1", path)
print("watching", path, flush=True)
loop = GLib.MainLoop()
GLib.timeout_add_seconds(20, loop.quit)
loop.run()
PY
H=$(helper $UA 30); N=$(wait_node $UA)
SID=$(loginctl --no-legend | awk '$2==1000{print $1; exit}')
python3 /tmp/lh-controller.py $(pgrep -n -u lhctap -x uhid-probe) $SID > /tmp/lh-controller.out 2>&1 &
sleep 2
check "the_controller_sees_the_session" 'grep -q watching /tmp/lh-controller.out'
T=$(now); sudo -u lh busctl --system call org.freedesktop.login1 /org/freedesktop/login1/session/auto org.freedesktop.login1.Session SetLockedHint b true >/dev/null
TC=$(now)
wait_gone $UA; R=$?; E=$(now)
echo "INFO lock: busctl returned after $(awk -v a=$T -v b=$TC 'BEGIN{printf "%.2f", b-a}') s; $(grep "signal at" /tmp/lh-controller.out | awk -v a=$T '{printf "controller saw it %.2f s after the call began", $3-a}')"
echo "INFO lock: node gone after $(awk -v a=$T -v b=$E 'BEGIN{printf "%.2f", b-a}') s"
check "locking_the_session_removes_the_node_within_a_second" '[ $R = 0 ] && awk -v a=$T -v b=$E "BEGIN{exit !(b-a<1)}"'
sudo -u lh busctl --system call org.freedesktop.login1 /org/freedesktop/login1/session/auto org.freedesktop.login1.Session SetLockedHint b false >/dev/null
wait

# 6. A real seat: two sessions on seat0, on virtual terminals 7 (lhb) and 8 (lh). The user whose
#    session is in front owns the seat; logind gives that user an ACL on every node tagged "uaccess".
seat_session() { # user, vt: starts a login session on the seat and prints its id
  systemd-run -q --unit=lhseat-$2 -p PAMName=login -p User=$1 -p TTYPath=/dev/tty$2 -p StandardInput=tty -p TTYReset=yes sleep 600
  for _ in $(seq 50); do id=$(loginctl --no-legend list-sessions | awk -v u=$1 '$3==u && $4=="seat0" {print $1}'); [ -n "$id" ] && { echo $id; return; }; sleep 0.1; done
}
SB=$(seat_session lhb 7); SA=$(seat_session lh 8)
chvt 7; sleep 1
check "both_sessions_are_on_the_seat_and_the_second_users_is_in_front" '[ -n "$SA" ] && [ -n "$SB" ] && [ "$(loginctl show-session $SB -p Active --value)" = yes ] && [ "$(loginctl show-session $SA -p Active --value)" = no ]'

# 6a. Without the rule: a key made for lh while lhb is in front.
rm -f $R2; udevadm control --reload
H=$(helper $UA 30); N=$(wait_node $UA)
echo "INFO seat default: $(stat -c '%U:%G %a' $N) lhb-can-open=$(can_open lhb $N && echo yes || echo no) lh-can-open=$(can_open lh $N && echo yes || echo no)"
check "by_default_the_user_in_front_on_the_seat_can_open_another_users_key" 'can_open lhb $N'
pkill -9 -x uhid-probe; wait_gone $UA

# 6b. Removing the tag in a rule that runs after 70-uaccess (this is the shape the real rule takes).
R3=/etc/udev/rules.d/71-lh-late.rules
cat > $R3 <<'RULE'
SUBSYSTEM=="hidraw", IMPORT{parent}="HID_UNIQ"
SUBSYSTEM=="hidraw", ENV{HID_UNIQ}=="linuxhello-uid-*", TAG-="uaccess"
RULE
udevadm control --reload
H=$(helper $UA 30); N=$(wait_node $UA)
echo "INFO late tag removal: $(tags $N) lhb-can-open=$(can_open lhb $N && echo yes || echo no)"
pkill -9 -x uhid-probe; wait_gone $UA
rm -f $R3

# 6c. The rule of step 2.
cat > $R2 <<'RULE'
# Linux Hello: a virtual security key belongs to the user named in its uniq string, not to the seat.
SUBSYSTEM=="hidraw", IMPORT{parent}="HID_UNIQ"
SUBSYSTEM=="hidraw", ENV{HID_UNIQ}=="linuxhello-uid-*", IMPORT{program}="/bin/sh -c 'echo LH_UID=$${HID_UNIQ#linuxhello-uid-}'", OWNER="$env{LH_UID}", GROUP="root", MODE="0600", TAG-="uaccess"
RULE
udevadm control --reload
H=$(helper $UA 30); N=$(wait_node $UA)
check "with_the_rule_the_user_in_front_on_the_seat_cannot_open_another_users_key" '! can_open lhb $N'
check "with_the_rule_the_owner_can_open_its_key_while_another_user_is_in_front" 'can_open lh $N'
pkill -9 -x uhid-probe; wait_gone $UA

# 6d. Switching away: the controller ends the device when the owner's session leaves the front.
chvt 8; sleep 1
H=$(helper $UA 30); N=$(wait_node $UA)
python3 /tmp/lh-controller.py $(pgrep -n -u lhctap -x uhid-probe) $SA > /tmp/lh-controller.out 2>&1 &
sleep 2
check "the_owner_is_in_front_and_has_its_key" '[ "$(loginctl show-session $SA -p Active --value)" = yes ] && [ -n "$(node_of $UA)" ]'
T=$(now); chvt 7
wait_gone $UA; R=$?; E=$(now)
echo "INFO switch: node gone after $(awk -v a=$T -v b=$E 'BEGIN{printf "%.2f", b-a}') s"
check "switching_to_another_user_removes_the_node_within_a_second" '[ $R = 0 ] && awk -v a=$T -v b=$E "BEGIN{exit !(b-a<1)}"'
wait

systemctl stop lhseat-7 lhseat-8; chvt 1

rm -f $R1 $R2 /tmp/lh-controller.py; reload
chown root:root /dev/uhid; chmod 600 /dev/uhid
[ "$fail" -eq 0 ] && echo "ALL PASSED" || echo "$fail FAILED"
exit "$fail"
REMOTE
