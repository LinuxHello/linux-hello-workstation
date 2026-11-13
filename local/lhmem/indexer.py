"""Indexers: deterministic jobs that read a source and bring the rows of one scope up to date.

Each pass is incremental. A source whose content hash is unchanged is not read or embedded again, a
changed one has its old rows replaced, and a source that is gone has its rows removed. Rows of other
scopes, and the agent rows, are never touched. They return a summary {added, changed, removed,
unchanged}.

Notes are always private. A repository is public only when its configuration says so.
"""
import datetime as dt
import hashlib
import json
import os
import re
import shutil
import subprocess

GIT = shutil.which("git") or "git"
GH = shutil.which("gh") or "gh"

from . import core

REPO_EXT = {".md", ".rs", ".toml", ".sh", ".py", ".yml", ".yaml", ".json", ".txt", ".service", ".conf",
            ".dsl", ".tsv", ".j2", ".sql", ".c", ".h", ".cpp", ".qml", ".js", ".ts"}
REPO_NAMES = {"Makefile", "justfile", "Dockerfile"}
MAX_BYTES = 200_000
# Folders of a notes vault that are not notes: editor state, the trash, and model output, which
# becomes knowledge only once provenance is tracked (ADR-0019, "First scope").
NOTE_SKIP = {".obsidian", ".trash", ".git", "Claude outputs"}


def parse_frontmatter(text):
    m = re.match(r"^---\r?\n(.*?)\r?\n---\r?\n?", text, re.S)
    if not m:
        return {}, text
    meta = {}
    for line in m.group(1).splitlines():
        k, sep, v = line.partition(":")
        if sep and k.strip() and not k.startswith((" ", "\t", "-")):
            meta[k.strip().lower()] = v.strip().strip("\"'")
    return meta, text[m.end():]


def chunk_prose(text, max_chars=1200):
    """Paragraph-aligned chunks, each led by the heading it sits under."""
    chunks, cur, heading = [], "", ""
    for para in re.split(r"\n\s*\n", text.strip()):
        if not para.strip():
            continue
        if para.lstrip().startswith("#"):
            heading = para.strip().splitlines()[0]
        if cur and len(cur) + len(para) > max_chars:
            chunks.append(cur)
            cur = heading + "\n" if heading and not para.lstrip().startswith("#") else ""
        cur += (("\n\n" if cur and not cur.endswith("\n") else "") + para)
    if cur.strip():
        chunks.append(cur)
    return chunks


def chunk_lines(text, size=60, overlap=10):
    lines = text.splitlines()
    out, i = [], 0
    while i < len(lines):
        out.append((i + 1, min(i + size, len(lines)), "\n".join(lines[i:i + size])))
        if i + size >= len(lines):
            break
        i += size - overlap
    return out


def _sha(data):
    return hashlib.sha256(data if isinstance(data, bytes) else data.encode()).hexdigest()


def _replace(store, emb, scope, existing, source_id, source_hash, rows_for, summary):
    """Bring one source up to date. rows_for(embedded_texts_fn) -> list of kwargs for make_row."""
    old = existing.get(source_id)
    if old == source_hash:
        summary["unchanged"] += 1
        return
    specs = rows_for()
    if old is not None:
        store.delete_source(source_id)
    if not specs:
        summary["changed"] += old is not None
        return
    vecs = emb([s["text"] for s in specs])
    store.add([core.make_row(emb, scope=scope, source_id=source_id, source_hash=source_hash, chunk=i,
                             vector=v, **s) for i, (s, v) in enumerate(zip(specs, vecs))])
    summary["changed" if old is not None else "added"] += 1


def _prune(store, existing, seen, summary):
    for sid in set(existing) - seen:
        store.delete_source(sid)
        summary["removed"] += 1


def index_notes(store, emb, vault, scope):
    """Markdown notes of a vault, private tier always. Media and the folders in NOTE_SKIP are skipped."""
    summary = dict(added=0, changed=0, removed=0, unchanged=0)
    existing, seen = store.source_hashes(scope), set()
    for root, dirs, files in os.walk(vault):
        dirs[:] = sorted(d for d in dirs if d not in NOTE_SKIP and not d.startswith("."))
        for name in sorted(files):
            if not name.endswith(".md") or name.startswith("."):
                continue
            path = os.path.join(root, name)
            rel = os.path.relpath(path, vault)
            if os.path.getsize(path) > MAX_BYTES:
                continue
            try:
                with open(path, encoding="utf-8") as f:
                    raw = f.read()
            except UnicodeDecodeError:
                continue
            sid = f"{scope}:{rel}"
            seen.add(sid)
            meta, body = parse_frontmatter(raw)
            mtime = dt.datetime.fromtimestamp(os.path.getmtime(path), dt.timezone.utc).isoformat()

            def rows_for(rel=rel, meta=meta, body=body, mtime=mtime, path=path):
                return [dict(kind="note", tier="private", source=f"{scope}:{rel}", location=rel,
                             revision=mtime, doc_status=meta.get("status", ""),
                             doc_date=str(meta.get("date", ""))[:10], source_path=path,
                             text=f"{rel}\n{c}") for c in chunk_prose(body)]

            _replace(store, emb, scope, existing, sid, _sha(raw), rows_for, summary)
    _prune(store, existing, seen, summary)
    store.flush()
    return summary


