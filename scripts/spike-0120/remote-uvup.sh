#!/usr/bin/env bash
# Runs inside the test VM as root (started by scripts/vm-test-uvup.sh). Spike linux-hello#120.
# PASS/FAIL per check; INFO lines are measurements and browser behaviour; a check named *_is_still_possible
# documents something the design does not stop. Exits non-zero if a check failed.
#   LH_UVUP_QUICK=1      skip the 62 s wait for the 60 s cap and the browser matrix
set +e
exec 2> >(grep -v "^Terminated$" >&2)   # bash reports the background jobs the test kills
H=/home/lh/spike120
PY=/home/lh/pw/bin/python
EV=/var/lib/lhctap2/events.jsonl
export DEBIAN_FRONTEND=noninteractive
fail=0
check() { if eval "$2" >/dev/null 2>&1; then echo "PASS $1"; else echo "FAIL $1"; fail=$((fail + 1)); fi; }
info() { echo "INFO $*"; }
cat > /usr/local/bin/aslh <<'WRAP'
#!/bin/sh
exec sudo -u lh -H env DISPLAY=:99 PLAYWRIGHT_BROWSERS_PATH=/opt/pw-browsers "$@"
WRAP
chmod +x /usr/local/bin/aslh
ctl() { python3 $H/lhctl "$@"; sleep 0.4; }
raw() { aslh $PY $H/ctapraw.py "$@" 2>&1; }
field() { python3 -c "import sys,json; d=json.loads(sys.stdin.read().strip().splitlines()[-1]); print(eval(sys.argv[1]))" "$1" 2>/dev/null; }
mark() { N0=$(wc -l < $EV); }
# count events since mark() for which the python predicate over e (a dict) is true
evq() { tail -n +$((N0 + 1)) $EV | python3 -c "import sys,json; es=[json.loads(l) for l in sys.stdin]; print(sum(1 for e in es if $1))"; }
signatures() { evq 'e["ev"]=="signed" and not e.get("silent")'; }
prompts() { evq 'e["ev"]=="gesture"'; }

# ---- provisioning (idempotent) -----------------------------------------------------------------
need=""; for p in fido2-tools xdotool python3-tk gdb x11-utils xinput apparmor-utils imagemagick python3-venv build-essential strace; do dpkg -s $p >/dev/null 2>&1 || need="$need $p"; done
[ -n "$need" ] && { info "installing:$need"; apt-get update -qq >/dev/null 2>&1; apt-get install -y -qq $need >/dev/null 2>&1; }
if [ ! -x $PY ]; then sudo -u lh python3 -m venv /home/lh/pw && sudo -u lh /home/lh/pw/bin/pip install -q playwright fido2; fi
$PY -c "import fido2" 2>/dev/null || sudo -u lh /home/lh/pw/bin/pip install -q fido2
if [ -z "$LH_UVUP_QUICK" ] && [ ! -d /opt/pw-browsers/firefox-1555 ]; then
  /home/lh/pw/bin/playwright install-deps chromium firefox >/dev/null 2>&1
  PLAYWRIGHT_BROWSERS_PATH=/opt/pw-browsers /home/lh/pw/bin/playwright install chromium firefox >/dev/null 2>&1; chmod -R a+rX /opt/pw-browsers
fi
modprobe uhid 2>/dev/null
install -D -m755 $H/lh-prompt-stub /usr/local/libexec/linuxhello/lh-prompt-stub
cp $H/lh-prompt-stub.apparmor /etc/apparmor.d/lh-prompt-stub && apparmor_parser -r /etc/apparmor.d/lh-prompt-stub
gcc -shared -fPIC -o /home/lh/evil.so $H/evil.c
pgrep -x Xvfb >/dev/null || aslh bash -c 'nohup Xvfb :99 -screen 0 1280x800x24 >/tmp/xvfb.log 2>&1 &'
pgrep -f "[h]ttp.server 8000" >/dev/null || aslh bash -c "cd $H && nohup python3 -m http.server 8000 >/tmp/http.log 2>&1 &"
sleep 1

want() { case " ${LH_UVUP_SECTIONS:-A B C} " in *" $1 "*) return 0;; esac; return 1; }   # LH_UVUP_SECTIONS="A C" runs part of it

