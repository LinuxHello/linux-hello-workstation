# Reads a brief; sourced, not run. Tested by local/test-lh-brief.sh.
#
#   lh_brief_test_names <brief>    the test names of its **Tests first** section, one per line
#
# A test name is a backticked name at the head of a bullet: "- `name`: ...",
# "- `a`, `b`", "- `a` and `b`", or after a file prefix, "- In `file.rs`: `name`". Backticked
# names later in a bullet are keys and values the test uses, not tests: counting them made the
# gates demand tests named face_requires_ir and require_hardware_tpm (#61, Aider, 2026-11-05).

lh_brief_test_names() {
  python3 - "$1" <<'PY'
import re, sys
m = re.search(r"\*\*Tests first\*\*(.*?)(?:\n\*\*[A-Z]|\Z)", sys.argv[1], re.S)
head = re.compile(
    r"^\s*[-*]\s+(?:In `[^`]+`:\s*)?"                      # bullet, optional "In `file`:"
    r"((?:`[a-z][a-z0-9_]+`(?:\s*,\s*|\s+and\s+)?)+)",     # names joined by "," or "and"
    re.M)
names = []
for h in head.findall(m.group(1) if m else ""):
    names += [n for n in re.findall(r"`([a-z][a-z0-9_]+)`", h) if n.count("_") >= 2]
print("\n".join(dict.fromkeys(names)))
PY
}
