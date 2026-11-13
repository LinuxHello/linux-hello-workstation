"""Tests for local/lhmem (ADR-0019: the shared memory of the coding agents).

Run with local/test-lh-memory.sh. Each test is named after the property it checks. The logic is tested
against the in-memory store and a deterministic embedder, so neither LanceDB nor a model is needed.
"""
import datetime as dt
import http.server
import json
import os
import subprocess
import sys
import tempfile
import threading
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from lhmem import core, indexer  # noqa: E402
from lhmem.embed import ConstEmbedder, HashEmbedder, OllamaEmbedder  # noqa: E402
from lhmem.stores import MemStore  # noqa: E402


class LeakyStore(MemStore):
    """A store whose tier filter is broken: it returns every row to every caller."""

    def vector(self, vec, n, tier):
        return super().vector(vec, n, "private")

    def keyword(self, text, n, tier):
        return super().keyword(text, n, "private")


def opener(stores):
    return lambda tier: stores[tier]


def memory(tier, emb=None, stores=None):
    stores = stores or {"public": MemStore(), "private": MemStore()}
    return core.Memory(opener(stores), tier, emb or HashEmbedder()), stores


def put(stores, emb, tier, kind, text, **kw):
    r = core.make_row(emb, kind=kind, tier=tier, source=kw.pop("source", f"{kind}:{abs(hash(text)) % 999}"),
                      text=text, **kw)
    stores[tier].add([r])
    return r


def git(path, *args):
    subprocess.run(["git", "-C", path, "-c", "user.name=t", "-c", "user.email=t@example.org",
                    "-c", "commit.gpgsign=false", *args], check=True, capture_output=True)


def make_repo(files):
    d = tempfile.mkdtemp()
    git(d, "init", "-q")
    for name, body in files.items():
        p = os.path.join(d, name)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w") as f:
            f.write(body)
    git(d, "add", "-A")
    git(d, "commit", "-q", "-m", "x")
    return d


def make_vault(files):
    d = tempfile.mkdtemp()
    for name, body in files.items():
        p = os.path.join(d, name)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "wb") as f:
            f.write(body if isinstance(body, bytes) else body.encode())
    return d


class Tiers(unittest.TestCase):
    def test_public_tier_never_returns_private_rows(self):
        emb = HashEmbedder()
        mem, st = memory("public", emb)
        put(st, emb, "private", "note", "the vault note about the retry limit and the home network")
        put(st, emb, "public", "code", "retry limit in the agent crate")
        hits = mem.search("retry limit home network")
        self.assertTrue(hits)
        self.assertTrue(all(h["tier"] == "public" for h in hits))
        self.assertFalse(any("vault note" in h["text"] for h in hits))

    def test_public_tier_never_opens_the_private_store(self):
        asked = []

        def spy(tier):
            asked.append(tier)
            return MemStore()

        core.Memory(spy, "public", HashEmbedder())
        self.assertEqual(asked, ["public"])
        core.Memory(spy, "private", HashEmbedder())
        self.assertEqual(asked, ["public", "public", "private"])

    def test_tier_guard_holds_even_if_a_store_ignores_its_filter(self):
        emb = HashEmbedder()
        st = {"public": LeakyStore(), "private": MemStore()}
        mem, _ = memory("public", emb, st)
        # The broken public store holds a private row and hands it out.
        put(st, emb, "private", "note", "private text about the retry limit")
        st["public"].add(st["private"].rows())
        put(st, emb, "public", "code", "public text about the retry limit")
        hits = mem.search("retry limit")
        self.assertEqual([h["tier"] for h in hits], ["public"])

    def test_row_without_tier_is_treated_as_private(self):
        self.assertFalse(core.visible({"kind": "code"}, "public"))
        self.assertFalse(core.visible({"kind": "code", "tier": ""}, "public"))
        self.assertFalse(core.visible({"kind": "code", "tier": "bogus"}, "public"))
        self.assertTrue(core.visible({"kind": "code"}, "private"))

    def test_notes_are_always_private(self):
        emb = HashEmbedder()
        store = MemStore()
        vault = make_vault({"A.md": "# A\n\nsome text", "Sub/B.md": "more text"})
        indexer.index_notes(store, emb, vault, "vault")
        rows = store.rows()
        self.assertTrue(rows)
        self.assertTrue(all(r["tier"] == "private" and r["kind"] == "note" for r in rows))

    def test_unconfigured_repo_is_private(self):
        self.assertEqual(core.parse_repo_spec("/p/x"), ("private", "/p/x"))
        self.assertEqual(core.parse_repo_spec("public:/p/x"), ("public", "/p/x"))
        self.assertEqual(core.parse_repo_spec("private:/p/x"), ("private", "/p/x"))
        with self.assertRaises(ValueError):
            core.parse_repo_spec("secret:/p/x")

    def test_write_inherits_the_callers_tier(self):
        emb = HashEmbedder()
        mem, st = memory("public", emb)
        rid = mem.remember("the model concluded x", agent="draft", run="r1", issue=131)
        self.assertEqual([r["id"] for r in st["public"].rows()], [rid])
        self.assertEqual(st["private"].rows(), [])
        mem2, st2 = memory("private", emb)
        mem2.remember("a private conclusion", agent="clerk", run="r2", issue=None)
        self.assertEqual(len(st2["private"].rows()), 1)
        self.assertEqual(st2["public"].rows(), [])

    def test_promotion_never_changes_the_tier(self):
        emb = HashEmbedder()
        mem, st = memory("private", emb)
        rid = mem.remember("a private conclusion", agent="clerk", run="r", issue=None)
        mem.promote(rid, by="maintainer")
        row = st["private"].get(rid)
        self.assertTrue(row["verified"])
        self.assertEqual(row["tier"], "private")
        with self.assertRaises(core.TierError):
            mem.promote(rid, by="maintainer", tier="public")
        self.assertEqual(st["public"].rows(), [])


