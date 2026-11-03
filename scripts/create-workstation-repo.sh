#!/usr/bin/env bash
# One-off: turn this bootstrap folder into the private repository LinuxHello/linux-hello-workstation,
# so the lead (Claude, through the Claude GitHub App) can maintain the workstation tooling.
#
#   ~/projects/LinuxHello/linux-hello-bootstrap/scripts/create-workstation-repo.sh
#
# Idempotent: skips steps that are already done. Refuses to push if it finds anything that
# looks like a secret. Uses your own gh login; nothing is sent anywhere else.
set -euo pipefail
source "$(dirname "$0")/../common.sh"
WS_REPO="${WS_REPO:-linux-hello-workstation}"
cd "$BOOTSTRAP_DIR"

command -v gh >/dev/null || die "gh not installed"
command -v git >/dev/null || die "git not installed"
gh auth status >/dev/null 2>&1 || die "gh not authenticated (gh auth login)"

# 1. Keep local state and junk out of the repository.
[[ -f .gitignore ]] || cat > .gitignore <<'IGN'
# Local state, never committed
.vscode/
*.log
*.tmp
.aider*
target/
IGN

# 2. Refuse to continue if anything looks like a credential.
pattern='(ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|gho_[A-Za-z0-9]{20,}|ghs_[A-Za-z0-9]{20,}|sk-ant-[A-Za-z0-9_-]{20,}|sk-[A-Za-z0-9]{32,}|AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY-----|xox[abp]-[A-Za-z0-9-]{10,})'
if hits=$(grep -rIEln --exclude-dir=.git --exclude="$(basename "$0")" "$pattern" . 2>/dev/null); then
  printf '%s\n' "$hits" >&2
  die "possible secrets in the files above; remove them before creating the repository"
fi
log "secret scan: clean"

# 3. Local repository with one signed-off commit.
if [[ ! -d .git ]]; then
  git init -q -b main
  git add -A
  git commit -q -s -m "Import the workstation tooling for Linux Hello

Bootstrap scripts for the LinuxHello organisation and the local agent
loop (lh-agent.sh, lh-implement.sh, lh-reset.sh, claude-local.sh), as
they stood before this repository existed. Private: it names local
models and paths, which the public repository must not (invariant 8)."
  log "local repository created"
else
  log "local repository already exists"
fi

# 4. Private repository on GitHub, then push.
if gh repo view "$ORG/$WS_REPO" >/dev/null 2>&1; then
  log "$ORG/$WS_REPO already exists"
  git remote get-url origin >/dev/null 2>&1 || git remote add origin "https://github.com/$ORG/$WS_REPO.git"
  git push -q -u origin main
else
  gh repo create "$ORG/$WS_REPO" --private \
    --description "Private workstation tooling for Linux Hello: bootstrap and the local agent loop" \
    --source . --remote origin --push
  log "created private $ORG/$WS_REPO and pushed main"
fi

# 5. Same merge settings as the public repository.
gh api -X PATCH "repos/$ORG/$WS_REPO" -F allow_squash_merge=true -F allow_merge_commit=false \
  -F allow_rebase_merge=false -F delete_branch_on_merge=true -F has_wiki=false \
  -f squash_merge_commit_title=PR_TITLE -f squash_merge_commit_message=PR_BODY >/dev/null
[[ "$(gh repo view "$ORG/$WS_REPO" --json visibility --jq .visibility)" == "PRIVATE" ]] || die "repository is not private"
log "settings applied; visibility PRIVATE confirmed"

cat <<MSG

Done. One step left, in the browser:
  Give the Claude GitHub App access to $ORG/$WS_REPO, unless it already has "All repositories":
  https://github.com/organizations/$ORG/settings/installations  ->  Claude  ->  Configure
MSG
