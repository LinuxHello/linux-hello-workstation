#!/usr/bin/env python3
"""Reads the evaluator's answer on stdin and prints its verdict as normalised JSON.

The evaluator is asked for one JSON object, but a model wraps it in prose, so the object is taken
from the first "{" to the last "}". Anything that is not a verdict ("ok" or "problems") exits with
status 3, and then nothing is published. Used by lh-evaluate-brief.sh; tested by test-lh-draft-next.sh.
"""
import json
import sys


def text(value):
    return value if isinstance(value, str) else ""


def main():
    raw = sys.stdin.read()
    start, end = raw.find("{"), raw.rfind("}")
    if start < 0 or end <= start:
        sys.exit(3)
    try:
        verdict = json.loads(raw[start:end + 1])
    except ValueError:
        sys.exit(3)
    if not isinstance(verdict, dict) or verdict.get("verdict") not in ("ok", "problems"):
        sys.exit(3)
    out = {
        "verdict": verdict["verdict"],
        "summary": text(verdict.get("summary")),
        "checked": [c for c in verdict.get("checked") or [] if isinstance(c, str)],
        "new_files": bool(verdict.get("new_files")),
        "problems": [],
    }
    for p in verdict.get("problems") or []:
        if not isinstance(p, dict):
            continue
        out["problems"].append({
            "id": text(p.get("id")),
            "what": text(p.get("what")),
            "why": text(p.get("why")),
            "fix": text(p.get("fix")),
            "who": "maintainer" if p.get("who") == "maintainer" else "ai",
            "question": text(p.get("question")),
            "options": [o for o in p.get("options") or [] if isinstance(o, str)],
            "recommendation": text(p.get("recommendation")),
            # A problem blocks unless the evaluator says it does not.
            "blocking": p.get("blocking", True) is not False,
        })
    print(json.dumps(out))


if __name__ == "__main__":
    main()