class Ranking(unittest.TestCase):
    def test_code_outranks_decision_outranks_issue_outranks_note(self):
        emb = HashEmbedder()
        mem, st = memory("private", emb)
        text = "the retry limit is three attempts"
        for kind in ("agent", "note", "issue", "decision", "code"):
            put(st, emb, "private" if kind in ("note", "agent") else "public", kind, text, source=kind + ":s")
        kinds = [h["kind"] for h in mem.search("retry limit attempts", k=8)]
        self.assertEqual(kinds, ["code", "decision", "issue", "note", "agent"])

    def test_newer_ranks_above_older_within_a_kind(self):
        emb = HashEmbedder()
        mem, st = memory("public", emb)
        put(st, emb, "public", "issue", "the retry limit is three", doc_date="2026-01-01", source="old")
        put(st, emb, "public", "issue", "the retry limit is five", doc_date="2026-09-01", source="new")
        self.assertEqual([h["source"] for h in mem.search("retry limit")], ["new", "old"])

    def test_agent_rows_are_labelled_unverified_and_last(self):
        emb = HashEmbedder()
        mem, st = memory("public", emb)
        mem.remember("the retry limit is three", agent="draft", run="r", issue=1)
        put(st, emb, "public", "issue", "the retry limit is three", source="i")
        hits = mem.search("retry limit")
        self.assertEqual([h["kind"] for h in hits], ["issue", "agent"])
        self.assertFalse(hits[1]["verified"])
        self.assertIn("UNVERIFIED", core.format_hits(hits))
        self.assertNotIn("UNVERIFIED", core.format_hits(hits[:1]))

    def test_promoted_agent_row_is_labelled_verified_but_still_ranks_below_notes(self):
        emb = HashEmbedder()
        mem, st = memory("private", emb)
        rid = mem.remember("the retry limit is three", agent="draft", run="r", issue=1)
        mem.promote(rid, by="maintainer")
        put(st, emb, "private", "note", "the retry limit is three", source="n")
        hits = mem.search("retry limit")
        self.assertEqual([h["kind"] for h in hits], ["note", "agent"])
        self.assertTrue(hits[1]["verified"])
        self.assertNotIn("UNVERIFIED", core.format_hits(hits))

    def test_nothing_is_dropped_on_conflict(self):
        emb = HashEmbedder()
        mem, st = memory("private", emb)
        put(st, emb, "public", "decision", "the retry limit is three attempts", doc_date="2026-11-01", source="adr")
        put(st, emb, "private", "note", "the retry limit is five attempts", doc_date="2026-08-01", source="note")
        hits = mem.search("retry limit attempts")
        self.assertEqual(len(hits), 2)
        self.assertIsNotNone(hits[0]["conflict"])
        self.assertEqual(hits[0]["conflict"], hits[1]["conflict"])
        self.assertIn("CONFLICT", core.format_hits(hits))

    def test_no_conflict_when_same_kind_and_date_or_unrelated(self):
        emb = HashEmbedder()
        mem, st = memory("private", emb)
        put(st, emb, "public", "issue", "the retry limit is three attempts", doc_date="2026-11-01", source="a")
        put(st, emb, "public", "issue", "the retry limit is five attempts", doc_date="2026-11-01", source="b")
        put(st, emb, "private", "note", "completely different words about camera sensors", source="c")
        hits = mem.search("retry limit attempts camera sensors", k=8)
        self.assertTrue(all(h["conflict"] is None for h in hits))

    def test_exact_identifier_is_found_by_keyword(self):
        emb = ConstEmbedder()
        mem, st = memory("public", emb)
        for i in range(20):
            put(st, emb, "public", "code", f"filler chunk number {i}", source=f"f{i}")
        put(st, emb, "public", "code", "fn lh_brief_open_points(clone, issue)", source="target")
        hits = mem.search("lh_brief_open_points", k=3)
        self.assertEqual(hits[0]["source"], "target")

    def test_rows_embedded_with_another_model_are_excluded(self):
        emb = HashEmbedder(model="current")
        mem, st = memory("public", emb)
        put(st, HashEmbedder(model="old"), "public", "code", "the retry limit is three", source="old")
        put(st, emb, "public", "code", "the retry limit is five", source="new")
        self.assertEqual([h["source"] for h in mem.search("retry limit")], ["new"])
        self.assertEqual(mem.other_model_rows(), 1)

    def test_a_hit_whose_source_changed_is_flagged(self):
        emb = HashEmbedder()
        mem, st = memory("public", emb)
        put(st, emb, "public", "code", "the retry limit is three", source="s")
        hits = mem.search("retry limit", fresh=lambda row: "file changed since it was read")
        self.assertEqual(hits[0]["stale"], "file changed since it was read")
        self.assertIn("SOURCE CHANGED SINCE READ", core.format_hits(hits))