# ---- helpers for the Agent and the simulated person ------------------------------------------------
person() { pkill -f "[l]huser.py" 2>/dev/null; sleep 0.3; [ "$1" = none ] && return; aslh bash -c "cd $H && nohup python3 lhuser.py $1 ${2:-123456} >/tmp/user.log 2>&1 &"; sleep 0.5; }
daemon() {   # daemon MODE [VAR=value ...]
  local m=$1; shift
  pkill -f "[l]hctap2.py" 2>/dev/null; pkill -f "[l]h-prompt-stub" 2>/dev/null; person none; sleep 1; rm -rf /var/lib/lhctap2; mkdir -p /var/lib/lhctap2; tpm2_dictionarylockout --clear-lockout >/dev/null 2>&1
  ( cd $H && env -i PATH=/usr/bin:/bin LH_PIN=123456 LH_MODE=$m LH_GESTURE_TIMEOUT=${LH_GESTURE_TIMEOUT:-6} "LH_PROMPT_LABEL=${LABEL-lh-prompt-stub (enforce)}" "$@" nohup python3 lhctap2.py > /var/lib/lhctap2/daemon.log 2>&1 & )
  for _ in $(seq 40); do fido2-token -L 2>/dev/null | grep -qi "product=0xf1d0" && break; sleep 0.5; done
  chmod 666 /dev/hidraw* 2>/dev/null; sleep 0.5; mark
}
tpm_lockout() { tpm2_getcap properties-variable 2>/dev/null | grep 'TPM2_PT_LOCKOUT_COUNTER' | head -1 | tr -d ' '; }
tpm2_dictionarylockout --clear-lockout >/dev/null 2>&1

info "environment: $(. /etc/os-release; echo $PRETTY_NAME), kernel $(uname -r), tpm2-tools $(tpm2_getcap -v 2>&1 | head -1 | tr -d '\n'), fido2-tools $(dpkg -s fido2-tools | sed -n 's/^Version: //p'), python-fido2 $($PY -c 'import importlib.metadata as m; print(m.version("fido2"))'), $(apparmor_parser --version | head -1), swtpm TPM (software)"

# ======================= A. the authenticator =====================================================
if want A; then
echo "== A. getInfo, resident keys, presence, user verification, the 60 s cap"
daemon click
person click
OUT=$(raw info)
check "getinfo_advertises_resident_keys_and_user_presence" 'echo "$OUT" | field "d[\"options\"][\"rk\"] and d[\"options\"][\"up\"]" | grep -q True'
check "a_click_only_agent_does_not_advertise_user_verification" 'echo "$OUT" | field "d[\"options\"][\"uv\"]" | grep -q False'
ctl mode sensor; OUT=$(raw info)
check "an_agent_with_a_sensor_advertises_user_verification" 'echo "$OUT" | field "d[\"options\"][\"uv\"]" | grep -q True'
ctl mode click; ctl forget; ctl unlock
check "a_verification_event_makes_uv_available_for_a_while" 'raw info | field "d[\"options\"][\"uv\"]" | grep -q True'
ctl forget
check "without_a_verification_event_uv_is_not_advertised" 'raw info | field "d[\"options\"][\"uv\"]" | grep -q False'

mark; person click
M=$(raw make --rk); CID=$(echo "$M" | field 'd["cred_id"]')
check "a_resident_credential_is_created_and_the_id_is_a_short_handle_not_the_key_blobs" '[ "$(echo "$M" | field "d[\"id_len\"]")" -le 32 ]'
check "the_credential_index_holds_the_resident_credential_and_its_user" 'python3 -c "import json; i=json.load(open(\"/var/lib/lhctap2/index.json\")); assert len(i)==1 and i[0][\"rp\"]==\"localhost\" and i[0][\"user\"][\"name\"]==\"alice4\""'
check "create_prompted_once_and_signed_once" '[ "$(prompts)" = 1 ] && [ "$(signatures)" = 1 ]'
mark
G=$(raw get)
check "a_get_without_an_allow_list_finds_the_discoverable_credential_and_returns_the_user" 'echo "$G" | field "d[\"user\"][\"id\"]" | grep -q 01020304'
check "a_get_without_an_allow_list_sets_up_and_not_uv_after_a_click" 'echo "$G" | field "d[\"flags\"][\"UP\"]==1 and d[\"flags\"][\"UV\"]==0" | grep -q True'
G=$(raw get --allow=$CID)
check "a_get_with_the_handle_in_the_allow_list_works" 'echo "$G" | field "d[\"ok\"]" | grep -q True'
check "a_credential_of_another_relying_party_is_not_found" 'raw get --rp=other.test | field "d[\"code\"]" | grep -q 0x2e'
mark; for i in 1 2 3; do raw get --allow=$CID >/dev/null; done
check "every_request_prompts_once_and_signs_once_three_requests_three_prompts" '[ "$(prompts)" = 3 ] && [ "$(signatures)" = 3 ]'

