#!/usr/bin/env python3
"""The harness-side interface to the shared memory (ADR-0019). Workstation-only.

    lh-memory.py index            update the memory from the configured sources
    lh-memory.py query TEXT       evidence for TEXT, with provenance and marks   [--k N] [--clone PATH]
    lh-memory.py remember TEXT    store an agent's conclusion, unverified        --agent A --run R [--issue N]
    lh-memory.py promote ID       a human verifies an agent row                  --by WHO
    lh-memory.py expire           drop unverified agent rows older than --days (30)
    lh-memory.py stats            rows per tier and kind

The tier comes from LH_MEMORY_TIER (default public) and from nowhere else: no option sets it, and
the process that starts an agent sets the variable, not the agent. See local/memory.env.example for
the other settings.
"""
import argparse
import datetime as dt
import hashlib
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from lhmem import core, indexer  # noqa: E402
from lhmem.embed import OllamaEmbedder  # noqa: E402
from lhmem.stores import open_dir_store  # noqa: E402


def env(name, default=""):
    return os.environ.get(name) or default


# The LanceDB volume (a required, encrypted mount), in its own directory: AnythingLLM mounts only
# its own subdirectory of the volume, so it cannot see this one.
DEFAULT_DIR = "/var/lib/lancedb/knowledge"


def memory_dir():
    return os.path.expanduser(env("LH_MEMORY_DIR", DEFAULT_DIR))


def build(tier):
    base = memory_dir()
    backend = env("LH_MEMORY_BACKEND", "lancedb")
    emb = OllamaEmbedder(env("LH_EMBED_HOST", "http://127.0.0.1:11435"), env("LH_EMBED_MODEL", "nomic-embed-text"))
    return core.Memory(lambda t: open_dir_store(base, t, backend), tier, emb)


def file_freshness(row):
    path = row.get("source_path")
    if not path:
        return None
    if not os.path.exists(path):
        return "the file is gone"
    with open(path, "rb") as f:
        text = f.read()
    return None if hashlib.sha256(text).hexdigest() == row.get("source_hash") else "the file changed"


def cmd_index(a):
    # Indexing is the maintainer's job and writes both tiers; each row goes to the store of its tier.
    mem = build("private")
    emb = mem.embedder
    for spec in env("LH_MEMORY_REPOS").split():
        tier, path = core.parse_repo_spec(spec)
        path, ref = core.split_ref(os.path.expanduser(path))
        print(f"repo {os.path.basename(path)} ({tier}):", indexer.index_repo(mem.store_for(tier), emb, path,
                                                                            os.path.basename(path), tier, ref))
    notes = env("LH_MEMORY_NOTES")
    if notes:
        notes = os.path.expanduser(notes)
        print(f"notes {os.path.basename(notes)} (private):",
              indexer.index_notes(mem.store_for("private"), emb, notes, "vault"))
    for spec in env("LH_MEMORY_ISSUES").split():
        tier, slug = core.parse_repo_spec(spec) if spec.split(":")[0] in core.TIERS else ("private", spec)
        try:
            issues = indexer.fetch_issues(slug)
        except (subprocess.CalledProcessError, FileNotFoundError) as e:
            err = (getattr(e, "stderr", "") or str(e)).strip().splitlines()
            print(f"issues {slug}: skipped ({err[-1] if err else e})", file=sys.stderr)
            continue
        print(f"issues {slug} ({tier}):", indexer.index_issues(mem.store_for(tier), emb, slug, tier, issues,
                                                              prune=len(issues) < 500))


def cmd_query(a):
    tier = env("LH_MEMORY_TIER", "public")
    mem = build(tier)
    hits = mem.search(a.text, k=a.k, fresh=file_freshness, clone=a.clone)
    n = mem.other_model_rows()
    if n:
        print(f"(note: {n} rows were embedded with another model and are left out until re-indexed)", file=sys.stderr)
    print(core.format_hits(hits) if hits else "(the memory has nothing on this)")


def cmd_remember(a):
    print(build(env("LH_MEMORY_TIER", "public")).remember(a.text, agent=a.agent, run=a.run, issue=a.issue))


def cmd_promote(a):
    build(env("LH_MEMORY_TIER", "public")).promote(a.id, by=a.by)


def cmd_expire(a):
    print(build(env("LH_MEMORY_TIER", "public")).expire(dt.datetime.now(dt.timezone.utc), a.days), "removed")


def cmd_stats(a):
    mem = build(env("LH_MEMORY_TIER", "public"))
    for tier, store in mem.stores.items():
        counts = {}
        for r in store.rows():
            key = (r["kind"], r["embed_model"])
            counts[key] = counts.get(key, 0) + 1
        print(tier + ":", ", ".join(f"{k}/{m}={n}" for (k, m), n in sorted(counts.items())) or "empty")


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("index").set_defaults(fn=cmd_index)
    q = sub.add_parser("query")
    q.add_argument("text")
    q.add_argument("--k", type=int, default=6)
    q.add_argument("--clone")
    q.set_defaults(fn=cmd_query)
    r = sub.add_parser("remember")
    r.add_argument("text")
    r.add_argument("--agent", required=True)
    r.add_argument("--run", required=True)
    r.add_argument("--issue")
    r.set_defaults(fn=cmd_remember)
    pr = sub.add_parser("promote")
    pr.add_argument("id")
    pr.add_argument("--by", required=True)
    pr.set_defaults(fn=cmd_promote)
    e = sub.add_parser("expire")
    e.add_argument("--days", type=int, default=30)
    e.set_defaults(fn=cmd_expire)
    sub.add_parser("stats").set_defaults(fn=cmd_stats)
    a = p.parse_args()
    a.fn(a)


if __name__ == "__main__":
    main()