class Verify(unittest.TestCase):
    def test_unverified_hit_names_identifiers_missing_from_the_repository(self):
        clone = make_repo({"src/lib.rs": "pub struct Api;\nimpl Api { pub fn record_uid(&self) {} }\n"})
        emb = HashEmbedder()
        mem, st = memory("private", emb)
        put(st, emb, "private", "note", "call `set_user_policy_verified` on `Api` after `record_uid`", source="n")
        hits = mem.search("set_user_policy_verified record_uid", clone=clone)
        self.assertEqual(hits[0]["not_in_repo"], ["set_user_policy_verified"])
        self.assertIn("NOT IN REPOSITORY: set_user_policy_verified", core.format_hits(hits))

    def test_code_and_decision_hits_are_not_checked_against_the_repository(self):
        clone = make_repo({"a.rs": "fn x() {}\n"})
        emb = HashEmbedder()
        mem, st = memory("public", emb)
        put(st, emb, "public", "code", "see `nothing_like_this_exists_anywhere`", source="c")
        self.assertEqual(mem.search("nothing_like_this_exists_anywhere", clone=clone)[0]["not_in_repo"], [])

    def test_expired_unverified_agent_rows_are_removed_and_verified_ones_kept(self):
        emb = HashEmbedder()
        mem, st = memory("public", emb)
        old = (dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=40)).isoformat()
        a = mem.remember("old unverified", agent="d", run="r", issue=1)
        b = mem.remember("old verified", agent="d", run="r", issue=1)
        c = mem.remember("fresh unverified", agent="d", run="r", issue=1)
        for rid in (a, b):
            st["public"].update(rid, {"created": old})
        mem.promote(b, by="maintainer")
        removed = mem.expire(dt.datetime.now(dt.timezone.utc), days=30)
        self.assertEqual(removed, 1)
        self.assertEqual({r["id"] for r in st["public"].rows()}, {b, c})