echo "-- presence cannot be skipped"
person none; mark
G=$(raw get --allow=$CID)
check "with_nobody_answering_the_prompt_the_request_fails_with_no_signature" 'echo "$G" | field "d[\"ok\"]" | grep -q False && [ "$(signatures)" = 0 ]'
person deny; mark
G=$(raw get --allow=$CID)
check "a_denied_prompt_is_operation_denied_and_nothing_is_signed" 'echo "$G" | field "d[\"code\"]" | grep -q 0x27 && [ "$(signatures)" = 0 ]'
person click

echo "-- user verification"
ctl forget; mark
G=$(raw get --allow=$CID --uv)
check "uv_is_refused_when_nothing_verified_the_user_a_click_is_not_verification" 'echo "$G" | field "d[\"ok\"]" | grep -q False && [ "$(signatures)" = 0 ]'
ctl mode sensor; person touch; mark
G=$(raw get --allow=$CID --uv)
check "a_sensor_match_for_this_request_gives_uv_1" 'echo "$G" | field "d[\"flags\"][\"UV\"]" | grep -q 1 && [ "$(evq "e[\"ev\"]==\"signed\" and e.get(\"uv_why\")==\"this_request\"")" = 1 ]'
mark; M=$(raw make --rk --uv --user 7)
check "a_resident_create_with_uv_required_sets_uv_1_after_a_sensor_match" 'echo "$M" | field "d[\"flags\"][\"UV\"]" | grep -q 1'
ctl mode pin; person pin 123456; mark
G=$(raw get --allow=$CID --uv)
check "the_right_pin_typed_into_the_prompt_gives_uv_1" 'echo "$G" | field "d[\"flags\"][\"UV\"]" | grep -q 1'
person pin 000000; L0=$(tpm_lockout); mark
G=$(raw get --allow=$CID --uv)
check "a_wrong_pin_typed_into_the_prompt_gives_no_signature" 'echo "$G" | field "d[\"ok\"]" | grep -q False && [ "$(signatures)" = 0 ]'
check "a_wrong_pin_counts_as_an_attempt_in_the_tpm" '[ "$(tpm_lockout)" != "$L0" ]'
tpm2_dictionarylockout --clear-lockout >/dev/null 2>&1

echo "-- the UV window (hard cap 60 s, policy may shorten)"
ctl mode click; person click; ctl window 60; ctl unlock; mark
G=$(raw get --allow=$CID --uv)
check "within_the_window_after_a_verification_event_uv_is_1" 'echo "$G" | field "d[\"flags\"][\"UV\"]" | grep -q 1 && [ "$(evq "e[\"ev\"]==\"signed\" and e.get(\"uv_why\")==\"window\"")" = 1 ]'
check "within_the_window_presence_is_still_asked_for_on_every_request" '[ "$(prompts)" = 1 ]'
ctl window 3; ctl unlock; sleep 4; mark
G=$(raw get --allow=$CID --uv)
check "a_policy_window_of_3_s_is_over_after_4_s" 'echo "$G" | field "d[\"ok\"]" | grep -q False && [ "$(signatures)" = 0 ]'
ctl window 600
check "a_policy_window_of_600_s_is_capped_to_60_s_in_effect" 'tail -1 $EV | python3 -c "import sys,json; e=json.loads(sys.stdin.read()); assert e[\"policy_window\"]==600 and e[\"window\"]==60"'
ctl window inf; check "a_policy_window_of_inf_is_capped_to_60_s" 'tail -1 $EV | python3 -c "import sys,json; e=json.loads(sys.stdin.read()); assert e[\"window\"]==60"'
ctl window nan; check "a_nan_window_means_no_window" 'tail -1 $EV | python3 -c "import sys,json; e=json.loads(sys.stdin.read()); assert e[\"window\"]==0"'
ctl window -5; check "a_negative_window_means_no_window" 'tail -1 $EV | python3 -c "import sys,json; e=json.loads(sys.stdin.read()); assert e[\"window\"]==0"'
if [ -z "$LH_UVUP_QUICK" ]; then
  ctl window 600; ctl unlock; mark; T0=$(date +%s)
  G=$(raw get --allow=$CID --uv); check "at_about_2_s_a_600_s_policy_window_is_open" 'echo "$G" | field "d[\"flags\"][\"UV\"]" | grep -q 1'
  sleep $((62 - ($(date +%s) - T0))); mark
  G=$(raw get --allow=$CID --uv)
  check "at_62_s_after_the_verification_a_600_s_policy_window_is_closed_the_cap_holds" 'echo "$G" | field "d[\"ok\"]" | grep -q False && [ "$(signatures)" = 0 ]'
