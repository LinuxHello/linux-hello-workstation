#!/usr/bin/env bash
# Spike linux-hello#121 in the test VM: what does the uhid helper cost in privilege, and how far can
# it be confined? A small Rust probe (scripts/uhid-probe.rs) stands in for the helper, and for a
# compromised one. Prints PASS/FAIL per check; a check named *_is_still_possible documents a gap that
# the profile cannot close. Exits non-zero if any check failed.
#
#   scripts/vm-test-uhid.sh        VM must be up: make vm-up
#
# It changes only the VM: a user lhctap, two udev rules, an AppArmor profile, the probe binary.
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
id lhctap >/dev/null 2>&1 || useradd -r -M -s /usr/sbin/nologin lhctap
rm -f /etc/udev/rules.d/70-lh-uhid.rules /etc/udev/rules.d/72-lh-uhid-no-input.rules
chown root:root /dev/uhid; chmod 600 /dev/uhid
apparmor_parser -R /etc/apparmor.d/lh-uhid-probe 2>/dev/null
reload() { udevadm control --reload; udevadm trigger --subsystem-match=misc --action=add; udevadm settle; sleep 1; }
reset_node() { chown root:root /dev/uhid; chmod 600 /dev/uhid; }   # udev does not undo a mode a removed rule set
as() { sudo -u lhctap "$@"; }
event_node() { ls -d /sys/devices/virtual/misc/uhid/*/input/input*/event* 2>/dev/null | head -1 | xargs -r basename; }
props() { udevadm info -q property -n /dev/input/$1; }
input_sys() { ls -d /sys/devices/virtual/misc/uhid/*/input/input* 2>/dev/null | head -1; }
tags() { udevadm info -q property -p "$(input_sys)" | grep ^CURRENT_TAGS=; }

# 1. The default: /dev/uhid is root-only.
check "by_default_an_unprivileged_user_cannot_create_a_uhid_device" 'as $P fido 1 | grep -q "cannot open /dev/uhid"'

# 2. Minimal grant: the helper's group may open /dev/uhid, nothing else changes.
echo 'KERNEL=="uhid", GROUP="lhctap", MODE="0660"' > /etc/udev/rules.d/70-lh-uhid.rules
reload
check "a_udev_rule_gives_the_helpers_group_the_device_and_no_one_else" '[ "$(stat -c "%G %a" /dev/uhid)" = "lhctap 660" ]'
(as $P fido 4 > /tmp/fido.out 2>&1 &) ; sleep 1.5
check "the_unprivileged_helper_creates_a_fido_device" 'fido2-token -L | grep -qi "vendor=0x1209, product=0xf1d0"'
sleep 4

# 3. AppArmor profile: /dev/uhid and nothing else.
cat > /etc/apparmor.d/lh-uhid-probe <<'PROFILE'
abi <abi/4.0>,
include <tunables/global>
profile lh-uhid-probe /usr/local/libexec/linuxhello/uhid-probe {
  include <abstractions/base>
  /usr/local/libexec/linuxhello/uhid-probe mr,
  /dev/uhid rw,
  deny network,
  deny capability,
  deny ptrace,
  deny /home/** rwklx,
  deny /root/** rwklx,
}
PROFILE
apparmor_parser -r /etc/apparmor.d/lh-uhid-probe
T0=$(date +%s)
(as $P fido 5 > /tmp/fido2.out 2>&1 &) ; sleep 1.5
PID=$(pgrep -n -f "uhid-probe fido")
check "the_helper_runs_in_enforce_mode_under_its_profile" 'grep -q "^lh-uhid-probe (enforce)" /proc/$PID/attr/current'
check "the_confined_helper_still_creates_its_fido_device" 'fido2-token -L | grep -qi "product=0xf1d0"'
sleep 5
check "the_profile_denies_the_tpm_to_root" '$P open /dev/tpmrm0 | grep -q denied'
check "the_profile_denies_a_home_directory_to_root" '$P open /home/lh/.bashrc | grep -q denied'
check "the_profile_denies_the_password_hashes_to_root" '$P open /etc/shadow | grep -q denied'
check "the_profile_denies_the_network" '$P net | grep -q denied'
check "apparmor_logged_the_denials" 'journalctl -k --no-pager --since "@$T0" | grep "apparmor=\"DENIED\"" | grep -q lh-uhid-probe'

# 4. A systemd sandbox of the kind the unit would use still lets the helper work.
check "a_closed_device_policy_with_only_uhid_allowed_still_works" 'systemd-run --quiet --wait --pipe -p User=lhctap -p DevicePolicy=closed -p "DeviceAllow=/dev/uhid rw" -p PrivateNetwork=yes -p NoNewPrivileges=yes -p ProtectHome=yes -p ProtectSystem=strict -p CapabilityBoundingSet= $P fido 1 | grep -q "created fido"'

# 5. What a compromised helper can still do. The kernel does not look at the descriptor.
OUT=$(as $P swap 3 2>&1)
echo "INFO swap: $(echo "$OUT" | tr '\n' ' ')"
check "a_second_device_on_a_live_fd_is_refused" 'echo "$OUT" | grep -q "while the first is alive: refused"'
check "recreating_a_different_device_after_destroy_is_still_possible" 'echo "$OUT" | grep -q "after destroy on the same fd: allowed"'
sleep 4
(as $P keyboard 6 > /tmp/kbd.out 2>&1 &) ; sleep 2
EV=$(event_node)
check "a_keyboard_device_under_the_profile_is_still_possible" '[ -n "$EV" ] && props $EV | grep -q "ID_INPUT_KEYBOARD=1"'
echo "INFO keyboard without the input rule: $(props $EV | grep -E "^(ID_INPUT_KEYBOARD|LIBINPUT_IGNORE_DEVICE)=" | tr '\n' ' ') $(tags)"
check "without_the_rule_a_uhid_keyboard_is_on_the_seat" 'tags | grep -q ":seat:"'
sleep 6

# 6. The mitigation: a udev rule that makes the session ignore any input device from uhid.
cat > /etc/udev/rules.d/72-lh-uhid-no-input.rules <<'RULE'
# Linux Hello: a uhid device is a security key, not a keyboard. Input devices made through uhid are
# hidden from libinput and from the seat, so a compromised helper cannot type into a session.
SUBSYSTEM=="input", DEVPATH=="*/virtual/misc/uhid/*", ENV{ID_INPUT}="", ENV{ID_INPUT_KEY}="", ENV{ID_INPUT_KEYBOARD}="", ENV{ID_INPUT_MOUSE}="", ENV{ID_INPUT_TOUCHPAD}="", ENV{ID_INPUT_JOYSTICK}="", ENV{LIBINPUT_IGNORE_DEVICE}="1", TAG-="seat", TAG-="uaccess", TAG-="power-switch"
RULE
reload
(as $P keyboard 6 > /tmp/kbd2.out 2>&1 &) ; sleep 2
EV=$(event_node)
echo "INFO keyboard with the input rule:    $(props $EV | grep -E "^(ID_INPUT_KEYBOARD|LIBINPUT_IGNORE_DEVICE)=" | tr '\n' ' ') $(tags)"
check "the_input_rule_hides_a_uhid_keyboard_from_libinput" '[ -n "$EV" ] && props $EV | grep -q "LIBINPUT_IGNORE_DEVICE=1" && ! props $EV | grep -q "ID_INPUT_KEYBOARD=1"'
check "the_input_rule_keeps_a_uhid_keyboard_off_the_seat" '! tags | grep -q ":seat:"'
sleep 6
(as $P fido 5 > /tmp/fido3.out 2>&1 &) ; sleep 1.5
check "the_input_rule_leaves_the_fido_device_working" 'fido2-token -L | grep -qi "product=0xf1d0"'
sleep 5

rm -f /etc/udev/rules.d/70-lh-uhid.rules /etc/udev/rules.d/72-lh-uhid-no-input.rules; reload; reset_node
[ "$fail" -eq 0 ] && echo "ALL PASSED" || echo "$fail FAILED"
exit "$fail"
REMOTE