class Indexing(unittest.TestCase):
    def test_indexer_skips_media_and_excluded_folders(self):
        vault = make_vault({
            "Keep.md": "# Keep\n\ntext", "Sub/Also.md": "text",
            "img.png": b"\x89PNG", "Videos/v.mp4": b"\x00\x00", "Audio/a.mp3": b"id3",
            ".obsidian/workspace.md": "x", ".trash/gone.md": "x", "Claude outputs/out.md": "model text",
            ".git": "gitdir: elsewhere",
        })
        store = MemStore()
        indexer.index_notes(store, HashEmbedder(), vault, "vault")
        self.assertEqual({r["source_id"] for r in store.rows()}, {"vault:Keep.md", "vault:Sub/Also.md"})

    def test_note_frontmatter_status_and_date_are_kept(self):
        vault = make_vault({"N.md": "---\nstatus: superseded\ndate: 2026-03-04\n---\n# N\n\nbody text"})
        store = MemStore()
        indexer.index_notes(store, HashEmbedder(), vault, "vault")
        row = store.rows()[0]
        self.assertEqual((row["doc_status"], row["doc_date"]), ("superseded", "2026-03-04"))
        self.assertNotIn("status: superseded", row["text"])

    def test_changed_source_is_reindexed_and_old_chunks_removed(self):
        vault = make_vault({"N.md": "# N\n\nold words here"})
        store, emb = MemStore(), HashEmbedder()
        indexer.index_notes(store, emb, vault, "vault")
        with open(os.path.join(vault, "N.md"), "w") as f:
            f.write("# N\n\nnew words here")
        summary = indexer.index_notes(store, emb, vault, "vault")
        self.assertEqual(summary["changed"], 1)
        texts = " ".join(r["text"] for r in store.rows())
        self.assertIn("new words", texts)
        self.assertNotIn("old words", texts)

    def test_deleted_source_is_removed(self):
        vault = make_vault({"A.md": "alpha text", "B.md": "beta text"})
        store, emb = MemStore(), HashEmbedder()
        indexer.index_notes(store, emb, vault, "vault")
        os.remove(os.path.join(vault, "B.md"))
        summary = indexer.index_notes(store, emb, vault, "vault")
        self.assertEqual(summary["removed"], 1)
        self.assertEqual({r["source_id"] for r in store.rows()}, {"vault:A.md"})

    def test_unchanged_source_is_not_re_embedded(self):
        vault = make_vault({"A.md": "alpha text"})
        store, emb = MemStore(), HashEmbedder()
        indexer.index_notes(store, emb, vault, "vault")
        before = emb.calls
        summary = indexer.index_notes(store, emb, vault, "vault")
        self.assertEqual(emb.calls, before)
        self.assertEqual((summary["unchanged"], summary["added"], summary["changed"]), (1, 0, 0))

    def test_only_accepted_adrs_are_decisions(self):
        repo = make_repo({
            "adr/0001-a.md": "---\nstatus: accepted\ndate: 2026-11-01\n---\n# ADR-0001\n\naccepted text",
            "adr/0002-b.md": "---\nstatus: proposed\ndate: 2026-11-02\n---\n# ADR-0002\n\nproposed text",
            "src/lib.rs": "fn main() {}\n",
        })
        store = MemStore()
        indexer.index_repo(store, HashEmbedder(), repo, "arch", "public")
        kinds = {r["source_id"]: r["kind"] for r in store.rows()}
        self.assertEqual(kinds["arch:adr/0001-a.md"], "decision")
        self.assertEqual(kinds["arch:adr/0002-b.md"], "issue")
        self.assertEqual(kinds["arch:src/lib.rs"], "code")

    def test_repo_index_reads_head_not_the_working_tree(self):
        repo = make_repo({"a.rs": "fn committed_version() {}\n"})
        with open(os.path.join(repo, "a.rs"), "w") as f:
            f.write("fn uncommitted_edit() {}\n")
        store = MemStore()
        indexer.index_repo(store, HashEmbedder(), repo, "r", "public")
        text = " ".join(r["text"] for r in store.rows())
        self.assertIn("committed_version", text)
        self.assertNotIn("uncommitted_edit", text)

    def test_repo_rows_carry_the_tier_of_the_configuration(self):
        repo = make_repo({"a.rs": "fn a() {}\n"})
        store = MemStore()
        indexer.index_repo(store, HashEmbedder(), repo, "r", "private")
        self.assertTrue(all(r["tier"] == "private" for r in store.rows()))

    def test_indexer_leaves_agent_rows_alone(self):
        emb = HashEmbedder()
        mem, st = memory("public", emb)
        rid = mem.remember("an agent conclusion", agent="d", run="r", issue=1)
        repo = make_repo({"a.rs": "fn a() {}\n"})
        indexer.index_repo(st["public"], emb, repo, "r", "public")
        os.remove(os.path.join(repo, "a.rs"))
        git(repo, "rm", "-q", "a.rs")
        git(repo, "commit", "-q", "-m", "rm")
        indexer.index_repo(st["public"], emb, repo, "r", "public")
        self.assertEqual([r["id"] for r in st["public"].rows()], [rid])

    def test_issue_rows_are_public_claims_with_their_date_and_state(self):
        issues = [{"number": 131, "title": "Verify uid", "body": "body text", "state": "OPEN",
                   "updatedAt": "2026-11-10T10:00:00Z", "comments": [{"body": "## Implementation brief\n\nx"}]}]
        store = MemStore()
        indexer.index_issues(store, HashEmbedder(), "LinuxHello/linux-hello", "public", issues)
        row = store.rows()[0]
        self.assertEqual((row["kind"], row["tier"], row["doc_status"], row["doc_date"]),
                         ("issue", "public", "open", "2026-11-10"))
        self.assertIn("Implementation brief", row["text"])