fi
ctl window 60; ctl forget

echo "-- one signature per request"
ctl mode click; person click; mark
raw get --allow=$CID --times 2 > /tmp/twice.out
check "an_identical_getassertion_repeated_on_one_channel_prompts_once_and_signs_once" '[ "$(prompts)" = 1 ] && [ "$(signatures)" = 1 ] && [ "$(evq "e[\"ev\"]==\"replayed\"")" = 1 ]'
mark; raw get --allow=$CID >/dev/null; raw get --allow=$CID >/dev/null
check "two_different_requests_prompt_and_sign_twice_the_repeat_rule_is_not_a_cache" '[ "$(prompts)" = 2 ] && [ "$(signatures)" = 2 ]'
person none; mark
( raw get --allow=$CID > /tmp/busy1.out & ); sleep 2
B=$(raw get --allow=$CID)
check "a_second_client_while_a_prompt_is_open_gets_channel_busy_and_no_second_prompt" 'echo "$B" | grep -qi "busy" && [ "$(prompts)" -le 1 ]'
sleep 6
person click
echo "-- more than one discoverable credential for a relying party, and the provider choice"
daemon click; person click
raw make --rk --user 8 >/dev/null; ctl provider kpxc-standin; raw make --rk --user 9 >/dev/null; ctl provider tpm
ctl choose 0; mark
N=$(raw get)
check "without_a_prompt_choice_two_resident_credentials_give_number_of_credentials_2_one_prompt_two_signatures" 'echo "$N" | head -1 | field "d[\"number_of_credentials\"]" | grep -q 2 && [ "$(prompts)" = 1 ] && [ "$(signatures)" = 2 ]'
info "without a prompt choice the Agent signs for every credential for the relying party although the user picks one in the browser: $(echo "$N" | wc -l) responses, $(signatures) signatures after one prompt"
ctl choose 1; person choose1; mark
N=$(raw get)
check "with_a_prompt_choice_the_user_picks_one_of_two_providers_credentials_in_the_prompt_ui" 'echo "$N" | field "d[\"user\"][\"id\"]" | grep -q 01020308'
check "with_a_prompt_choice_one_prompt_gives_exactly_one_signature_and_no_number_of_credentials" '[ "$(prompts)" = 1 ] && [ "$(signatures)" = 1 ] && echo "$N" | field "d[\"number_of_credentials\"]" | grep -q None'
person choose0; mark
N=$(raw get)
info "choose0 answered: $(echo "$N" | cut -c1-150); events: $(tail -n +$((N0+1)) $EV | cut -c1-160 | tr '\n' ' ')"
check "choosing_the_other_credential_returns_the_other_user" 'echo "$N" | field "d[\"user\"][\"id\"]" | grep -q 01020309'

fi
# ======================= B. browsers ==================================================================
if want B && [ -z "$LH_UVUP_QUICK" ]; then
echo "== B. browsers (Playwright builds, headed, Xvfb, page on http://localhost:8000)"
browser() {   # browser NAME MODE-OF-AGENT PERSON  : the matrix
  local b=$1 m=$2 p=$3 pin=${4:-123456}
  daemon $m; person $p $pin
  local out; for q in "create|rk=discouraged&uv=discouraged" "create,get|rk=required&uv=required&guv=required&allow=1" "get|rk=required&uv=required&guv=required&allow=0" "get|rk=required&uv=required&guv=discouraged&allow=0"; do
    mark; out=$(timeout 100 aslh $PY $H/browser120.py $b "${q%%|*}" "${q#*|}" 2>&1 | tail -n +2)
    echo "$out" | while read -r l; do info "$b agent=$m :: $l"; done
    info "$b agent=$m :: ${q#*|} -> prompts=$(prompts) signatures=$(signatures) silent_probes_answered_without_signing=$(evq 'e["ev"]=="silent_probe_answered_without_signing"') refused=$(evq 'e["ev"]=="refused"')"
    BROWSER_LAST="$out"
  done
}
for b in chromium firefox; do
  daemon sensor; person touch
  mark; out=$(timeout 100 aslh $PY $H/browser120.py $b create,get 'rk=discouraged&uv=discouraged' 2>&1)
  VER=$(echo "$out" | head -1); info "$VER"
  check "${b}_create_and_get_with_defaults_prompt_twice_sign_twice_one_each" '[ "$(prompts)" = 2 ] && [ "$(signatures)" = 2 ]'
  browser $b sensor touch
  check "${b}_sensor_agent_discoverable_get_without_an_allow_list_returns_uv_1" 'echo "$BROWSER_LAST" | grep -q "GET OK UP=1 UV=1 .*user=01020304"'
  browser $b pin pin
  check "${b}_pin_agent_discoverable_get_without_an_allow_list_returns_uv_1" 'echo "$BROWSER_LAST" | grep -q "GET OK UP=1 UV=1 .*user=01020304"'
  browser $b click click
