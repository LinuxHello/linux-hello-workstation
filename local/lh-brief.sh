# shellcheck shell=bash
# Reads a brief; sourced, not run. Tested by local/test-lh-brief.sh.
#
#   lh_brief_test_names <brief>    the test names of its **Tests first** section, or of a heading that
#                                  ends in "tests first" ("### 3. Properties and tests first"), one per line
#   lh_deleted_tests               the test fns the diff removes or renames (none is allowed)\n#   lh_tests_in_diff <found|missing> <names>   the names that do (or do not) appear in the added lines of
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
# The section is a bold key ending in "tests first" ("**Tests first**", "**Properties and tests first.**") or a
# heading ending in "tests first"; it runs to the next heading
# or bold key.
# A "**Tests first**" marker ends at the next bold key; a heading ends only at the next heading, so
# bold paragraphs inside a headed section (for example a note on how to build a value) do not cut it short.
m = re.search(r"\*\*(?:[^*\n]*\b)?[Tt]ests first[.:]?\*\*(.*?)(?=^#{1,6}[ \t]|\n\*\*[A-Z]|\Z)", text, re.S | re.M) \
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

# A test that the diff removes or renames: a `fn` line marked by #[test] (or by an #[ignore] above it)
# that is deleted and not added back under the same name. Prints the names, space separated.
lh_deleted_tests() {
  python3 - <<'PY'
import re, subprocess
subprocess.run(["git", "add", "-N", "."], check=False)
diff = subprocess.run(["git", "diff", "origin/main"], capture_output=True, text=True).stdout.split("\n")
fn = re.compile(r"^([-+ ])\s*(?:pub\s+)?fn ([A-Za-z0-9_]+)\s*\(")
marker = re.compile(r"^[-+ ]\s*#\[(?:test|ignore|tokio::test)")
removed, added = set(), set()
for i, line in enumerate(diff):
    m = fn.match(line)
    if not m:
        continue
    if m.group(1) == "+":         # any added fn name counts as put back, whatever sits above it in the diff
        added.add(m.group(2))
        continue
    attrs, j = [], i - 1          # the attribute lines directly above the fn
    while j >= 0 and re.match(r"^[-+ ]\s*#\[", diff[j]):
        attrs.append(diff[j])
        j -= 1
    if not any(marker.match(x) for x in attrs):
        continue
    if m.group(1) == "-":
        removed.add(m.group(2))
print(" ".join(sorted(removed - added)))
PY
}

# lh_brief_already_implemented <brief>   succeeds when the brief names tests and every one of them already
# exists on origin/main as a test that is not an ignored placeholder: the work it describes has merged, and
# running the implementer on it can only find nothing to change. A brief that enables a placeholder, adds a
# new test, or names none is not "implemented". LH_ALLOW_EXISTING_TESTS=1 turns the check off (for a brief
# that changes existing tests rather than adding any). Run it in the clone.
lh_brief_already_implemented() {
  [[ "${LH_ALLOW_EXISTING_TESTS:-0}" != 1 ]] || return 1
  local names
  names=$(lh_brief_test_names "$1")
  [[ -n "$names" ]] || return 1
  python3 - "$names" <<'PY'
import re, subprocess, sys
names = sys.argv[1].split()
# One search with fixed arguments: each fn line of main with the three lines above it.
out = subprocess.run(["git", "grep", "-h", "-B3", "-E", r"^\s*(pub +)?(async +)?fn[ \t]+[A-Za-z_][A-Za-z0-9_]*[ \t]*\(",
                      "origin/main", "--", "*.rs"], capture_output=True, text=True, check=False).stdout
fns, window = {}, []
for line in out.split("\n"):
    if line == "--":
        window = []
        continue
    m = re.match(r"^\s*(?:pub\s+)?(?:async\s+)?fn\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(", line)
    if m:
        fns[m.group(1)] = any("#[ignore" in w for w in window[-3:])
    window.append(line)
sys.exit(0 if all(n in fns and not fns[n] for n in names) else 1)
PY
}

# lh_brief_files <brief>   the files the brief lets the implementer edit, one per line. The list sits under
# "**Files:**", under a bold key that goes on after "Files" ("**Files (at most three, all listed):**"), or
# under a "### N. Files" heading, and runs to the next heading or bold key. A file is a list item ("-", "*" or
# "1.") that starts with its backticked path; prose such as "never edit `x.yml`" is not a file. A section
# with no such items falls back to every quoted path in it. Directories (a submodule pointer) are not
# editable files. Run it in the clone (the directory test is relative).
lh_brief_files() {
  python3 - "$1" <<'PY'
import os, re, sys
text = sys.argv[1]
m = re.search(r"(?:\*\*Files\b[^*\n]*\*\*|^#{2,}[ \t]*(?:\d+\.[ \t]*)?Files[ \t]*$)(.*?)(?=^#{1,6}[ \t]|\n\*\*[A-Z]|\Z)", text, re.S | re.M)
seen = []
section = m.group(1) if m else ""
ext = r"`([A-Za-z0-9_./-]+\.(?:rs|toml|md|txt|yml|yaml|json|sh|service|socket|conf|py))`"
found = [mm.group(1) for line in section.splitlines() if (mm := re.match(r"\s*(?:[-*]|\d+\.)\s+" + ext, line))]
if not found:
    found = re.findall(ext, section)
for p in found:
    if ("/" in p or p.endswith(".toml")) and not os.path.isdir(p) and p not in seen: seen.append(p)
if seen: print("\n".join(seen))
PY
}