class Embedding(unittest.TestCase):
    def test_ollama_embedder_posts_model_and_input(self):
        seen = []

        class H(http.server.BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                seen.append((self.path, body))
                out = json.dumps({"embeddings": [[1.0, 0.0] for _ in body["input"]]}).encode()
                self.send_response(200)
                self.send_header("Content-Length", str(len(out)))
                self.end_headers()
                self.wfile.write(out)

        srv = http.server.HTTPServer(("127.0.0.1", 0), H)  # NOSONAR loopback only, test stub
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        try:
            emb = OllamaEmbedder(f"http://127.0.0.1:{srv.server_address[1]}", "nomic-embed-text", batch=2)
            vecs = emb(["a", "b", "c"])
        finally:
            srv.shutdown()
            srv.server_close()
        self.assertEqual(len(vecs), 3)
        self.assertEqual(seen[0][0], "/api/embed")
        self.assertEqual(seen[0][1], {"model": "nomic-embed-text", "input": ["a", "b"]})
        self.assertEqual(seen[1][1]["input"], ["c"])
        self.assertEqual(emb.model, "nomic-embed-text")


try:
    import lancedb  # noqa: F401
    HAVE_LANCE = True
except ImportError:
    HAVE_LANCE = False


@unittest.skipUnless(HAVE_LANCE, "lancedb is not installed (make memory-venv)")
class LanceRoundTrip(unittest.TestCase):
    def test_lance_store_round_trip_tier_filter_update_and_delete(self):
        from lhmem.stores import LanceStore
        emb = HashEmbedder()
        store = LanceStore(tempfile.mkdtemp())
        a = core.make_row(emb, kind="code", tier="public", source="s:a", text="the retry limit is three", scope="s")
        b = core.make_row(emb, kind="note", tier="private", source="s:b", text="the retry limit is five", scope="s")
        store.add([a, b])
        q = emb(["retry limit"])[0]
        self.assertEqual({r["id"] for r, _ in store.vector(q, 5, "public")}, {a["id"]})
        self.assertEqual({r["id"] for r, _ in store.vector(q, 5, "private")}, {a["id"], b["id"]})
        self.assertEqual({r["id"] for r, _ in store.keyword("five", 5, "private")}, {b["id"]})
        self.assertEqual(store.source_hashes("s"), {"s:a": "", "s:b": ""})
        store.update(a["id"], {"verified": False})
        self.assertFalse(store.get(a["id"])["verified"])
        store.delete_source("s:a")
        self.assertEqual([r["id"] for r in store.rows()], [b["id"]])


if __name__ == "__main__":
    unittest.main()