done
# Firefox: the repeated GetAssertion is a silent probe (up=false, hash of the empty string) and the real request.
ffget() { mark; timeout 100 aslh $PY $H/browser120.py firefox create,get 'rk=discouraged&uv=discouraged' > /tmp/ff.out 2>&1; }
daemon sensor LH_SILENT=stub; person touch; ffget
info "firefox get, getAssertion requests seen by the Agent (up, hash prefix): $(tail -n +$((N0+1)) $EV | python3 -c "import sys,json; print([(e['up'], e['cdh']) for e in map(json.loads, sys.stdin) if e['ev']=='request' and e['cmd']=='getAssertion'])")"
check "firefox_sends_two_getassertion_the_first_with_up_false_and_the_hash_of_the_empty_string" '[ "$(evq "e[\"ev\"]==\"request\" and e[\"cmd\"]==\"getAssertion\" and e[\"up\"]==False and e[\"cdh\"]==\"e3b0c442\"")" = 1 ] && [ "$(evq "e[\"ev\"]==\"request\" and e[\"cmd\"]==\"getAssertion\" and e[\"up\"]==True")" = 1 ]'
check "with_the_probe_answered_without_signing_firefox_gets_one_prompt_and_one_signature_per_get" '[ "$(evq "e[\"ev\"]==\"signed\" and e[\"cmd\"]==\"getAssertion\"")" = 1 ] && [ "$(evq "e[\"ev\"]==\"silent_probe_answered_without_signing\"")" = 1 ] && [ "$(prompts)" = 2 ]'
daemon sensor LH_SILENT=sign; person touch; ffget
info "control, the probe signed as in spike 0094: key signatures for getAssertion per get = $(evq 'e["ev"]=="signed" and e["cmd"]=="getAssertion"') (one of them with up=0, no presence), prompts for create and get = $(prompts)"
check "if_the_probe_is_signed_the_key_signs_twice_for_one_get_once_without_presence" '[ "$(evq "e[\"ev\"]==\"signed\" and e[\"cmd\"]==\"getAssertion\"")" = 2 ] && [ "$(evq "e[\"ev\"]==\"signed\" and e.get(\"silent\")==True")" = 1 ]'
daemon sensor LH_SILENT=refuse; person touch
ffget; cp /tmp/ff.out /tmp/ffrefuse.out
info "control, the probe refused (CTAP2_ERR_UNSUPPORTED_OPTION): $(grep '^get' /tmp/ffrefuse.out | cut -c1-120); extra requests seen: $(evq 'e["ev"]=="request" and e["rp"]=="make.me.blink"') for rp make.me.blink"
fi

# ======================= C. what #139 needs ============================================================
if want C; then
echo "== C. a process of the same user against the prompt (synthetic input, ptrace, preload, impostor)"
PROF="lh-prompt-stub (enforce)"
echo "-- C1 click-only presence, confined prompt: synthetic input"
LABEL="$PROF" daemon click; person click           # the "person" is a script that clicks through XTEST: indistinguishable from a user
CID=$(raw make --rk | head -1 | field 'd["cred_id"]'); mark
G=$(raw get --allow=$CID)
check "a_synthetic_click_on_a_confined_click_only_prompt_still_obtains_a_signature_is_still_possible" 'echo "$G" | field "d[\"ok\"]" | grep -q True'
check "the_prompt_that_was_clicked_ran_under_the_apparmor_profile_and_the_agent_saw_that_label" '[ "$(evq "e[\"ev\"]==\"prompt_connection\" and e[\"accepted\"] and e[\"label\"]==\"$PROF\"")" -ge 1 ]'

