#!/usr/bin/env bash
# Spike linux-hello#120 in the test VM: resident keys, user presence and user verification in the virtual
# CTAP authenticator, and what a process of the same user can do against the prompt (#139). The prototype
# (scripts/spike-0120/lhctap2.py) extends the spike 0094 one; a stub Prompt UI shows the relying-party id;
# the browsers are driven through the prompt. Prints PASS/FAIL per check and INFO lines with the
# measurements; a check named *_is_still_possible documents what the design does not stop. Exits non-zero
# if a check failed.
#
#   scripts/vm-test-uvup.sh            VM must be up: make vm-up   (first run installs packages and the browsers)
#   LH_UVUP_QUICK=1 scripts/vm-test-uvup.sh    skip the 62 s wait for the 60 s cap and the browser matrix
#   LH_UVUP_SECTIONS="A C" scripts/vm-test-uvup.sh    run only some sections: A authenticator, B Playwright browsers, C attacks
#                                                     on the prompt, D Chrome stable and the Snaps (opt-in, downloads ~600 MB)
#   Default: A B C. Takes about 25 minutes (the 62 s wait for the 60 s cap, the browser matrix).
#
# It changes only the VM: packages, a python venv with playwright and python-fido2, an AppArmor profile,
# /usr/local/libexec/linuxhello/lh-prompt-stub, files under ~lh/spike120 and /var/lib/lhctap2.
set -euo pipefail
source "$(dirname "$0")/../common.sh"
vm="$(dirname "$0")/vm.sh"
here="$(cd "$(dirname "$0")" && pwd)"
bash "$vm" status | grep -q '^running' || die "the VM is not running: make vm-up"
bash "$vm" ssh 'rm -rf ~/spike120 && mkdir ~/spike120 && tar x -C ~/spike120' < <(tar c -C "$here/spike-0120" .)
sections=$(printf '%q' "${LH_UVUP_SECTIONS:-}")
bash "$vm" ssh "sudo -H env LH_UVUP_QUICK=${LH_UVUP_QUICK:-} LH_UVUP_SECTIONS=$sections bash /home/lh/spike120/remote-uvup.sh" | grep --line-buffered -v '^Terminated$'
exit "${PIPESTATUS[0]}"
