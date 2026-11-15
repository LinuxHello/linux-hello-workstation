#!/usr/bin/env bash
# Tests for scripts/map.py (make map) with a fixture; no GitHub. Needs bash and python3.
#
#   local/test-map.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
pass=0 fail=0
check() { if [[ "$2" == 0 ]]; then pass=$((pass + 1)); echo "ok   $1"; else fail=$((fail + 1)); echo "FAIL $1"; fi; }

TRIAGE=$'# comment\n10\tneeds-brief\tnext\t-\tfirst\n11\tblocked\tlater\t10\tsecond\n12\tblocked\tlater\t10,11\tthird\n20\tneeds-brief\tnext\t-\tspike\n21\tblocked\tlater\t20\tafter the spike\n30\tneeds-brief\tnext\t-\talone\n40\tblocked\tlater\t99\tblocked by a closed issue\n'
ISSUES='[
 {"number":10,"title":"First \"quoted\" [thing]","labels":[{"name":"container:agent"},{"name":"status:needs-brief"}]},
 {"number":11,"title":"Second","labels":[{"name":"container:agent"},{"name":"status:blocked"}]},
 {"number":12,"title":"Third","labels":[{"name":"container:pam"},{"name":"status:blocked"}]},
 {"number":20,"title":"A spike","labels":[{"name":"container:agent"},{"name":"type:spike"}]},
 {"number":21,"title":"After the spike","labels":[{"name":"container:agent"},{"name":"status:blocked"}]},
 {"number":30,"title":"Alone","labels":[{"name":"status:needs-brief"}]},
 {"number":40,"title":"Closed blocker","labels":[{"name":"status:blocked"}]},
 {"number":50,"title":"Being built","labels":[{"name":"status:in-progress"}]}
]'
out=$(python3 -c '
import json, sys
print(json.dumps({"issues": json.loads(sys.argv[1]), "triage": sys.argv[2]}))' "$ISSUES" "$TRIAGE" | python3 "$here/../scripts/map.py")

check "an_edge_is_drawn_from_the_blocker_to_the_blocked_issue" "$(grep -q '  n10 --> n11' <<<"$out"; echo $?)"
check "an_issue_with_two_blockers_gets_two_edges" "$(grep -q '  n10 --> n12' <<<"$out" && grep -q '  n11 --> n12' <<<"$out"; echo $?)"
check "connected_issues_share_one_group_named_by_their_container" "$(grep -q 'subgraph g1\["agent"\]' <<<"$out" && grep -q 'subgraph g2\["agent"\]' <<<"$out"; echo $?)"
check "a_spike_is_marked_as_yours" "$(grep -q 'class n20 yours' <<<"$out"; echo $?)"
check "a_blocked_issue_is_marked_as_waiting_and_an_unblocked_one_as_ready" "$(grep -q 'class n11 waits' <<<"$out" && grep -q 'class n10 ready' <<<"$out"; echo $?)"
check "quotes_and_brackets_in_a_title_cannot_break_the_diagram" "$(grep -q "n10\[\"#10 First 'quoted' 'thing'\"\]" <<<"$out"; echo $?)"
check "an_issue_with_no_edge_is_listed_not_drawn" "$(! grep -q 'n30' <<<"$out" && grep -q -- '- #30 Alone' <<<"$out"; echo $?)"
check "an_edge_to_a_closed_blocker_is_dropped_and_the_issue_listed" "$(! grep -q 'n99' <<<"$out" && grep -q -- '- #40 Closed blocker' <<<"$out"; echo $?)"
check "an_issue_being_built_is_listed_as_active" "$(grep -q 'being worked on or in review' <<<"$out" && grep -q -- '- #50 Being built' <<<"$out"; echo $?)"
echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
