# Reads a brief; sourced, not run. Tested by local/test-lh-brief.sh.
#
#   lh_brief_test_names <brief>    the test names of its **Tests first** section, or of a heading that
#                                  ends in "tests first" ("### 3. Properties and tests first"), one per line
#   lh_tests_in_diff <found|missing> <names>   the names that do (or do not) appear in the added lines of
#                                  git diff origin/main, space separated
#
# A test name is a backticked name at the head of a bullet: "- `name`: ...",
# "- `a`, `b`", "- `a` and `b`", or after a file prefix, "- In `file.rs`: `name`". Backticked
# names later in a bullet are keys and values the test uses, not tests: counting them made the
# gates demand tests named face_requires_ir and require_hardware_tpm (#61, Aider, 2026-11-05).

lh_brief_test_names() {
  python3 - "$1" <<'PY'
import re, sys
text = sys.argv[1]
# The section is "**Tests first**" or a heading ending in "tests first"; it runs to the next heading
# or bold key.
# A "**Tests first**" marker ends at the next bold key; a heading ends only at the next heading, so
# bold paragraphs inside a headed section (for example a note on how to build a value) do not cut it short.
m = re.search(r"\*\*Tests first\*\*(.*?)(?=^#{1,6}[ \t]|\n\*\*[A-Z]|\Z)", text, re.S | re.M) \
    or re.search(r"^#{2,}[^\n]*tests first[^\n]*$(.*?)(?=^#{1,6}[ \t]|\Z)", text, re.S | re.M | re.I)
section = m.group(1) if m else ""
head = re.compile(
    r"^\s*[-*]\s+(?:In `[^`]+`:\s*)?"                      # bullet, optional "In `file`:"
    r"((?:`[a-z][a-z0-9_]+`(?:\s*,\s*|\s+and\s+)?)+)",     # names joined by "," or "and"
    re.M)
names = []
for h in head.findall(section):
    names += [n for n in re.findall(r"`([a-z][a-z0-9_]+)`", h) if n.count("_") >= 2]
# Test functions written out in a code block of the section.
names += [n for n in re.findall(r"\bfn\s+([a-z][a-z0-9_]+)\s*\(", section) if n.count("_") >= 2]
print("\n".join(dict.fromkeys(names)))
PY
}

# A test exists in a diff when its name is a Rust fn, a shell function, or a quoted case name
# (a `check "name" ...` line), or when an existing `#[ignore]`d placeholder with that name is enabled.
lh_tests_in_diff() {
  python3 - "$1" "$2" <<'PY'
import re, subprocess, sys
want, names = sys.argv[1], sys.argv[2].split()
subprocess.run(["git", "add", "-N", "."], check=False)
diff = subprocess.run(["git", "diff", "origin/main"], capture_output=True, text=True).stdout
lines = diff.split("\n")
def enabled_placeholder(n):
    """A placeholder test that exists already and is enabled by the diff: its fn line is context and an
    #[ignore] line just above it is removed."""
    e = re.compile(r"^\s+fn " + re.escape(n) + r"\s*\(")
    for i, l in enumerate(lines):
        if e.match(l) and any(x.startswith("-") and "#[ignore" in x for x in lines[max(0, i - 4):i]):
            return True
    return False
def present(n):
    e = re.escape(n)
    if re.search(r"^\+\s*fn " + e + r"\s*\(|^\+\s*" + e + r"\s*\(\)|^\+.*[\"']" + e + r"[\"']", diff, re.M):
        return True
    return enabled_placeholder(n)
print(" ".join(n for n in names if present(n) == (want == "found")))
PY
}
