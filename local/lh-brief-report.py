#!/usr/bin/env python3
"""Renders the outcome of `make draft-next-brief` as a short report for a reader who is not a specialist.

    lh-brief-report.py <report file>      the outcome as JSON on stdin

The JSON has: issue, title, outcome ("published", "dry_run" or "not_published"), reasons (why a guard
stopped it), verdict (the evaluator's normalised verdict, or null), details (the mechanical checks'
raw findings). The report goes to stdout and to <report file>. Decisions the maintainer must take
come first, each with its options and a recommendation; what the lead fixes without asking comes
next; the technical details go last. Tested by test-lh-draft-next.sh.
"""
import json
import sys


def main():
    path = sys.argv[1]
    data = json.load(sys.stdin)
    verdict = data.get("verdict") or {}
    problems = verdict.get("problems") or []
    outcome = data["outcome"]
    lines = [f"Issue #{data['issue']}: {data['title']}"]
    lines.append({
        "published": "RESULT: PUBLISHED. The brief is on the issue and the issue is set to ready.",
        "dry_run": "RESULT: DRY RUN. The brief passed every check and would have been published; nothing was posted.",
        "not_published": "RESULT: NOT PUBLISHED. Nothing was posted and no label was changed.",
    }[outcome])

    if verdict.get("summary"):
        lines += ["", "What the brief is for", f"  {verdict['summary']}"]

    decisions = [p for p in problems if p["who"] == "maintainer"]
    if decisions:
        lines += ["", f"Needs your decision ({len(decisions)})"]
        for i, p in enumerate(decisions, 1):
            lines.append(f"  {i}. {p['question'] or p['what']}")
            for option in p["options"]:
                lines.append(f"       {option}")
            if p["recommendation"]:
                lines.append(f"     My recommendation: {p['recommendation']}")
            if p["why"]:
                lines.append(f"     Why it matters: {p['why']}")

    blocking = [p for p in problems if p["who"] == "ai" and p["blocking"]]
    if blocking:
        lines += ["", f"Mine to fix (no action from you) ({len(blocking)})"]
        for p in blocking:
            lines.append(f"  - {p['what']}" + (f" Why it matters: {p['why']}" if p["why"] else ""))
        lines.append("  Tell the lead \"fix the brief for #%s\" and it will correct it and check it again." % data["issue"])

    minor = [p for p in problems if p["who"] == "ai" and not p["blocking"]]
    if minor:
        lines += ["", "Minor notes (they did not stop publishing)"]
        lines += [f"  - {p['what']}" for p in minor]

    if data.get("reasons"):
        lines += ["", "Why nothing was published"]
        lines += [f"  - {r}" for r in data["reasons"]]

    if verdict.get("checked"):
        lines += ["", "Checked and found fine"]
        lines += [f"  - {c}" for c in verdict["checked"]]

    if verdict.get("new_files"):
        lines += ["", "Note: this brief creates new files. The local implementer has failed on every brief that"
                  " creates new files so far, so plan for the code to be written by hand."]

    if data.get("details", "").strip():
        lines += ["", "Technical details (only if you want them)"]
        lines += [f"  {line}" for line in data["details"].strip().splitlines()]

    report = "\n".join(lines) + "\n"
    with open(path, "w", encoding="utf-8") as f:
        f.write(report)
    sys.stdout.write(report)


if __name__ == "__main__":
    main()
