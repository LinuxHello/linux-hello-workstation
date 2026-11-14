#!/usr/bin/env bash
# Tests for lh_set_status in local/lh-status.sh, with a stub gh; needs bash.
#
#   local/test-lh-status.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
pass=0 fail=0
check() { if [[ "$2" == 0 ]]; then pass=$((pass + 1)); echo "ok   $1"; else fail=$((fail + 1)); echo "FAIL $1"; fi; }
# shellcheck source=local/lh-status.sh
source "$here/lh-status.sh"

mkdir -p "$work/bin"
# gh issue view: prints the labels in $STUB_DIR/labels (one per line); gh issue edit: logs its arguments.
cat > "$work/bin/gh" <<'SH'
#!/usr/bin/env bash
case "$2" in
  view) [[ -f "$STUB_DIR/gh-fails" ]] && exit 1; cat "$STUB_DIR/labels" ;;
  edit) echo "$*" >> "$STUB_DIR/edits" ;;
esac
SH
chmod +x "$work/bin/gh"
export PATH="$work/bin:$PATH" STUB_DIR="$work"

printf 'container:agent\nstatus:ready\nstatus:in-review\npriority:next\n' > "$work/labels"
: > "$work/edits"
lh_set_status LinuxHello/linux-hello 132 ready
check "the_target_status_is_added" "$(grep -q -- '--add-label status:ready' "$work/edits"; echo $?)"
check "every_other_status_label_is_removed" "$(grep -q -- '--remove-label status:in-review' "$work/edits"; echo $?)"
check "the_target_is_not_removed" "$(! grep -q -- '--remove-label status:ready' "$work/edits"; echo $?)"
check "labels_that_are_not_a_status_are_left_alone" "$(! grep -q -- 'priority:next\|container:agent' "$work/edits"; echo $?)"

printf 'status:ready\n' > "$work/labels"; : > "$work/edits"
lh_set_status LinuxHello/linux-hello 132 in-progress
check "ready_is_replaced_by_in_progress" "$(grep -q -- '--add-label status:in-progress' "$work/edits" && grep -q -- '--remove-label status:ready' "$work/edits"; echo $?)"

touch "$work/gh-fails"; : > "$work/edits"
rc=0; lh_set_status LinuxHello/linux-hello 132 ready || rc=$?
check "a_failing_gh_never_stops_the_run" "$([[ $rc -eq 0 ]]; echo $?)"
check "the_target_is_still_requested_when_the_labels_cannot_be_read" "$(grep -q -- '--add-label status:ready' "$work/edits"; echo $?)"

echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