ctl window 60; ctl unlock; mark
G=$(raw get --allow=$CID --uv)
check "uv_within_the_window_is_obtained_by_a_synthetic_click_is_still_possible" 'echo "$G" | field "d[\"flags\"][\"UV\"]" | grep -q 1 && [ "$(evq "e[\"ev\"]==\"signed\" and e.get(\"uv_why\")==\"window\"")" = 1 ]'
ctl forget

echo "-- C2 sensor presence: synthetic input does not produce a signature"
ctl mode sensor; person click; mark
G=$(raw get --allow=$CID)
check "a_synthetic_click_on_a_sensor_prompt_produces_no_signature" 'echo "$G" | field "d[\"ok\"]" | grep -q False && [ "$(signatures)" = 0 ]'
person pin 123456; mark
G=$(raw get --allow=$CID)
check "synthetic_typing_of_the_pin_on_a_sensor_prompt_produces_no_signature" 'echo "$G" | field "d[\"ok\"]" | grep -q False && [ "$(signatures)" = 0 ]'
check "the_sensor_socket_is_not_writable_by_the_user" '! sudo -u lh python3 -c "import socket; s=socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM); s.sendto(b\"match\", \"/run/lhctap2/sensor\")"'
check "the_control_socket_is_not_writable_by_the_user" '! sudo -u lh python3 -c "import socket; s=socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM); s.sendto(b\"mode click\", \"/run/lhctap2/ctl\")"'
person none; mark
( sleep 1.5; python3 $H/lhsensor match ) &
SP=$!
G=$(raw get --allow=$CID); wait $SP
check "a_sensor_match_written_by_root_gives_the_signature" 'echo "$G" | field "d[\"flags\"][\"UV\"]" | grep -q 1'

echo "-- C3 an impostor prompt (same user, unconfined) answers on the prompt socket"
ctl mode click; person none; mark
( aslh python3 $H/impostor.py 12 > /tmp/impostor.out 2>&1 & )
( for i in 1 2 3; do aslh env LH_PROMPT_SOCK=/run/lhctap2/prompt.sock timeout 3 /usr/local/libexec/linuxhello/lh-prompt-stub; done >/dev/null 2>&1 & )
sleep 0.5; G=$(raw get --allow=$CID)
sleep 8
check "an_impostor_prompt_connection_is_refused_and_gets_no_signature" 'echo "$G" | field "d[\"ok\"]" | grep -q False && [ "$(signatures)" = 0 ] && [ "$(evq "e[\"ev\"]==\"prompt_connection\" and not e[\"accepted\"]")" -ge 1 ]'
check "a_second_copy_of_the_real_prompt_binary_started_by_the_user_has_the_right_label_and_is_still_refused" '[ "$(evq "e[\"ev\"]==\"prompt_connection\" and not e[\"accepted\"] and e[\"label\"]==\"$PROF\"")" -ge 1 ]'
check "the_impostor_never_receives_the_request_or_the_relying_party" 'grep -q "messages from the Agent: 0" /tmp/impostor.out'