def _git(path, *args, text=True):
    return subprocess.run([GIT, "-C", path, *args], capture_output=True, text=text, check=True).stdout


def resolve_ref(path, ref=None):
    """The commit to index: <ref>, else origin/main, else main. Never the checked-out branch: the clone
    of a working repository is usually on someone's in-flight branch, and its code is not the project's."""
    for cand in ([ref] if ref else ["origin/main", "main"]):
        r = subprocess.run([GIT, "rev-parse", "--verify", "--quiet", cand + "^{commit}"], cwd=path,
                           capture_output=True, text=True, check=False)
        if r.returncode == 0:
            return cand, r.stdout.strip()
    raise ValueError(f"{path} has no {ref or 'origin/main or main'} to index; name one with <tier>:<path>@<ref>")


def index_repo(store, emb, path, scope, tier, ref=None):
    """The tracked files of a repository as committed at <ref> (default origin/main, else main). The
    working tree and the checked-out branch are not read."""
    if tier not in core.TIERS:
        raise core.TierError(f"bad tier {tier!r}")
    summary = dict(added=0, changed=0, removed=0, unchanged=0)
    ref, head = resolve_ref(path, ref)
    existing, seen = store.source_hashes(scope), set()
    listing = _git(path, "ls-tree", "-r", "-l", "-z", head, text=False).decode("utf-8", "replace")
    for entry in filter(None, listing.split("\0")):
        meta_part, _, rel = entry.partition("\t")
        _, otype, sha, size = meta_part.split(None, 3)
        ext = os.path.splitext(rel)[1]
        if otype != "blob" or int(size) > MAX_BYTES or (ext not in REPO_EXT and os.path.basename(rel) not in REPO_NAMES):
            continue
        sid = f"{scope}:{rel}"
        seen.add(sid)

        def rows_for(rel=rel, sha=sha):
            try:
                raw = _git(path, "cat-file", "blob", sha, text=False).decode("utf-8")
            except UnicodeDecodeError:
                return []
            kind, status, date, body = "code", "", "", raw
            if re.search(r"(^|/)adr/\d{4}-[^/]*\.md$", rel):
                fm, body = parse_frontmatter(raw)
                status, date = fm.get("status", ""), str(fm.get("date", ""))[:10]
                kind = "decision" if status.lower() == "accepted" else "issue"
                chunks = [(None, None, c) for c in chunk_prose(body)]
            elif rel.endswith(".md"):
                chunks = [(None, None, c) for c in chunk_prose(body)]
            else:
                chunks = chunk_lines(body)
            out = []
            for a, b, c in chunks:
                loc = rel if a is None else f"{rel}:{a}-{b}"
                out.append(dict(kind=kind, tier=tier, source=f"{scope}:{rel}", location=loc, revision=head[:12],
                                doc_status=status, doc_date=date, text=f"{loc}\n{c}"))
            return out

        _replace(store, emb, scope, existing, sid, sha, rows_for, summary)
    _prune(store, existing, seen, summary)
    store.flush()
    return summary


def fetch_issues(slug, limit=500):
    out = subprocess.run([GH, "issue", "list", "--repo", slug, "--state", "all", "--limit", str(limit),
                          "--json", "number,title,body,state,updatedAt,comments"],
                         capture_output=True, text=True, check=True).stdout
    return json.loads(out)


def index_issues(store, emb, slug, tier, issues, prune=True):
    """Issues with their comments (briefs included) as claims by their authors, dated and with state."""
    if tier not in core.TIERS:
        raise core.TierError(f"bad tier {tier!r}")
    summary = dict(added=0, changed=0, removed=0, unchanged=0)
    existing, seen = store.source_hashes(slug), set()
    for it in issues:
        sid = f"{slug}#{it['number']}"
        seen.add(sid)
        comments = [c.get("body", "") for c in it.get("comments") or []]
        body = f"#{it['number']} {it['title']}\n\n{it.get('body') or ''}\n\n" + "\n\n".join(comments)

        def rows_for(it=it, body=body):
            return [dict(kind="issue", tier=tier, source=f"{slug}#{it['number']}",
                         location=f"#{it['number']} {it['title']}", revision=it["updatedAt"],
                         doc_status=it["state"].lower(), doc_date=it["updatedAt"][:10], text=c)
                    for c in chunk_prose(body)]

        _replace(store, emb, slug, existing, sid, _sha(json.dumps(it, sort_keys=True)), rows_for, summary)
    if prune:
        _prune(store, existing, seen, summary)
    store.flush()
    return summary
