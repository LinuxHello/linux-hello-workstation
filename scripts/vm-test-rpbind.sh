#!/usr/bin/env bash
# Spike linux-hello#119 in the test VM: can a credential key be made unusable for any relying party
# but its own inside the TPM? Option tried: the key's authorisation value is HMAC(H, rpIdHash), where
# H is an HMAC key under the user's root key R, so the TPM computes the value and the key refuses a
# request for another relying party (TPM_RC_AUTH_FAIL), with no lockout (noDA). Prints PASS/FAIL per
# check and INFO lines with the measurements; exits non-zero if a check failed.
#
#   scripts/vm-test-rpbind.sh      VM must be up: make vm-up
set -euo pipefail
source "$(dirname "$0")/../common.sh"
vm="$(dirname "$0")/vm.sh"
bash "$vm" status | grep -q '^running' || die "the VM is not running: make vm-up"
bash "$vm" ssh 'sudo -H bash -s' <<'REMOTE'
set +e
fail=0
check() { if eval "$2" >/dev/null 2>&1; then echo "PASS $1"; else echo "FAIL $1"; fail=$((fail + 1)); fi; }
rm -rf ~/spike119 && mkdir ~/spike119 && cd ~/spike119
PIN=123456
KEY="fixedtpm|fixedparent|sensitivedataorigin|userwithauth"
lockout() { tpm2_getcap properties-variable 2>/dev/null | grep 'TPM2_PT_LOCKOUT_COUNTER' | head -1 | tr -d ' ' ; }
ms() { date +%s%3N; }
tpm2_dictionarylockout --clear-lockout >/dev/null 2>&1

# P (primary) > R (root key, PIN) > H (HMAC key) and the credential keys.
tpm2_createprimary -C o -G ecc -c prim.ctx >/dev/null
tpm2_create -C prim.ctx -G ecc256:null:aes128cfb -a "restricted|decrypt|$KEY" -p $PIN -u r.pub -r r.priv >/dev/null
tpm2_load -C prim.ctx -u r.pub -r r.priv -c r.ctx >/dev/null
tpm2_create -C r.ctx -P $PIN -G hmac -a "sign|$KEY|noda" -u h.pub -r h.priv >/dev/null
tpm2_load -C r.ctx -P $PIN -u h.pub -r h.priv -c h.ctx >/dev/null

# The authorisation value for a relying party, computed inside the TPM.
rpauth() { printf '%s' "$1" | openssl dgst -sha256 -binary > rp.hash; tpm2_hmac -c h.ctx -g sha256 -o rp.hmac rp.hash >/dev/null && xxd -p -c 64 rp.hmac; }
AUTH_A=$(rpauth example.test); AUTH_B=$(rpauth other.test)
check "the_tpm_derives_different_values_for_different_relying_parties" '[ -n "$AUTH_A" ] && [ "$AUTH_A" != "$AUTH_B" ]'
check "the_value_is_stable_for_one_relying_party" '[ "$(rpauth example.test)" = "$AUTH_A" ]'

# A credential key for relying party A, bound by its authorisation value.
T0=$(ms)
tpm2_create -C r.ctx -P $PIN -G ecc256:ecdsa-sha256 -p hex:$AUTH_A -a "sign|$KEY|noda" -u cA.pub -r cA.priv >/dev/null
T1=$(ms)
tpm2_load -C r.ctx -P $PIN -u cA.pub -r cA.priv -c cA.ctx >/dev/null
echo hello > msg
T2=$(ms)
tpm2_sign -c cA.ctx -p hex:$AUTH_A -g sha256 -s ecdsa -o sigA msg >/dev/null 2>&1; RC_A=$?
T3=$(ms)
echo "INFO create $((T1-T0)) ms, load+sign path: sign $((T3-T2)) ms (swtpm, tpm2-tools process calls)"
check "the_key_signs_for_its_own_relying_party" '[ $RC_A -eq 0 ] && [ -s sigA ]'

BEFORE=$(lockout)
tpm2_sign -c cA.ctx -p hex:$AUTH_B -g sha256 -s ecdsa -o sigB msg >errB 2>&1; RC_B=$?
check "the_tpm_refuses_the_key_for_another_relying_party" '[ $RC_B -ne 0 ] && [ ! -s sigB ]'
check "the_refusal_is_an_authorisation_failure" 'grep -qi "auth" errB'
check "a_refused_request_does_not_count_towards_the_lockout" '[ "$(lockout)" = "$BEFORE" ]'
tpm2_sign -c cA.ctx -g sha256 -s ecdsa -o sigC msg >/dev/null 2>&1; RC_C=$?
check "the_key_is_refused_without_any_authorisation_value" '[ $RC_C -ne 0 ]'

# Control: the same without noDA, to show why the credential keys carry it.
tpm2_create -C r.ctx -P $PIN -G ecc256:ecdsa-sha256 -p hex:$AUTH_A -a "sign|$KEY" -u cN.pub -r cN.priv >/dev/null
tpm2_load -C r.ctx -P $PIN -u cN.pub -r cN.priv -c cN.ctx >/dev/null
B2=$(lockout)
tpm2_sign -c cN.ctx -p hex:$AUTH_B -g sha256 -s ecdsa -o sigN msg >/dev/null 2>&1
echo "INFO lockout counter: $B2 before and $(lockout) after one wrong-RP request on a key WITHOUT noda"
check "without_noda_a_wrong_relying_party_request_would_count_as_a_failed_attempt" '[ "$(lockout)" != "$B2" ]'
tpm2_dictionarylockout --clear-lockout >/dev/null 2>&1

# PIN change in place keeps the credential loadable and usable (spike 0011).
tpm2_changeauth -c r.ctx -C prim.ctx -p $PIN -r r.priv.new newpin >/dev/null 2>&1
tpm2_load -C prim.ctx -u r.pub -r r.priv.new -c r2.ctx >/dev/null 2>&1
tpm2_load -C r2.ctx -P newpin -u cA.pub -r cA.priv -c cA2.ctx >/dev/null 2>&1; RC_L=$?
tpm2_sign -c cA2.ctx -p hex:$AUTH_A -g sha256 -s ecdsa -o sigD msg >/dev/null 2>&1; RC_D=$?
check "after_a_pin_change_the_credential_loads_under_the_new_root_key_and_signs" '[ $RC_L -eq 0 ] && [ $RC_D -eq 0 ]'
tpm2_load -C r2.ctx -P newpin -u h.pub -r h.priv -c h2.ctx >/dev/null 2>&1
tpm2_hmac -c h2.ctx -g sha256 -o rp.hmac2 rp.hash >/dev/null 2>&1; printf '%s' other.test | openssl dgst -sha256 -binary > rp.hash.o
check "after_a_pin_change_the_hmac_key_gives_the_same_value" 'tpm2_hmac -c h2.ctx -g sha256 -o x1 rp.hash.o && [ "$(xxd -p -c 64 x1)" = "$AUTH_B" ]'

echo "INFO sizes: public $(stat -c %s cA.pub) bytes + private $(stat -c %s cA.priv) bytes per credential; the HMAC key (public $(stat -c %s h.pub), private $(stat -c %s h.priv)) exists once per user, not per credential"
[ "$fail" -eq 0 ] && echo "ALL PASSED" || echo "$fail FAILED"
exit "$fail"
REMOTE
