"""A stub of the Ollama API for the shell tests; test code only.

  stub-ollama.py <dir> [pulled-model ...]

<dir>/loaded lists the loaded models, <dir>/log records the /api/generate requests, <dir>/port gets
the port. /api/ps and /api/tags answer from the files and the arguments, /api/show gives every model
a 32768-token window, and /api/generate loads a model or, with keep_alive 0, unloads it, and /api/embed answers
with hash vectors (lhmem.embed.HashEmbedder).
"""
import http.server, json, os, sys, tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lhmem.embed import HashEmbedder  # noqa: E402  deterministic stand-in for an embedding model

# The state directory must be a real directory inside the temporary directory: the tests make it
# with mktemp -d, and nothing else may be written through this argument.
work = os.path.realpath(sys.argv[1])
pulled = sys.argv[2:]
if not work.startswith(os.path.realpath(tempfile.gettempdir()) + os.sep) or not os.path.isdir(work):
    sys.exit("stub-ollama: the state directory must be inside " + tempfile.gettempdir())
loaded = os.path.join(work, "loaded")


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, obj):
        body = json.dumps(obj).encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def names(self):
        return [l.strip() for l in open(loaded) if l.strip()] if os.path.exists(loaded) else []

    def do_GET(self):
        every = self.names() + [p for p in pulled if p not in self.names()]
        self.reply({"models": [{"name": n} for n in (every if self.path == "/api/tags" else self.names())]})

    def do_POST(self):
        req = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        if self.path == "/api/embed":
            return self.reply({"embeddings": HashEmbedder(model=req["model"])(req["input"])})
        if self.path == "/api/show":
            return self.reply({"parameters": "num_ctx 32768"})
        open(os.path.join(work, "log"), "a").write(json.dumps(req) + "\n")
        names = [n for n in self.names() if n != req["model"]]
        if req.get("keep_alive") != 0:
            names.append(req["model"])
        open(loaded, "w").write("\n".join(names) + "\n")
        self.reply({})


server = http.server.HTTPServer(("127.0.0.1", 0), Handler)  # NOSONAR python:S5332 loopback only, test stub
open(os.path.join(work, "port"), "w").write(str(server.server_address[1]))
server.serve_forever()  # NOSONAR python:S5332 loopback only, test stub
