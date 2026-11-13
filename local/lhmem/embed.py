"""Embedders: a callable that maps a list of texts to a list of vectors, with .model and .dim."""
import hashlib
import json
import math
import re
import urllib.request


class OllamaEmbedder:
    """Embeddings from an Ollama server (the CPU instance, so the GPU models stay loaded)."""

    def __init__(self, host, model, batch=32, timeout=300):
        self.host = host.rstrip("/")
        self.model = model
        self.batch = batch
        self.timeout = timeout
        self.dim = None

    def __call__(self, texts):
        out = []
        for i in range(0, len(texts), self.batch):
            body = json.dumps({"model": self.model, "input": texts[i:i + self.batch]}).encode()
            req = urllib.request.Request(self.host + "/api/embed", data=body,
                                         headers={"Content-Type": "application/json"})
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:  # NOSONAR the host is the local Ollama
                out.extend(json.load(resp)["embeddings"])
        if out:
            self.dim = len(out[0])
        return out


class HashEmbedder:
    """Deterministic bag-of-words vectors for the tests: texts that share words are close."""

    def __init__(self, dim=256, model="hash-test"):
        self.dim, self.model, self.calls = dim, model, 0

    def __call__(self, texts):
        self.calls += len(texts)
        out = []
        for t in texts:
            v = [0.0] * self.dim
            for w in re.findall(r"[a-z0-9_]+", t.lower()):
                h = int(hashlib.md5(w.encode()).hexdigest(), 16)  # NOSONAR not a security use
                v[h % self.dim] += 1.0 if (h >> 64) & 1 else -1.0
            n = math.sqrt(sum(x * x for x in v)) or 1.0
            out.append([x / n for x in v])
        return out


class ConstEmbedder(HashEmbedder):
    """Every text gets the same vector, so only keyword search can tell rows apart."""

    def __init__(self):
        super().__init__(dim=4, model="const")

    def __call__(self, texts):
        self.calls += len(texts)
        return [[1.0, 0.0, 0.0, 0.0] for _ in texts]
