#!/usr/bin/env bash
# adr-tools (the `adr` command) set up for the architecture repository, whose ADRs are not in the
# layout adr-tools assumes: they live in adr/, start with front matter, are headed "ADR-NNNN: title",
# are numbered with four digits and start as "Proposed" (adr-tools writes "Accepted").
#
#   scripts/adr.sh setup          point adr at <architecture clone>/adr (writes .adr-dir, untracked)
#   scripts/adr.sh new <title>    create the next numbered ADR from <clone>/templates/adr.md, status Proposed
#
# Environment: ARCH_REPO_DIR (the architecture clone, default ~/projects/LinuxHello/architecture).
# Nothing is committed or pushed. adr/README.md, the index of the ADRs, is edited by hand.
set -euo pipefail
: "${ARCH_REPO_DIR:=$HOME/projects/LinuxHello/architecture}"
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[[ -d "$ARCH_REPO_DIR/adr" && -f "$ARCH_REPO_DIR/templates/adr.md" ]] \
  || die "$ARCH_REPO_DIR is not the architecture clone (no adr/ or templates/adr.md); set ARCH_REPO_DIR"

setup() {
  # adr finds its directory through .adr-dir, searched from the current directory upwards.
  if [[ "$(cat "$ARCH_REPO_DIR/.adr-dir" 2>/dev/null || true)" != adr ]]; then
    echo adr > "$ARCH_REPO_DIR/.adr-dir"
    echo "adr-tools: wrote $ARCH_REPO_DIR/.adr-dir"
  fi
  # A per-clone ignore, so the file is not a change to the repository.
  local exclude="$ARCH_REPO_DIR/.git/info/exclude"
  if [[ -d "$ARCH_REPO_DIR/.git/info" ]] && ! grep -qx '/.adr-dir' "$exclude" 2>/dev/null; then
    echo '/.adr-dir' >> "$exclude"
  fi
  echo "adr-tools: configured for $ARCH_REPO_DIR/adr; create one with: make adr TITLE='...'"
}

new() {
  local title=${1:-}
  [[ -n "$title" ]] || die "usage: $0 new <title>"
  command -v adr >/dev/null || die "adr is not installed: make adr-tools"
  setup >/dev/null

  # adr-tools fills the words NUMBER, TITLE and DATE (first one on a line) and always writes
  # STATUS as Accepted. Turn the repository's own template into that form so it cannot drift;
  # the heading's four-digit number is filled in below, because NUMBER is not zero-padded.
  local tmpl file id
  tmpl=$(mktemp); trap "rm -f '$tmpl'" EXIT
  sed -e 's/{{date}}/DATE/g' -e 's/{{title}}/TITLE/g' "$ARCH_REPO_DIR/templates/adr.md" > "$tmpl"

  file=$(cd "$ARCH_REPO_DIR" && ADR_TEMPLATE="$tmpl" VISUAL=true adr new "$title" | tail -n 1)
  [[ "$file" == /* ]] || file=$ARCH_REPO_DIR/$file   # adr prints the path relative to its directory
  [[ -f "$file" ]] || die "adr new did not create a file"
  id=$(basename "$file" | grep -Eo '^[0-9]+')
  sed -i "s/ADR-NNNN/ADR-$id/" "$file"
  echo "$file"
  echo "next: write the ADR, add it to $ARCH_REPO_DIR/adr/README.md, and set 'subject:' in its front matter"
}

case "${1:-}" in
  setup) setup ;;
  new) shift; new "$*" ;;
  *) die "usage: $0 setup | new <title>" ;;
esac
