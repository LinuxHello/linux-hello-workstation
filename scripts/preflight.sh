#!/usr/bin/env bash
# Read-only checks. Fails closed before anything is changed.
set -euo pipefail
source "$(dirname "$0")/../common.sh"

command -v gh >/dev/null  || die "gh not installed (sudo apt install gh)"
command -v git >/dev/null || die "git not installed"
gh auth status >/dev/null 2>&1 || die "gh not authenticated: run 'gh auth login' (token stays in your keyring)"

login=$(gh api user --jq .login)
[[ "$login" == "$OWNER" ]] || die "gh is logged in as '$login', expected '$OWNER'"

role=$(gh api "orgs/$ORG/memberships/$OWNER" --jq .role 2>/dev/null) || die "cannot read membership of $OWNER in $ORG"
[[ "$role" == "admin" ]] || die "$OWNER is '$role' in $ORG, needs admin"

scopes=$(gh auth status 2>&1 | grep -i 'token scopes' || true)
for s in admin:org repo workflow; do
  grep -q "'$s'" <<<"$scopes" || die "gh token lacks scope '$s': run 'gh auth refresh -s admin:org,repo,workflow'"
done

tfa=$(gh api "orgs/$ORG" --jq .two_factor_requirement_enabled)
[[ "$tfa" == "true" ]] || die "2FA is not required for $ORG. GitHub only allows this in the web UI: https://github.com/organizations/$ORG/settings/security → 'Require two-factor authentication'. Then re-run."

git config user.signingkey >/dev/null || log "WARN: no git signing key configured; the seed commit will be unsigned (allowed, it lands before the ruleset)"

for f in "Linux Hello - Target Architecture.md" "Linux Hello - workspace.dsl"; do
  [[ -f "$ARCH_SRC/$f" ]] || die "missing '$ARCH_SRC/$f' (bisync not run? set ARCH_SRC=<dir> or fetch with rclone copy)"
done

log "preflight OK: $OWNER is admin of $ORG, 2FA required, sources present"
