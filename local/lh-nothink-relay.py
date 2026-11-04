#!/usr/bin/env python3
"""Loopback relay between Claude Code and Ollama that switches the model's thinking off.

    lh-nothink-relay.py <ollama-url>

Listens on 127.0.0.1 on a free port and prints that port as its first line of output. Every request
is passed to <ollama-url> and its reply passed back unchanged, streamed as it arrives, except one
thing: a JSON body POSTed to /v1/messages gets "thinking": {"type": "disabled"}, whatever the client
sent. Tested by local/test-lh-nothink-relay.sh.

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

# Headers that describe one connection, not the message; never forwarded.
HOP_BY_HOP = {"connection", "keep-alive", "proxy-authenticate", "proxy-authorization", "te",
              "trailers", "transfer-encoding", "upgrade", "content-length", "host"}


def rewrite(path, body):
    """Return the body to forward: thinking disabled on a JSON /v1/messages request, else unchanged."""
    if urllib.parse.urlsplit(path).path.rstrip("/") != "/v1/messages":
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
            length = int(self.headers.get("content-length") or 0)
            body = self.rfile.read(length) if length else b""
            if self.command == "POST":
                body = rewrite(self.path, body)
            headers = {k: v for k, v in self.headers.items() if k.lower() not in HOP_BY_HOP}
            if self.command == "POST" or body:
                headers["Content-Length"] = str(len(body))
            conn = http.client.HTTPConnection(upstream.hostname, upstream.port or 80)
            try:
                conn.request(self.command, self.path, body=body or None, headers=headers)
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
    server = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(upstream))
    print(server.server_address[1], flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
