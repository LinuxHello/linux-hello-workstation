"""Stores for the memory rows: an in-memory one (tests), a JSON-lines file (small corpora, tests), and
LanceDB (production, ADR-0019). All have the same methods; core.Memory re-checks what they return.

    add(rows)  get(id)  update(id, fields)  delete_ids(ids)  delete_source(source_id)  rows()
    source_hashes(scope) -> {source_id: source_hash}
    vector(vec, n, tier) -> [(row, cosine similarity)]    keyword(text, n, tier) -> [(row, score)]
    flush()
"""
import json
import math
import os
import re

from . import core

_WORD = re.compile(r"[a-z0-9_]+")


def _tokens(text):
    return _WORD.findall(text.lower())


def keyword_scores(rows, text, n):
    """A small BM25-like ranking over whole tokens, so identifiers and error strings match exactly."""
    q = set(_tokens(text))
    if not q or not rows:
        return []
    docs = [(r, _tokens(r["text"] + " " + r.get("location", ""))) for r in rows]
    df = {t: sum(1 for _, d in docs if t in d) for t in q}
    avg = sum(len(d) for _, d in docs) / len(docs) or 1.0
    scored = []
    for row, doc in docs:
        s = 0.0
        for t in q:
            tf = doc.count(t)
            if tf:
                idf = math.log(1 + (len(docs) - df[t] + 0.5) / (df[t] + 0.5))
                s += idf * tf * 2.2 / (tf + 1.2 * (0.25 + 0.75 * len(doc) / avg))
        if s > 0:
            scored.append((row, s))
    scored.sort(key=lambda x: -x[1])
    return scored[:n]


class MemStore:
    def __init__(self):
        self._rows = {}

    def add(self, rows):
        for r in rows:
            self._rows[r["id"]] = dict(r)

    def get(self, row_id):
        r = self._rows.get(row_id)
        return dict(r) if r else None

    def update(self, row_id, fields):
        self._rows[row_id].update(fields)

    def delete_ids(self, ids):
        for i in ids:
            self._rows.pop(i, None)

    def delete_source(self, source_id):
        self.delete_ids([i for i, r in self._rows.items() if r["source_id"] == source_id])

    def rows(self):
        return [dict(r) for r in self._rows.values()]

    def source_hashes(self, scope):
        return {r["source_id"]: r["source_hash"] for r in self._rows.values() if r.get("scope") == scope}

    def _allowed(self, tier):
        return [r for r in self._rows.values() if core.visible(r, tier)]

    def vector(self, vec, n, tier):
        scored = [(dict(r), core.cosine(vec, r["vector"])) for r in self._allowed(tier)]
        scored.sort(key=lambda x: -x[1])
        return scored[:n]

    def keyword(self, text, n, tier):
        return [(dict(r), s) for r, s in keyword_scores(self._allowed(tier), text, n)]

    def flush(self):
        pass


class JsonlStore(MemStore):
    """Rows in one JSON-lines file. For tests and small corpora; the vector search is a linear scan."""

    def __init__(self, path):
        super().__init__()
        self.path = path
        if os.path.exists(path):
            with open(path) as f:
                for line in f:
                    if line.strip():
                        r = json.loads(line)
                        self._rows[r["id"]] = r

    def flush(self):
        os.makedirs(os.path.dirname(self.path), exist_ok=True)
        tmp = self.path + ".tmp"
        with open(tmp, "w") as f:
            for r in self._rows.values():
                f.write(json.dumps(r) + "\n")
        os.replace(tmp, self.path)


class LanceStore:
    """LanceDB. Written against the documented API but not run by the unit tests (they do not need
    lancedb); `make test` runs the round trip in test_lhmem.py once `make memory-venv` has installed it."""

    TABLE = "memory"
    TEXT = ("id", "kind", "tier", "source", "source_id", "scope", "location", "revision", "source_hash",
            "doc_status", "doc_date", "source_path", "embed_model", "text", "agent", "run", "issue",
            "created", "promoted_by", "promoted")

    def __init__(self, path):
        import lancedb  # imported here so the rest of the package works without it
        self._pa = __import__("pyarrow")
        os.makedirs(path, exist_ok=True)
        self.db = lancedb.connect(path)
        self.tbl = self.db.open_table(self.TABLE) if self.TABLE in self.db.table_names() else None
        self._cache = None

    @staticmethod
    def _q(s):
        return str(s).replace("'", "''")

    def _flat(self, r):
        out = {k: str(r.get(k, "") or "") for k in self.TEXT}
        out.update(verified=bool(r.get("verified")), embed_dim=int(r["embed_dim"]),
                   vector=[float(x) for x in r["vector"]])
        return out

    def _schema(self, dim):
        pa = self._pa
        fields = [pa.field(k, pa.string()) for k in self.TEXT]
        fields += [pa.field("verified", pa.bool_()), pa.field("embed_dim", pa.int32()),
                   pa.field("vector", pa.list_(pa.float32(), dim))]
        return pa.schema(fields)

    def add(self, rows):
        rows = [self._flat(r) for r in rows]
        if not rows:
            return
        if self.tbl is None:
            self.tbl = self.db.create_table(self.TABLE, data=rows, schema=self._schema(len(rows[0]["vector"])))
        else:
            self.tbl.add(rows)
        self._cache = None

    def rows(self):
        if self.tbl is None:
            return []
        if self._cache is None:
            self._cache = self.tbl.to_arrow().to_pylist()
        return [dict(r) for r in self._cache]

    def get(self, row_id):
        return next((r for r in self.rows() if r["id"] == row_id), None)

    def update(self, row_id, fields):
        self.tbl.update(where=f"id = '{self._q(row_id)}'", values=fields)
        self._cache = None

    def delete_ids(self, ids):
        for i in ids:
            self.tbl.delete(f"id = '{self._q(i)}'")
        self._cache = None

    def delete_source(self, source_id):
        if self.tbl is not None:
            self.tbl.delete(f"source_id = '{self._q(source_id)}'")
            self._cache = None

    def source_hashes(self, scope):
        return {r["source_id"]: r["source_hash"] for r in self.rows() if r["scope"] == scope}

    def vector(self, vec, n, tier):
        if self.tbl is None:
            return []
        q = self.tbl.search([float(x) for x in vec]).metric("cosine")
        if tier != "private":
            q = q.where("tier = 'public'", prefilter=True)
        return [(r, 1.0 - float(r["_distance"])) for r in q.limit(n).to_list()]

    def keyword(self, text, n, tier):
        # The scan is the simple path: exact tokens, no index to keep in step with writes.
        return [(r, s) for r, s in keyword_scores([r for r in self.rows() if core.visible(r, tier)], text, n)]

    def flush(self):
        pass


def open_dir_store(base, tier, backend="lancedb"):
    """The store of one tier: <base>/<tier>. The private directory is for its owner only."""
    path = os.path.join(base, tier)
    os.makedirs(path, mode=0o700 if tier == "private" else 0o755, exist_ok=True)
    if backend == "jsonl":
        return JsonlStore(os.path.join(path, "rows.jsonl"))
    if backend == "lancedb":
        return LanceStore(path)
    raise ValueError(f"unknown backend {backend!r}")