echo "-- C4 ptrace (Yama, the not-dumpable flag and the AppArmor profile, each alone)"
YAMA=$(sysctl -n kernel.yama.ptrace_scope)
attach() {   # attach NAME: a request waits on the prompt, a process of the same user (unconfined) tries to attach to it
  person none; ( raw get --allow=$CID > /dev/null & ); sleep 3
  PP=$(pgrep -n -f '[l]h-prompt-stub')
  PROFILE_SEEN=$(cat /proc/$PP/attr/current 2>/dev/null); ENV_OWNER=$(stat -c %U /proc/$PP/environ 2>/dev/null)
  ATT=$(timeout 4 aslh strace -p $PP -o /dev/null 2>&1 | head -3)
  info "$1: pid $PP, profile ${PROFILE_SEEN:-none}, strace says: $(echo "$ATT" | head -1 | cut -c1-110)"
  pkill -f "[l]h-prompt-stub" 2>/dev/null; sleep 3
}
newdaemon() { LABEL="$1" daemon click "${@:2}"; person click; CID=$(raw make --rk 2>&1 | head -1 | field 'd["cred_id"]'); }
newdaemon "$PROF"
attach "Yama $YAMA, not dumpable, profile (as shipped)"
check "the_prompt_started_by_the_agent_runs_under_its_apparmor_profile" 'echo "$PROFILE_SEEN" | grep -q "^$PROF"'
check "the_prompt_started_by_the_agent_is_not_dumpable_its_proc_files_belong_to_root" '[ "$ENV_OWNER" = root ]'
check "a_process_of_the_same_user_cannot_attach_to_the_prompt_the_agent_started" 'echo "$ATT" | grep -qi "not permitted"'
person none; ( raw get --allow=$CID > /dev/null & ); sleep 3
T=$(timeout 4 aslh gdb -batch -p $(pgrep -n -f '[l]h-prompt-stub') -ex quit 2>&1 | head -6)
check "gdb_cannot_attach_either" 'echo "$T" | grep -qi "not permitted\|Could not attach\|ptrace"'
pkill -f "[l]h-prompt-stub" 2>/dev/null; sleep 3
check "a_process_of_the_same_user_cannot_read_the_memory_of_the_prompt_the_agent_started" '( raw get --allow=$CID >/dev/null & ); sleep 3; ! aslh python3 -c "open(\"/proc/$(pgrep -n -f [l]h-prompt-stub)/mem\",\"rb\").read(1)"'
pkill -f "[l]h-prompt-stub" 2>/dev/null; sleep 3
sysctl -qw kernel.yama.ptrace_scope=0
newdaemon "$PROF"; attach "Yama off, not dumpable, profile"
apparmor_parser -R /etc/apparmor.d/lh-prompt-stub
newdaemon "" ; attach "Yama off, not dumpable, no profile (the flag alone)"
apparmor_parser -r /etc/apparmor.d/lh-prompt-stub
check "the_not_dumpable_flag_alone_refuses_an_attach_by_the_same_user" 'echo "$ATT" | grep -qi "not permitted"'
newdaemon "$PROF" LH_PROMPT_DUMPABLE=1; attach "Yama off, dumpable, profile (the profile alone)"
check "the_apparmor_profile_alone_does_not_stop_an_unconfined_tracer_of_the_same_user_is_still_possible" 'echo "$ATT" | grep -qi "attached"'
apparmor_parser -R /etc/apparmor.d/lh-prompt-stub
newdaemon "" LH_PROMPT_DUMPABLE=1; attach "Yama off, dumpable, no profile (control)"
check "control_with_every_layer_off_a_process_of_the_same_user_can_attach" 'echo "$ATT" | grep -qi "attached"'
sysctl -qw kernel.yama.ptrace_scope=1
newdaemon "" LH_PROMPT_DUMPABLE=1; attach "Yama 1, dumpable, no profile (Yama alone)"
check "yama_alone_refuses_an_attach_to_a_process_that_is_not_your_child" 'echo "$ATT" | grep -qi "not permitted"'
apparmor_parser -r /etc/apparmor.d/lh-prompt-stub
sysctl -qw kernel.yama.ptrace_scope=$YAMA
# The same user starts a copy and traces it from exec: tracing a process you started is allowed even under the profile.
rm -f /tmp/st.out
aslh bash -c 'LH_PROMPT_SOCK=/nonexistent strace -f -o /tmp/st.out /usr/local/libexec/linuxhello/lh-prompt-stub' >/tmp/st.err 2>&1
check "a_copy_of_the_prompt_that_the_user_starts_and_traces_from_exec_runs_is_still_possible" '[ "$(wc -l < /tmp/st.out)" -gt 100 ]'
info "that copy is not the Agent's child: it has no way to answer the Agent's request (C3: refused by pid)"

echo "-- C5 preload"
rm -f /tmp/lh-preload-ran
aslh env LD_PRELOAD=/home/lh/evil.so LH_PROMPT_SOCK=/nonexistent /usr/local/libexec/linuxhello/lh-prompt-stub >/dev/null 2>&1
check "ld_preload_is_ignored_when_the_confined_prompt_is_started" '[ ! -e /tmp/lh-preload-ran ]'
apparmor_parser -R /etc/apparmor.d/lh-prompt-stub
aslh env LD_PRELOAD=/home/lh/evil.so LH_PROMPT_SOCK=/nonexistent /usr/local/libexec/linuxhello/lh-prompt-stub >/dev/null 2>&1
check "control_without_the_profile_the_same_preload_runs_its_code" '[ -e /tmp/lh-preload-ran ]'
rm -f /tmp/lh-preload-ran; apparmor_parser -r /etc/apparmor.d/lh-prompt-stub

