#!/usr/bin/env python3
"""Loopback relay between Claude Code and Ollama that switches the model's thinking off.

    lh-nothink-relay.py <ollama-url>

Listens on 127.0.0.1 on a free port and prints that port as its first line of output. It forwards
only the two requests Claude Code makes, POST /v1/messages and POST /v1/messages/count_tokens, to
those fixed paths on <ollama-url>, and passes the reply back unchanged, streamed as it arrives. The
one change: a JSON body POSTed to /v1/messages gets "thinking": {"type": "disabled"}, whatever the
client sent. Any other request gets 404 and never reaches Ollama. Tested by
local/test-lh-nothink-relay.sh.

Why: on Ollama's Anthropic-compatible endpoint a thinking model thinks unless the request says
{"type": "disabled"}. Claude Code (2.1.318, checked against a stub server) sends
{"type": "adaptive"} by default and, with thinking turned off in its settings, sends no "thinking"
field at all, so Ollama still thinks. A "think false" default in the Ollama model is stored but
not applied (Ollama 0.34.0, checked). Aider turns thinking off itself (think: false).
"""
import http.client
import json
import sys
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# The requests the relay forwards: (method, path) to the fixed path it is sent to. Fixed paths,
# so no client input chooses where a request goes.
FORWARDED = {
    ("POST", "/v1/messages"): "/v1/messages",
    ("POST", "/v1/messages/count_tokens"): "/v1/messages/count_tokens",
}

# Headers that describe one connection, not the message; never forwarded.
HOP_BY_HOP = {"connection", "keep-alive", "proxy-authenticate", "proxy-authorization", "te",
              "trailers", "transfer-encoding", "upgrade", "content-length", "host"}


def rewrite(target, body):
    """Return the body to forward: thinking disabled on a JSON /v1/messages request, else unchanged."""
    if target != "/v1/messages":
        return body
    try:
        request = json.loads(body)
    except ValueError:
        return body
    if not isinstance(request, dict):
        return body
    request["thinking"] = {"type": "disabled"}
    return json.dumps(request).encode()


def make_handler(upstream):
    """A request handler class that relays to the parsed upstream URL."""

    class Relay(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def relay(self):
            target = FORWARDED.get((self.command, urllib.parse.urlsplit(self.path).path.rstrip("/")))
            if target is None:
                self.send_error(404, "not forwarded by the thinking-off relay")
                return
            length = int(self.headers.get("content-length") or 0)
            body = rewrite(target, self.rfile.read(length) if length else b"")
            headers = {k: v for k, v in self.headers.items() if k.lower() not in HOP_BY_HOP}
            headers["Content-Length"] = str(len(body))
            # Plain HTTP to Ollama on loopback: main() refuses any other upstream, and Ollama serves
            # no TLS. The connection never leaves this machine.
            conn = http.client.HTTPConnection(upstream.hostname, upstream.port or 80)  # NOSONAR python:S5332 loopback only
            try:
                conn.request("POST", target, body=body, headers=headers)
                reply = conn.getresponse()
                self.send_response(reply.status, reply.reason)
                for k, v in reply.getheaders():
                    if k.lower() not in HOP_BY_HOP:
                        self.send_header(k, v)
                self.send_header("Connection", "close")
                self.end_headers()
                while chunk := reply.read1(65536):
                    self.wfile.write(chunk)
                    self.wfile.flush()
            finally:
                conn.close()

        do_GET = do_POST = do_DELETE = relay

    return Relay


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: lh-nothink-relay.py <ollama-url>")
    upstream = urllib.parse.urlsplit(sys.argv[1])
    if upstream.scheme != "http" or upstream.hostname not in ("127.0.0.1", "localhost"):
        sys.exit(f"upstream must be http on loopback, got {sys.argv[1]!r}")
    # Plain HTTP on 127.0.0.1 only: the client is Claude Code on this machine.
    server = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(upstream))  # NOSONAR python:S5332 loopback only
    print(server.server_address[1], flush=True)
    server.serve_forever()  # NOSONAR python:S5332 loopback only


if __name__ == "__main__":
    main()
