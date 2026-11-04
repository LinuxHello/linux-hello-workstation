#!/usr/bin/env bash
# shellcheck disable=SC2015  # ok() always succeeds, so "test && ok || nok" never runs both
# Tests for triage.sh with a fake gh. Needs bash and jq; never calls GitHub.
#   bash scripts/test-triage.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "ok   $1"; }
nok() { fail=$((fail + 1)); echo "FAIL $1"; local d="${2:-}"; echo "     ${d//$'\n'/$'\n'     }"; }

# Issues: #1 open with stale labels, #2 open and already right, #3 closed. #1 is already blocked by #2.
cat >"$work/bin/gh" <<EOF
#!/usr/bin/env bash
echo "gh \$*" >>"$work/calls"
case "\$*" in
  "api repos/LinuxHello/linux-hello/issues/1")
    echo '{"id":101,"state":"open","title":"One","labels":[{"name":"status:needs-brief"},{"name":"priority:later"},{"name":"type:docs"}]}' ;;
  "api repos/LinuxHello/linux-hello/issues/2")
    echo '{"id":102,"state":"open","title":"Two","labels":[{"name":"status:ready"},{"name":"priority:now"}]}' ;;
  "api repos/LinuxHello/linux-hello/issues/3")
    echo '{"id":103,"state":"closed","title":"Three","labels":[]}' ;;
  "api repos/LinuxHello/linux-hello/issues/1/dependencies/blocked_by --jq .[].number") echo 2 ;;
  "api repos/LinuxHello/linux-hello/issues/"*"/dependencies/blocked_by --jq .[].number") ;;
  "api repos/LinuxHello/linux-hello/issues/2 --jq .id") echo 102 ;;
  "api repos/LinuxHello/linux-hello/issues/3 --jq .id") echo 103 ;;
  "issue edit"*|"api -X POST"*) ;;
  *) echo "unexpected gh \$*" >&2; exit 1 ;;
esac
EOF
chmod +x "$work/bin/gh"
printf '# comment\n1\tready\tnow\t2,3\tnote\n2\tready\tnow\t-\t\n3\tready\tnow\t-\t\n' >"$work/t.tsv"
run() { : >"$work/calls"; PATH="$work/bin:$PATH" bash "$here/triage.sh" "$work/t.tsv" 2>&1; }

t=dry_run_changes_nothing
out=$(run)
! grep -qE 'issue edit|-X POST' "$work/calls" && grep -q 'plan: labels +\[status:ready priority:now\] -\[status:needs-brief priority:later\]' <<<"$out" \
  && ok "$t" || nok "$t" "$out"

t=apply_sets_one_status_and_priority_and_keeps_other_labels
out=$(APPLY=1 run)
grep -q 'issue edit 1 --repo LinuxHello/linux-hello --add-label status:ready --add-label priority:now --remove-label status:needs-brief --remove-label priority:later' "$work/calls" \
  && ! grep -q 'remove-label type:docs' "$work/calls" && ok "$t" || nok "$t" "$(cat "$work/calls")"

t=apply_adds_only_missing_blocked_by_links
grep -q 'api -X POST repos/LinuxHello/linux-hello/issues/1/dependencies/blocked_by -F issue_id=103' "$work/calls" \
  && ! grep -q 'issue_id=102' "$work/calls" && ok "$t" || nok "$t" "$(cat "$work/calls")"

t=issue_already_right_is_left_alone
! grep -q 'issue edit 2' "$work/calls" && ok "$t" || nok "$t" "$(cat "$work/calls")"

t=closed_issue_is_skipped
grep -q '#3 is closed; skipped' <<<"$out" && ! grep -q 'issue edit 3' "$work/calls" && ok "$t" || nok "$t" "$out"

t=bad_status_fails_before_any_change
printf '1\tdone\tnow\t-\t\n' >"$work/t.tsv"
rc=0; out=$(APPLY=1 run) || rc=$?
[[ $rc != 0 ]] && grep -q "bad status 'done'" <<<"$out" && ! grep -q 'issue edit' "$work/calls" && ok "$t" || nok "$t" "$out"

echo "$pass passed, $fail failed"
((fail == 0))
