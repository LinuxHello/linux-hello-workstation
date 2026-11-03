#!/usr/bin/env bash
# One-off: lead review of spike 0005 and ADR-0005 (proposed), as a PR from origin/main.
# Uses a temporary git worktree, so uncommitted work in the main clone is untouched.
set -euo pipefail
: "${CLONE_DIR:=$HOME/projects/LinuxHello/linux-hello}"
: "${BRANCH:=docs/spike-0005-review-adr-0005}"
HERE="$(cd "$(dirname "$0")" && pwd)"
PENDING="$HERE/provider"
log() { printf '\033[1m==> %s\033[0m\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

command -v gh >/dev/null || die "gh not installed"
gh auth status >/dev/null 2>&1 || die "gh not authenticated"
[[ -d "$PENDING" ]] || die "nothing pending in $PENDING"
[[ "$(git -C "$CLONE_DIR" config --get commit.gpgsign || true)" == "true" ]] || die "commit signing is not enabled in $CLONE_DIR"

git -C "$CLONE_DIR" fetch -q origin main
WT=$(mktemp -d "${TMPDIR:-/tmp}/lh-provider.XXXXXX")
trap 'git -C "$CLONE_DIR" worktree remove --force "$WT" >/dev/null 2>&1 || true' EXIT
if git -C "$CLONE_DIR" show-ref -q --verify "refs/heads/$BRANCH"; then
  git -C "$CLONE_DIR" worktree add -q "$WT" "$BRANCH"
else
  git -C "$CLONE_DIR" worktree add -q -b "$BRANCH" "$WT" origin/main
fi
cd "$WT"

for src in "$PENDING"/*; do
  [[ -f "$src" ]] || continue
  name=$(basename "$src"); dest="${name//__//}"
  mkdir -p "$(dirname "$dest")"; cp "$src" "$dest"
done

git add -A docs
if git diff --cached --quiet; then
  log "nothing new to commit"
elif [[ "$(git log --oneline origin/main..HEAD | wc -l)" -gt 0 ]]; then
  # Follow-up on an existing PR branch; message from provider.msg next to this script.
  [[ -f "$HERE/provider.msg" ]] || die "follow-up commit needs $HERE/provider.msg"
  git commit -q -s -F "$HERE/provider.msg"
  NOTE_ACCEPTED=1
else
  git commit -q -s -F - <<'MSG'
Review spike 0005; propose ADR-0005 for the provider path

Lead review of the credentialsd spike against a fresh clone of v0.3.1
and credentialsd#26. Answer confirmed (no provider API, no KDE portal
backend). Corrected: the UI has a commented-out PasskeyProvider
placeholder; #26 holds a concrete draft API by the credentialsd
maintainer; the credentialsd crate is LGPL-3.0-only.

ADR-0005 (proposed): contribute the provider API upstream from the
#26 draft (option A); keep in-tree TPM (C) open; no virtual CTAP
authenticator (B) as product path.

Target architecture: C1, C5, licence line, provider containers and
prior art no longer assume a provider API exists. Spike and ADR
indexes updated.

Closes #5

Assisted-by: Claude Code (claude-opus-5-5)
Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01HDRiNrHMgwggETKeGt6Fed
MSG
fi
git push -q -u origin "$BRANCH"
pr_url=$(gh pr list --repo LinuxHello/linux-hello --head "$BRANCH" --state open --json url --jq '.[0].url // empty')
if [[ -n "$pr_url" ]]; then
  log "PR exists: $pr_url"
else
  gh pr create --base main --head "$BRANCH" \
    --title "Review spike 0005; propose ADR-0005 for the provider path" \
    --label type:docs --label upstream --label container:workspace \
    --body-file - <<'BODY'
## Intent
Record the lead review of spike 0005 and put the provider-path decision in front of the maintainer as ADR-0005 (proposed). Closes #5.

## Affected containers
Docs only: `docs/spikes/`, `docs/adr/`, `docs/architecture/target-architecture.md`.

## Tests
No code. Re-checked the spike's claims against credentialsd v0.3.1 (commit `861e04c`, fresh clone) and credentialsd#26: **tested by reading source**, nothing built. Frontmatter parses; relative links resolve.

## Security
None directly. ADR-0005 keeps KeePassXC across a process boundary (C3) in every option and rejects a privileged virtual-HID authenticator as the product path.

## Decision needed
ADR-0005: accept option A (contribute the provider API upstream from the #26 draft), or choose another. Merging this PR does **not** accept it; status stays Proposed.

## Rollback
Revert the squash commit.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_01HDRiNrHMgwggETKeGt6Fed
BODY
fi

if [[ "${NOTE_ACCEPTED:-0}" == 1 ]]; then
  pr=$(gh pr list --repo LinuxHello/linux-hello --head "$BRANCH" --state open --json number --jq '.[0].number')
  gh pr edit "$pr" --repo LinuxHello/linux-hello --title "Review spike 0005; accept ADR-0005 (contribute the provider API upstream)" >/dev/null
  if ! gh pr view "$pr" --repo LinuxHello/linux-hello --json comments --jq '.comments[].body' | grep -q 'ADR-0005 accepted'; then
    gh pr comment "$pr" --repo LinuxHello/linux-hello --body "ADR-0005 accepted by the maintainer on 2026-11-01: option A. The 'Decision needed' section above is resolved; merging records the accepted ADR. Upstream offer posted on credentialsd#26: https://github.com/linux-credentials/credentialsd/issues/26#issuecomment-6559782108" >/dev/null
  fi
  # Issue 32 (upstream offer): posted, now waiting for upstream.
  gh issue edit 32 --repo LinuxHello/linux-hello --add-label status:in-review --remove-label status:needs-brief >/dev/null 2>&1 || true
  if ! gh issue view 32 --repo LinuxHello/linux-hello --json comments --jq '.comments[].body' | grep -q 'issuecomment-6559782108'; then
    gh issue comment 32 --repo LinuxHello/linux-hello --body "Offer posted on 2026-11-01: https://github.com/linux-credentials/credentialsd/issues/26#issuecomment-6559782108. Waiting for upstream; the answer goes into ADR-0005." >/dev/null
  fi
  log "PR #$pr and issue #32 updated"
fi
