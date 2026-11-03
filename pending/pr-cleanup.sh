#!/usr/bin/env bash
# One-off: unsafe-policy fix and repository clean-up as one PR from main.
set -euo pipefail
: "${CLONE_DIR:=$HOME/projects/LinuxHello/linux-hello}"
: "${BRANCH:=chore/unsafe-policy-and-cleanup}"
PENDING="$(cd "$(dirname "$0")" && pwd)/cleanup"
log() { printf '\033[1m==> %s\033[0m\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

command -v gh >/dev/null || die "gh not installed"
gh auth status >/dev/null 2>&1 || die "gh not authenticated"
# rustup installs cargo into ~/.cargo/bin, which a non-login shell may not have on PATH.
[[ -d "$HOME/.cargo/bin" ]] && PATH="$HOME/.cargo/bin:$PATH"
command -v cargo >/dev/null || die "cargo not found; see README, Build > Prerequisites"
cd "$CLONE_DIR"
[[ "$(git config --get commit.gpgsign || true)" == "true" ]] || die "commit signing is not enabled in $CLONE_DIR"

files=(Cargo.toml AGENTS.md CONTRIBUTING.md docs/security/README.md .sonarlint/connectedMode.json
       crates/linuxhello-agent/src/main.rs crates/linuxhello-ctl/src/main.rs crates/linuxhello-dbus/src/lib.rs
       crates/linuxhello-kpxc-bridge/src/main.rs crates/linuxhello-tpm-provider/src/main.rs crates/pam-linuxhello/src/lib.rs
       scripts/ci/unsafe-policy.sh scripts/ci/unsafe-allowlist.txt .github/workflows/ci.yml
       docs/adr/0004-agent-roles.md .github/copilot-instructions.md)
# Not Linux Hello's: a Python-only SonarQube automatic-analysis config (automatic analysis is off;
# CI uses sonar-project.properties) and Postman script instructions added by an editor extension.
remove=(.sonarcloud.properties .github/instructions)

current=$(git branch --show-current)
if [[ "$current" != "$BRANCH" ]]; then
  git fetch -q origin main
  git switch -q main && git merge -q --ff-only origin/main
  git switch -C "$BRANCH"   # -C: a branch left by an earlier failed run is reset to main
fi

if [[ -d "$PENDING" ]]; then
  for src in "$PENDING"/*; do
    [[ -f "$src" ]] || continue
    name=$(basename "$src"); dest=".${name//__//}"
    mkdir -p "$(dirname "$dest")"; cp "$src" "$dest"
  done
fi
chmod +x scripts/ci/unsafe-policy.sh

for r in "${remove[@]}"; do
  if git ls-files --error-unmatch "$r" >/dev/null 2>&1; then git rm -r -q "$r"; fi
done

log "gates (rustc $(rustc --version | cut -d' ' -f2))"
gate() { log "gate: $*"; "$@" || die "gate failed: $*  (nothing committed; fix and re-run this script)"; }
gate cargo fmt --all --check
gate cargo clippy --workspace --all-targets -- -D warnings
gate cargo test --workspace
gate bash scripts/ci/unsafe-policy.sh

extra=$(git status --porcelain --untracked-files=all | awk '{print $NF}' | grep -vxF -f <(printf '%s\n' "${files[@]}") | grep -v -e '^\.sonarcloud\.properties$' -e '^\.github/instructions/' || true)
[[ -z "$extra" ]] || die "unexpected changes, not committing: $extra"

git add -- "${files[@]}"
if git diff --cached --quiet; then
  log "nothing new to commit"
else
  git update-index --chmod=+x scripts/ci/unsafe-policy.sh
  git commit -q -s -F - <<'MSG'
Confine unsafe code; define Copilot suggestions and DCO; remove stray configs

The workspace lint was forbid(unsafe_code), which no module can
relax, so the TPM FFI and PAM entry-point modules allowed by
invariant 4 could never compile. The workspace now denies unsafe
code, every crate root outside the TPM provider and the PAM module
forbids it, and a module may allow it only when listed in
scripts/ci/unsafe-allowlist.txt (empty today).

New CI job unsafe-policy enforces the property; tested against
five broken trees (missing forbid, unlisted allow, allow-list entry
outside the two crates, combined allow attribute).

Copilot (ADR-0004 amended): it may commit accepted suggestions.
"Commit suggestion" commits are web commits and carry the required
sign-off; coding-agent commits are certified by the maintainer with
dco-signoff.sh before merge. The dco job's error names both paths.

Also: SonarLint connected-mode binding for the repository; remove
the Python-only .sonarcloud.properties (automatic analysis is off)
and the Postman instruction files an editor extension committed.

Assisted-by: Claude Code (claude-opus-5-5)
Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01HDRiNrHMgwggETKeGt6Fed
MSG
fi
git log -1 --show-signature --format='%h %s' | tail -3

git push -u origin "$BRANCH"
if gh pr view "$BRANCH" >/dev/null 2>&1; then
  log "PR exists: $(gh pr view "$BRANCH" --json url --jq .url)"
else
  gh pr create --base main --head "$BRANCH" \
    --title "Confine unsafe code; define Copilot suggestions and DCO; remove stray configs" \
    --label type:security --label container:workspace \
    --body-file - <<'BODY'
## Intent
Make invariant 4 implementable and enforced: unsafe code only in allow-listed modules of the TPM provider and the PAM module. Remove two configs that do not belong to this project.

## Affected containers
All crate roots (one attribute each), workspace `Cargo.toml`, CI, `AGENTS.md`, `CONTRIBUTING.md`, `docs/security/README.md`.

## Tests
- New CI job `unsafe-policy` (`scripts/ci/unsafe-policy.sh`). Verified locally against the clean tree (passes) and five broken trees (all fail): missing `#![forbid(unsafe_code)]`; unlisted `#[allow(unsafe_code)]`; allow-list entry outside the two crates; `#[allow(dead_code, unsafe_code)]`; and `cargo build` rejects `allow(unsafe_code)` under `forbid` (E0453).
- fmt, clippy `-D warnings`, test: pass on rustc 1.97.0.

## Security
Moves the workspace lint from `forbid` to `deny`; every non-exempt crate root now forbids unsafe itself, and the two exempt crates deny it. Net effect today: no unsafe anywhere (the allow-list is empty).

## How to verify
`unsafe-policy` job green. Add `#[allow(unsafe_code)]` to any file on a branch: the job fails.

## Copilot and the DCO
ADR-0004 amended: Copilot may commit when the maintainer accepts a suggestion or asks it to fix something. AGENTS.md gains "Copilot suggestions and the DCO"; the `dco` job's error message points to `git commit -s` or to the maintainer's `dco-signoff.sh`. Assumption to confirm on the next PR: "Commit suggestion" commits carry the web sign-off the organisation requires.

## Rollback
Revert the squash commit.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_01HDRiNrHMgwggETKeGt6Fed
BODY
fi
