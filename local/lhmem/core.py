"""The memory contract of ADR-0019, independent of the store and the embedder.

The memory is a rebuildable index plus an append-only log of what agents concluded. It returns
evidence (kind, source, date, status, text), never a verdict, and it marks what an agent should not
trust: conflicts between hits, agent-written rows nobody has verified, names a note cites that the
repository does not contain, and sources that changed since they were read.

The tier of the caller is fixed by whoever starts it, never by a query. A public-tier Memory does not
open the private store at all; `visible` is a second guard for a store that misbehaves, and a row
with no valid tier counts as private.
"""
import datetime as dt
import hashlib
import math
import re
import subprocess
import uuid

TIERS = ("public", "private")
# Lower ranks first. Live code outranks any note about it; a reviewed decision outranks a claim; an
# unverified agent row comes last (ADR-0019, "How an agent reads it").
AUTHORITY = {"code": 0, "decision": 1, "issue": 2, "note": 3}
AUTHORITY_VERIFIED_AGENT = 3.5
AUTHORITY_UNVERIFIED_AGENT = 4


class TierError(Exception):
    pass


def authority(row):
    if row.get("kind") == "agent":
        return AUTHORITY_VERIFIED_AGENT if row.get("verified") else AUTHORITY_UNVERIFIED_AGENT
    return AUTHORITY.get(row.get("kind"), AUTHORITY_UNVERIFIED_AGENT)


def visible(row, tier):
    """May a caller of this tier see the row? Anything without a valid tier is private."""
    if tier == "private":
        return True
    return row.get("tier") == "public"


def parse_repo_spec(spec):
    """'public:/path', 'private:/path' or '/path' (private: a repository is public only when said so)."""
    if spec.startswith(("/", "~", ".")):
        return "private", spec
    head, sep, rest = spec.partition(":")
    if not sep or head not in TIERS:
        raise ValueError(f"expected public:<path> or private:<path>, got {spec!r}")
    return head, rest


def now_iso():
    return dt.datetime.now(dt.timezone.utc).isoformat()


def make_row(embedder, *, kind, tier, source, text, source_id=None, scope="", chunk=0, location="",
             revision="", source_hash="", doc_status="", doc_date="", source_path="", agent="", run="",
             issue="", verified=None, created=None, vector=None):
    """One row, embedded unless a vector is given."""
    if tier not in TIERS:
        raise TierError(f"bad tier {tier!r}")
    sid = source_id or source
    vec = vector if vector is not None else embedder([text])[0]
    return {
        "id": hashlib.sha1(f"{sid}|{chunk}|{text}".encode()).hexdigest(),  # NOSONAR identifier, not security
        "kind": kind, "tier": tier, "source": source, "source_id": sid, "scope": scope,
        "location": location or source, "revision": revision, "source_hash": source_hash,
        "doc_status": doc_status, "doc_date": doc_date, "source_path": source_path,
        "embed_model": embedder.model, "embed_dim": len(vec), "text": text, "vector": list(vec),
        "agent": agent, "run": run, "issue": "" if issue is None else str(issue),
        "verified": (kind != "agent") if verified is None else bool(verified),
        "created": created or now_iso(),
    }


def cosine(a, b):
    na = math.sqrt(sum(x * x for x in a))
    nb = math.sqrt(sum(x * x for x in b))
    return sum(x * y for x, y in zip(a, b)) / (na * nb) if na and nb else 0.0


_IDENT = re.compile(r"`([A-Za-z_][A-Za-z0-9_./:-]{2,})`")


def _checkable(name):
    return "_" in name or "::" in name or "/" in name or re.search(r"\.[A-Za-z]{1,5}$", name) \
        or re.search(r"[a-z][A-Z]", name)


def missing_identifiers(text, clone, limit=12):
    """Backticked names and paths in text that the repository at <clone> does not contain."""
    missing = []
    for name in list(dict.fromkeys(_IDENT.findall(text)))[:limit]:
        if not _checkable(name):
            continue
        if "/" in name or re.search(r"\.[A-Za-z]{1,5}$", name):
            r = subprocess.run(["git", "-C", clone, "ls-files", "--", name], capture_output=True, text=True)
            found = bool(r.stdout.strip()) or subprocess.run(
                ["git", "-C", clone, "grep", "-qwF", "--", name], capture_output=True).returncode == 0
        else:
            word = name.split("::")[-1]
            found = subprocess.run(["git", "-C", clone, "grep", "-qwF", "--", word],
                                   capture_output=True).returncode == 0
        if not found:
            missing.append(name)
    return missing


def _norm(text):
    return " ".join(text.lower().split())