echo "-- C6 can a process of the same user read the PIN typed into the prompt (X11)?"
LABEL="$PROF" daemon pin; person pin 123456
M=$(raw make --rk --uv 2>&1 | head -1)
person none; ( aslh bash -c 'timeout 12 xinput test-xi2 --root > /tmp/xi.out 2>&1' & ); sleep 1
person pin 123456; mark
G=$(raw get --uv 2>&1)
sleep 1
KEYS=$(grep -A8 'RawKeyPress\|KeyPress' /tmp/xi.out | grep -o 'detail: [0-9]*' | awk '{print $2}' | tr '\n' ' ')
info "an X client of the same user recorded these key codes while the PIN was typed into the prompt: $KEYS"
KEYS=$(echo $KEYS | awk '{for(i=1;i<=NF;i++) if($i!=p){printf "%s ",$i; p=$i}}')
check "a_pin_typed_into_an_x11_prompt_can_be_read_by_another_x_client_is_still_possible" 'echo "$KEYS" | grep -q "10 11 12 13 14 15"'
person none
tpm2_dictionarylockout --clear-lockout >/dev/null 2>&1

fi
# ======================= D. distribution browsers (opt-in: downloads about 600 MB) =======================
if want D && echo " $LH_UVUP_SECTIONS " | grep -q " D "; then
echo "== D. Chrome stable (.deb from Google), Chromium and Firefox as Snaps (Ubuntu's store)"
command -v google-chrome >/dev/null || { curl -fsSL -o /tmp/chrome.deb https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb && apt-get install -y -qq /tmp/chrome.deb >/dev/null 2>&1; }
snap list chromium >/dev/null 2>&1 || snap install chromium >/dev/null 2>&1
snap list firefox >/dev/null 2>&1 || snap install firefox >/dev/null 2>&1
info "versions: $(google-chrome --version), chromium snap $(snap list chromium | awk 'NR==2{print $2, "rev", $3}'), firefox snap $(snap list firefox | awk 'NR==2{print $2, "rev", $3}'); u2f-devices connected: $(snap connections chromium | grep -c ':u2f-devices') chromium, $(snap connections firefox | grep -c ':u2f-devices') firefox"
daemon sensor; person touch
mkdir -p /home/lh/snap/firefox/common/lhprof /home/lh/snap/chromium/common/lhprof; chown -R lh:lh /home/lh/snap
run() {   # run NAME COMMAND...: the page runs create then get by itself; the result is read from the window title
  local name=$1; shift; local t
  pkill -f "snap/chromium|snap/firefox|/opt/google/chrome/chrome" 2>/dev/null; sleep 1; mark
  setsid -f sudo -u lh env DISPLAY=:99 HOME=/home/lh "$@" > /tmp/br-$name.log 2>&1 < /dev/null
  for i in $(seq 40); do
    t=$(aslh bash -c 'for w in $(xdotool search --name "LH120"); do xdotool getwindowname $w; done' 2>/dev/null | head -1)
    case "$t" in *"GET OK"*|*"ERR"*) break;; esac; sleep 1
  done
  info "$name: ${t:-no result after 40 s}"; TITLE="$t"
  pkill -f "snap/chromium|snap/firefox|/opt/google/chrome/chrome" 2>/dev/null; sleep 2
}
U="http://localhost:8000/spike120.html?auto=create,get&rk=required&uv=required&guv=required&allow=1"
run chrome-stable /opt/google/chrome/chrome --user-data-dir=/home/lh/lhchrome --no-first-run --no-default-browser-check --no-sandbox "$U"
check "chrome_stable_creates_a_resident_credential_with_uv_and_gets_with_the_allow_list" 'echo "$TITLE" | grep -q "GET OK UP=1 UV=1"'
run chromium-snap /snap/bin/chromium --user-data-dir=/home/lh/snap/chromium/common/lhprof --no-first-run --no-default-browser-check "$U"
check "chromium_as_a_snap_reaches_the_virtual_authenticator_through_u2f_devices" 'echo "$TITLE" | grep -q "GET OK UP=1 UV=1"'
run firefox-snap /snap/bin/firefox -no-remote -profile /home/lh/snap/firefox/common/lhprof "$U"
check "firefox_as_a_snap_reaches_the_virtual_authenticator_through_u2f_devices" 'echo "$TITLE" | grep -q "GET OK UP=1 UV=1"'
check "each_of_the_three_runs_prompted_and_signed_exactly_twice_create_and_get" '[ "$(grep -c "\"ev\": \"signed\"" $EV)" = 6 ]'
fi
pkill -f "[l]hctap2.py" 2>/dev/null; person none; pkill -f "[x]input test-xi2" 2>/dev/null
[ "$fail" -eq 0 ] && echo "ALL PASSED" || echo "$fail FAILED"
exit "$fail"
