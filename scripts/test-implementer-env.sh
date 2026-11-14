#!/usr/bin/env bash
# shellcheck disable=SC2015  # ok() always succeeds, so "test && ok || nok" never runs both
# Tests for implementer-env.sh in a scratch HOME, with no model server. Never touches your config.
#   bash scripts/test-implementer-env.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "ok   $1"; }
nok() { fail=$((fail + 1)); echo "FAIL $1"; }

# shellcheck disable=SC2120  # some calls pass arguments, some do not
run() { HOME="$work/home" XDG_CONFIG_HOME="" OLLAMA_HOST=http://127.0.0.1:9 CLONE_DIR="$work/clone" bash "$here/implementer-env.sh" "$@" 2>&1; }
f="$work/home/.config/linux-hello/implementer.env"

out=$(run) && ok "first run succeeds" || nok "first run succeeds: $out"
[[ -f "$f" ]] && ok "creates the file" || nok "creates the file"
[[ "$(stat -c %a "$f")" == 600 ]] && ok "file is mode 600" || nok "file is mode 600"
grep -q "^LH_TOOLING_DIR=$(cd "$here/.." && pwd)\$" "$f" && ok "points at this checkout" || nok "points at this checkout"
grep -q "^CLONE_DIR=$work/clone\$" "$f" && ok "points at the clone" || nok "points at the clone"
grep -q '^OLLAMA_MODEL=gemma4-26b-64k:latest$' "$f" && ok "fills the default model" || nok "fills the default model"
grep -q '^LH_BG_MODEL=gemma4-26b-64k:latest$' "$f" && ok "background model follows the model" || nok "background model follows the model"
! grep -qE '^[A-Z_]+=.*<[^>]*>' "$f" && ok "leaves no placeholder" || nok "leaves no placeholder"
# Every other line is the example's.
diff <(grep -vE '^(LH_TOOLING_DIR|CLONE_DIR|OLLAMA_MODEL|LH_BG_MODEL)=' "$f") \
     <(grep -vE '^(LH_TOOLING_DIR|CLONE_DIR|OLLAMA_MODEL|LH_BG_MODEL)=' "$here/../local/implementer.env.example") >/dev/null \
  && ok "keeps the rest of the example" || nok "keeps the rest of the example"

echo "OLLAMA_MODEL=mine:1b" >>"$f"
out=$(run) && ok "second run succeeds" || nok "second run succeeds"
grep -q '^OLLAMA_MODEL=mine:1b$' "$f" && grep -q "left unchanged" <<<"$out" && ok "never overwrites an existing file" || nok "never overwrites an existing file"

rm -f "$f"
out=$(OLLAMA_MODEL=other:7b run) && grep -q '^OLLAMA_MODEL=other:7b$' "$f" && ok "OLLAMA_MODEL at creation is honoured" || nok "OLLAMA_MODEL at creation is honoured"

echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
