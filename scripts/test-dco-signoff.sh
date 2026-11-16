#!/usr/bin/env bash
# shellcheck disable=SC2015  # ok() always succeeds, so "test && ok || nok" never runs both
# Tests for dco-signoff.sh with a fake gh, a local bare "origin" and an ephemeral SSH signing key.
# Never calls GitHub and never touches your clones or your git config.
#   bash scripts/test-dco-signoff.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/home"
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "ok   $1"; }
nok() { fail=$((fail + 1)); echo "FAIL $1"; local d="${2:-}"; echo "     ${d//$'\n'/$'\n'     }"; }

# make exports these, pointing at the real clones; the test must only ever see its own.
unset ORG REPO OWNER CLONE_DIR REPO_SLUG ARCH_SRC TEMPLATE_DIR
export HOME="$work/home" GIT_CONFIG_GLOBAL="$work/gitconfig" GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=Dev GIT_AUTHOR_EMAIL=dev@example.com GIT_COMMITTER_NAME=Dev GIT_COMMITTER_EMAIL=dev@example.com
ssh-keygen -q -t ed25519 -N "" -f "$work/key" >/dev/null
printf 'dev@example.com %s\n' "$(cut -d' ' -f1,2 "$work/key.pub")" >"$work/allowed"
git config --global init.defaultBranch main
git config --global gpg.format ssh
git config --global user.signingkey "$work/key.pub"
git config --global gpg.ssh.allowedSignersFile "$work/allowed"
git config --global user.name Maintainer
git config --global user.email dev@example.com

# A fake gh: records its calls; the PR's branch is "feature", based on "main", from the same repository.
cat >"$work/bin/gh" <<EOF2
#!/usr/bin/env bash
echo "gh \$*" >>"$work/calls"
case "\$*" in
  "auth status") ;;
  "pr view "*) echo "feature main false" ;;
  *) echo "unexpected gh \$*" >&2; exit 1 ;;
esac
EOF2
chmod +x "$work/bin/gh"

# make_repo <name> <origin-url-name>: a bare origin, a clone whose origin URL names owner/repo,
# main with one signed-off commit, and "feature" with one commit that has no sign-off.
make_repo() {
  local name=$1 url=$2
  git init -q --bare "$work/$name.git"
  git clone -q "$work/$name.git" "$work/clone-$name" 2>/dev/null
  (
    cd "$work/clone-$name"
    git config commit.gpgsign true
    git commit -q --allow-empty -s -m base
    git push -q origin main
    git switch -q -c feature
    git commit -q --allow-empty -m "unsigned work"
    git push -q origin feature
    git switch -q main
    # Present the remote under its GitHub name, as a real clone has; fetch still goes to the bare repo.
    git remote set-url origin "$url"
    git config "url.$work/$name.git.insteadOf" "$url"
  )
}
make_repo arch "git@github.com:LinuxHello/linux-hello-architecture.git"
make_repo lh "https://github.com/LinuxHello/linux-hello.git"

run() { # stdin answer, then the script's arguments; the environment is the caller's
  local answer=$1; shift
  status=0; : >"$work/calls"
  out="$(printf '%s\n' "$answer" | PATH="$work/bin:$PATH" bash "$here/dco-signoff.sh" "$@" 2>&1)" || status=$?
}
head_msg() { git -C "$1" log -1 --format=%B "origin/feature"; }

# 1. Another repository, named by its short name, with the default clone location.
mkdir -p "$work/home/projects/LinuxHello"
ln -s "$work/clone-arch" "$work/home/projects/LinuxHello/linux-hello-architecture"
ln -s "$work/clone-lh" "$work/home/projects/LinuxHello/linux-hello"
run yes 7 linux-hello-architecture
if [[ $status == 0 ]] && grep -q 'gh pr view 7 --repo LinuxHello/linux-hello-architecture' "$work/calls" \
   && git -C "$work/arch.git" log -1 --format=%B feature | grep -q '^Signed-off-by: Dev <dev@example.com>$' \
   && [[ "$(git -C "$work/arch.git" cat-file -p feature | grep -c '^gpgsig')" == 1 ]]
then ok "signs off a PR in another repository, queried by that repository's name and re-signed"; else nok "signs off a PR in another repository" "status $status: $out"; fi

# 2. The same through owner/repo, and a repo whose commits are already signed off is left alone.
run yes 7 LinuxHello/linux-hello-architecture
if [[ $status == 0 ]] && grep -q 'every commit on PR #7 is signed off' <<<"$out" && grep -q -- '--repo LinuxHello/linux-hello-architecture' "$work/calls"
then ok "accepts owner/repo, and exits quietly when everything is signed off"; else nok "owner/repo form" "status $status: $out"; fi

# 3. The default repository is unchanged: linux-hello, its own clone, no prompt answer needed to decline.
run no 3
if [[ $status != 0 ]] && grep -q 'gh pr view 3 --repo LinuxHello/linux-hello' "$work/calls" && grep -q 'not certified; nothing changed' <<<"$out" \
   && ! git -C "$work/lh.git" log -1 --format=%B feature | grep -q '^Signed-off-by:'
then ok "default repository is still linux-hello; declining changes nothing"; else nok "default repository" "status $status: $out"; fi

# 4. A clone of another repository is refused, whatever CLONE_DIR says.
CLONE_DIR="$work/clone-lh" run yes 7 linux-hello-architecture
if [[ $status != 0 ]] && grep -q 'is a clone of LinuxHello/linux-hello, not of LinuxHello/linux-hello-architecture' <<<"$out" \
   && ! grep -q 'pr view' "$work/calls"
then ok "refuses a clone of a different repository before asking GitHub anything"; else nok "wrong clone refused" "status $status: $out"; fi

# 5. A directory that is not a clone is refused.
mkdir -p "$work/empty"
CLONE_DIR="$work/empty" run yes 7 linux-hello-architecture
if [[ $status != 0 ]] && grep -q 'is not a clone with an origin remote' <<<"$out"; then ok "refuses a directory that is not a clone"; else nok "non-clone refused" "status $status: $out"; fi

# 6. Bad usage.
run yes abc
if [[ $status != 0 ]] && grep -q 'usage:' <<<"$out"; then ok "a non-numeric PR is a usage error"; else nok "usage error" "status $status: $out"; fi

echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