class Memory:
    def __init__(self, open_store, tier, embedder, min_sim=0.2, conflict_threshold=0.75):
        if tier not in TIERS:
            raise TierError(f"bad tier {tier!r}")
        self.tier, self.embedder = tier, embedder
        self.min_sim, self.conflict_threshold = min_sim, conflict_threshold
        # A public-tier caller never asks for the private store.
        self.stores = {"public": open_store("public")}
        if tier == "private":
            self.stores["private"] = open_store("private")

    def store_for(self, tier):
        if tier not in self.stores:
            raise TierError(f"this {self.tier}-tier memory has no {tier} store")
        return self.stores[tier]

    # -- reading -----------------------------------------------------------------------------

    def _ok(self, row):
        return visible(row, self.tier) and row.get("embed_model") == self.embedder.model

    def other_model_rows(self):
        return sum(1 for s in self.stores.values() for r in s.rows()
                   if visible(r, self.tier) and r.get("embed_model") != self.embedder.model)

    def search(self, query, k=8, fresh=None, clone=None):
        qv = self.embedder([query])[0]
        n = max(k * 4, 20)
        fused, rows = {}, {}
        for store in self.stores.values():
            ranked = [("v", store.vector(qv, n, self.tier)), ("k", store.keyword(query, n, self.tier))]
            for which, hits in ranked:
                hits = [(r, s) for r, s in hits if self._ok(r) and (which == "k" or s >= self.min_sim)]
                for rank, (row, _) in enumerate(hits):
                    # Exact matches (identifiers, paths, error strings) count for more than similarity.
                    fused[row["id"]] = fused.get(row["id"], 0.0) + (1.5 if which == "k" else 1.0) / (60 + rank)
                    rows[row["id"]] = row
        order = sorted(fused, key=lambda i: -fused[i])[:n]
        # Stable sorts, least significant key first: authority, then newer, then fused score.
        order.sort(key=lambda i: rows[i].get("doc_date") or "", reverse=True)
        order.sort(key=lambda i: authority(rows[i]))
        picked = order[:k]
        hits = [self._hit(rows[i], fused[i], fresh, clone) for i in picked]
        self._mark_conflicts(hits, [rows[i]["vector"] for i in picked])
        return hits

    def _hit(self, row, score, fresh, clone):
        hit = {k: v for k, v in row.items() if k != "vector"}
        hit.update(score=score, conflict=None, stale=fresh(row) if fresh else None,
                   not_in_repo=missing_identifiers(row["text"], clone)
                   if clone and row.get("kind") in ("note", "agent") else [])
        return hit

    def _mark_conflicts(self, hits, vecs):
        parent = list(range(len(hits)))

        def find(i):
            while parent[i] != i:
                parent[i] = parent[parent[i]]
                i = parent[i]
            return i

        linked = set()
        for i in range(len(hits)):
            for j in range(i + 1, len(hits)):
                a, b = hits[i], hits[j]
                if _norm(a["text"]) == _norm(b["text"]):
                    continue
                if a["kind"] == b["kind"] and (a.get("doc_date") or "") == (b.get("doc_date") or ""):
                    continue
                if cosine(vecs[i], vecs[j]) >= self.conflict_threshold:
                    parent[find(i)] = find(j)
                    linked.update((i, j))
        names = {}
        for i in sorted(linked):
            root = find(i)
            names.setdefault(root, f"C{len(names) + 1}")
            hits[i]["conflict"] = names[root]

    # -- writing -----------------------------------------------------------------------------

    def remember(self, text, agent, run, issue):
        """An agent's conclusion. It lands in the caller's own tier, unverified."""
        rid = uuid.uuid4().hex
        row = make_row(self.embedder, kind="agent", tier=self.tier, source=f"agent:{agent}:{run}",
                       source_id=f"agent:{rid}", scope="agent", text=text, agent=agent, run=run, issue=issue)
        row["id"] = rid
        self.store_for(self.tier).add([row])
        self.store_for(self.tier).flush()
        return rid

    def _find(self, row_id):
        for store in self.stores.values():
            row = store.get(row_id)
            if row and visible(row, self.tier):
                return store, row
        raise KeyError(row_id)

    def promote(self, row_id, by, tier=None):
        """A human (or a passing test) verifies an agent row. The tier never changes."""
        store, row = self._find(row_id)
        if tier is not None and tier != row["tier"]:
            raise TierError("a row never changes tier by promotion; write it again through a public source")
        if row["kind"] != "agent":
            raise ValueError("only agent rows are promoted")
        store.update(row_id, {"verified": True, "promoted_by": by, "promoted": now_iso()})
        store.flush()

    def expire(self, now, days):
        """Remove unverified agent rows older than <days>. Returns how many."""
        cutoff = (now - dt.timedelta(days=days)).isoformat()
        removed = 0
        for store in self.stores.values():
            gone = [r["id"] for r in store.rows()
                    if r["kind"] == "agent" and not r["verified"] and r["created"] < cutoff]
            store.delete_ids(gone)
            store.flush()
            removed += len(gone)
        return removed


def format_hits(hits, limit_chars=700):
    """The text a prompt gets: evidence with its provenance and the marks an agent must not skip."""
    out, groups = [], set()
    for n, h in enumerate(hits, 1):
        marks = []
        if h.get("conflict"):
            marks.append(f"CONFLICT {h['conflict']}")
            groups.add(h["conflict"])
        if h["kind"] == "agent" and not h.get("verified"):
            marks.append("UNVERIFIED")
        if h.get("not_in_repo"):
            marks.append("NOT IN REPOSITORY: " + ", ".join(h["not_in_repo"]))
        if h.get("stale"):
            marks.append("SOURCE CHANGED SINCE READ: " + h["stale"])
        head = " | ".join(x for x in (h["kind"], h.get("location") or h["source"], h.get("doc_date"),
                                      h.get("doc_status")) if x)
        text = h["text"] if len(h["text"]) <= limit_chars else h["text"][:limit_chars] + " [...]"
        out.append(f"[{n}] {head}" + (f"  <{'; '.join(marks)}>" if marks else "") + "\n" + text)
    if groups:
        out.append("Hits marked CONFLICT with the same label disagree. Do not choose between them: "
                   "settle it from the code, or list it under '## Open questions for the lead'.")
    return "\n\n".join(out)
