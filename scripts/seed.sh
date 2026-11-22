#!/usr/bin/env bash
# First commit: template + sanitised architecture docs.
# Builds in a staging dir and only moves it into place once the privacy guard passes,
# so a failed run leaves nothing behind. Resumes a push if a previous run got that far.
set -euo pipefail
source "$(dirname "$0")/../common.sh"

if gh api "repos/$ORG/$REPO/branches/main" >/dev/null 2>&1; then
  log "main already exists on $ORG/$REPO, skipping seed"; exit 0
fi

if [[ -e "$CLONE_DIR" ]]; then
  if git -C "$CLONE_DIR" rev-parse --verify -q HEAD >/dev/null \
     && [[ "$(git -C "$CLONE_DIR" remote get-url origin 2>/dev/null)" == "git@github.com:$ORG/$REPO.git" ]]; then
    log "$CLONE_DIR has the seed commit but main is not on GitHub; pushing"
    git -C "$CLONE_DIR" push -u origin main; exit 0
  fi
  die "$CLONE_DIR exists and is not a seeded clone; move it away first"
fi

[[ -n "$ARCH_SRC" ]] || die "set ARCH_SRC (in local.mk) to the folder of the private architecture notes"
note="$ARCH_SRC/Linux Hello - Target Architecture.md"
dsl="$ARCH_SRC/Linux Hello - workspace.dsl"
[[ -f "$note" && -f "$dsl" ]] || die "architecture sources missing in $ARCH_SRC"

mkdir -p "$(dirname "$CLONE_DIR")"
stage=$(mktemp -d "$CLONE_DIR.seed.XXXXXX")
trap 'rm -rf "$stage"' EXIT
log "staging in $stage"
cp -a "$TEMPLATE_DIR/." "$stage/"
mkdir -p "$stage/docs/architecture"

# One rule set for both files: the note embeds the same DSL. The rules and the words that must
# not survive name the private notes' machine, so they live outside this public repository.
rules=${LH_SEED_RULES:-${XDG_CONFIG_HOME:-$HOME/.config}/linux-hello/seed-sanitise.sed}
words=${LH_SEED_WORDS:-${XDG_CONFIG_HOME:-$HOME/.config}/linux-hello/seed-private-words}
[[ -f "$rules" && -f "$words" ]] || die "the private sanitising rules are missing ($rules, $words)"
sanitise() {
  sed -E -f "$rules"
}
awk 'NR==1 && /^---$/ {fm=1; next} fm && /^---$/ {fm=0; next} !fm' "$note" | sanitise > "$stage/docs/architecture/target-architecture.md"
sanitise < "$dsl" > "$stage/docs/architecture/workspace.dsl"

# Fail closed if anything private survived.
if grep -n -i -E -f "$words" "$stage"/docs/architecture/*; then
  die "private workstation references left in docs/architecture (listed above); nothing was written to $CLONE_DIR"
fi

git -C "$stage" init -q -b main
git -C "$stage" add -A
git -C "$stage" commit -q -s -m "Initial skeleton: architecture, governance, Cargo workspace" \
  -m "LGPL-3.0-or-later (ADR-0002); monorepo with split guardrails (ADR-0001)."
git -C "$stage" remote add origin "git@github.com:$ORG/$REPO.git"

mv "$stage" "$CLONE_DIR"
trap - EXIT
log "seed commit ready in $CLONE_DIR; pushing"
git -C "$CLONE_DIR" push -u origin main
