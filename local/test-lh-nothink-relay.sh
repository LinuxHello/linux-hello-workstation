#!/usr/bin/env bash
# Tests for local/lh-nothink-relay.py against a stub upstream; needs python3 and curl, never calls a
# model server.
#
#   local/test-lh-nothink-relay.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
for c in python3 curl jq; do command -v "$c" >/dev/null || { echo "$c not installed" >&2; exit 1; }; done

work="$(mktemp -d)"
pids=()
trap 'kill "${pids[@]}" 2>/dev/null || true; rm -rf "$work"' EXIT

# Stub upstream: records each request (method, path, body) and answers with a fixed SSE stream,
# or 400 for /fail.
cat >"$work/stub.py" <<'PY'
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
log, reply = sys.argv[1], sys.argv[2].encode()
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def handle_one(self):
        n = int(self.headers.get("content-length") or 0)
        body = self.rfile.read(n).decode() if n else ""
        with open(log, "a") as f: f.write(json.dumps({"method": self.command, "path": self.path, "body": body}) + "\n")
        status = 400 if self.headers.get("x-stub-fail") else 200
        out = b'{"error":"bad"}' if status == 400 else reply
        self.send_response(status); self.send_header("content-type", "text/event-stream")
        self.send_header("content-length", str(len(out))); self.end_headers(); self.wfile.write(out)
    do_GET = do_POST = handle_one
s = HTTPServer(("127.0.0.1", 0), H); print(s.server_address[1], flush=True); s.serve_forever()
PY
sse=$'event: message_start\ndata: {"type":"message_start"}\n\nevent: message_stop\ndata: {"type":"message_stop"}\n\n'
start() { # <outfile> <cmd...>: start a server that prints its port, echo the port
  local out=$1; shift
  "$@" >"$out" 2>"$out.err" & pids+=($!)
  for _ in $(seq 50); do [[ -s "$out" ]] && break; sleep 0.1; done
  head -1 "$out"
}
up=$(start "$work/up.port" python3 -I "$work/stub.py" "$work/req.log" "$sse")
relay=$(start "$work/relay.port" python3 -I "$here/lh-nothink-relay.py" "http://127.0.0.1:$up")
url="http://127.0.0.1:$relay"

pass=0 fail=0
ok()  { pass=$((pass + 1)); echo "ok   $1"; }
nok() { fail=$((fail + 1)); echo "FAIL $1: $2"; }
last() { tail -1 "$work/req.log"; }
post() { curl -fsS -X POST "$url$1" -H 'content-type: application/json' -d "$2"; }

for case in 'adaptive:{"type":"adaptive","display":"omitted"}' 'nothing:absent'; do
  name="thinking_is_disabled_when_claude_code_sends_${case%%:*}" sent=${case#*:}
  body=$(jq -cn --arg s "$sent" '{model:"m",max_tokens:5,messages:[{role:"user",content:"hi"}]} + (if $s=="absent" then {} else {thinking:($s|fromjson)} end)')
  post '/v1/messages?beta=true' "$body" >/dev/null
  got=$(last | jq -c '.body | fromjson | .thinking')
  if [[ "$got" == '{"type":"disabled"}' ]]; then ok "$name"; else nok "$name" "upstream got $got"; fi
done

post /v1/messages '{"model":"m","max_tokens":7,"messages":[{"role":"user","content":"hi"}],"stream":true}' >/dev/null
if [[ "$(last | jq -c '.body | fromjson | del(.thinking)')" == '{"model":"m","max_tokens":7,"messages":[{"role":"user","content":"hi"}],"stream":true}' ]]; then
  ok other_fields_reach_ollama_unchanged
else nok other_fields_reach_ollama_unchanged "$(last)"; fi

post /v1/messages '{"model":"m","max_tokens":1,"messages":[]}' >"$work/stream.out"
if cmp -s "$work/stream.out" <(printf '%s' "$sse"); then ok streamed_reply_reaches_the_client_unchanged
else nok streamed_reply_reaches_the_client_unchanged "bytes differ: $(od -c "$work/stream.out" | tail -3)"; fi

post /v1/messages/count_tokens '{"model":"m","messages":[]}' >/dev/null
if [[ "$(last | jq -r .body)" == '{"model":"m","messages":[]}' ]]; then ok other_paths_pass_through_untouched
else nok other_paths_pass_through_untouched "$(last)"; fi

before=$(wc -l <"$work/req.log")
codes=$(for r in "GET /api/tags" "POST /api/pull" "POST /v1/messages/../../api/delete" "DELETE /v1/messages"; do
  curl -s -o /dev/null -w '%{http_code} ' -X "${r%% *}" "$url${r#* }" -d '{}'; done)
if [[ "$codes" == "404 404 404 404 " && "$(wc -l <"$work/req.log")" == "$before" ]]; then ok other_requests_are_refused_and_never_reach_ollama
else nok other_requests_are_refused_and_never_reach_ollama "codes: $codes; upstream saw $(( $(wc -l <"$work/req.log") - before )) request(s)"; fi

post '/v1/messages?beta=true&x=http://192.0.2.1/' '{"model":"m","max_tokens":1,"messages":[]}' >/dev/null
if [[ "$(last | jq -r .path)" == "/v1/messages" ]]; then ok query_string_does_not_reach_ollama
else nok query_string_does_not_reach_ollama "$(last)"; fi

code=$(curl -s -o "$work/fail.out" -w '%{http_code}' -X POST "$url/v1/messages/count_tokens" -H 'x-stub-fail: 1' -d '{}')
if [[ "$code" == 400 && "$(cat "$work/fail.out")" == '{"error":"bad"}' ]]; then ok upstream_error_reaches_the_client_unchanged
else nok upstream_error_reaches_the_client_unchanged "status $code, body $(cat "$work/fail.out")"; fi

# 192.0.2.1 is a documentation address (RFC 5737); the relay must refuse it before connecting.
if python3 -I "$here/lh-nothink-relay.py" http://192.0.2.1:11434 >/dev/null 2>&1; then  # NOSONAR shell:S5332 never contacted
  nok non_loopback_upstream_is_refused "relay started"
else ok non_loopback_upstream_is_refused; fi

echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
