#!/usr/bin/env python3
"""Mechanical consistency checks on an implementation brief; no model involved.

    lh-brief-checks.py <clone>        brief on stdin

Prints one line per finding, nothing for a clean brief. The checks look for contradictions between the
sections of a brief that a model glosses over, and cannot talk themselves into passing:

  * the count a brief states ("Exactly two files") against the files its Files section lists;
  * a source file (.rs, .toml, .py, .sh) named in the Goal, tests or constraints that the Files
    section does not list (the implementer is told to touch nothing else);
  * a backticked name or an issue number that is out of scope and also in Files or the tests;
  * a test name listed twice, or a new test whose name already exists in the repository.

Tested by local/test-lh-draft.sh.
"""
import os
import re
import shutil
import subprocess
import sys

GIT = shutil.which("git") or "git"  # one resolved path, not a search of PATH at each call

NUMBERS = {"one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6}
SOURCE = re.compile(r"`([A-Za-z0-9_./-]+\.(?:rs|toml|py|sh))(?::\d+(?:-\d+)?)?`")
TICK = re.compile(r"`([^`\n]{3,})`")
ISSUE = re.compile(r"(?<![\w/])#(\d{1,5})\b")
TEST_NAME = re.compile(r"[a-z][a-z0-9_]{1,80}")
EXISTING = re.compile(r"existing|already|placeholder|unchanged|replace|remove|verify|keep|still", re.I)


def is_heading(line):
    """'##', '###' or '####' followed by a space or a tab (no regular expression to backtrack)."""
    n = len(line) - len(line.lstrip("#"))
    return 2 <= n <= 4 and len(line) > n and line[n] in " \t"


def sections(text):
    """Split at headings: a list of (kind, heading, body)."""
    parts = [""]
    for line in text.split("\n"):
        if is_heading(line):
            parts += [line, ""]
        else:
            parts[-1] += line + "\n"
    out = []
    for i in range(1, len(parts), 2):
        head, body = parts[i], parts[i + 1]
        h = head.lower()
        kind = ("files" if re.search(r"\bfiles?\b", h) else
                "oos" if "out of scope" in h else
                "tests" if "tests first" in h else
                "acceptance" if "acceptance" in h else
                "constraints" if "constraint" in h else
                "goal" if "goal" in h else
                "other")
        out.append((kind, head.strip("# \t"), body))
    return out


def tests_of(body):
    names = []
    for line in body.splitlines():
        m = re.match(r"\s*[-*]\s+(?:In `[^`]+`:\s*)?`([a-z][a-z0-9_]+)`", line)
        if m:
            names.append((m.group(1), line))
    return names


def main():
    clone = os.path.abspath(sys.argv[1])  # absolute, so git cannot read it as an option
    if not os.path.isdir(clone):
        sys.exit(f"lh-brief-checks: {clone} is not a directory")
    text = sys.stdin.read()
    secs = sections(text)
    by = {}
    for kind, head, body in secs:
        by.setdefault(kind, []).append(body)
    joined = {k: "\n".join(v) for k, v in by.items()}
    findings = []

    files = set(SOURCE.findall(joined.get("files", "")))
    stated = re.search(r"\b(?:exactly|only)\s+(one|two|three|four|five|six|\d+)\s+(?:source\s+)?files?\b",
                       joined.get("files", ""), re.I)
    if stated:
        n = stated.group(1).lower()
        n = NUMBERS.get(n) or int(n)
        listed = {f for f in re.findall(r"^\s*[-*]\s+`([^`]+\.[A-Za-z]+)`", joined.get("files", ""), re.M)}
        if listed and len(listed) != n:
            findings.append(f"FILES: the Files section says {stated.group(0)!r} but lists {len(listed)}: {', '.join(sorted(listed))}")

    if files:
        for kind in ("goal", "tests", "constraints", "other"):
            for f in sorted(set(SOURCE.findall(joined.get(kind, "")))):
                if f not in files and not any(g.endswith("/" + f) or f.endswith("/" + g) for g in files):
                    findings.append(f"FILES: `{f}` is named under '{kind}' but is not in the Files section, which is all the implementer may touch; add it there or take it out")

    oos = joined.get("oos", "")
    if oos:
        scope_text = joined.get("files", "") + "\n" + joined.get("tests", "")
        for name in sorted(set(TICK.findall(oos))):
            if len(name) >= 5 and name in scope_text:
                findings.append(f"SCOPE: `{name}` is listed out of scope and also appears in Files or the tests")
        for n in sorted(set(ISSUE.findall(oos))):
            if re.search(rf"(?<![\w/])#{n}\b", joined.get("files", "") + joined.get("tests", "")):
                findings.append(f"SCOPE: #{n} is listed out of scope and also appears in Files or the tests")

    seen = {}
    for name, line in tests_of(joined.get("tests", "")):
        if name in seen:
            findings.append(f"TESTS: `{name}` is listed twice")
        seen[name] = line
    for name, line in seen.items():
        if EXISTING.search(line.split("`", 2)[2] if line.count("`") >= 2 else line):
            continue
        if not TEST_NAME.fullmatch(name):  # only a plain identifier reaches the command line
            continue
        r = subprocess.run([GIT, "-C", clone, "grep", "-qwF", "--", f"fn {name}"],
                           capture_output=True)
        if r.returncode == 0:
            findings.append(f"TESTS: `{name}` already exists in the repository; if the brief means to change it, say 'existing' beside it, otherwise give the new test another name")

    print("\n".join(findings))


if __name__ == "__main__":
    main()
