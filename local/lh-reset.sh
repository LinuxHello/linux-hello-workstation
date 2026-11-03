#!/usr/bin/env bash
# Return the clone to a clean tree so lh-agent.sh / lh-implement.sh can run. Workstation-only.
#
#   lh-reset.sh [-n] [-y] [--main]
#     -n, --dry-run   show what would be saved and removed, change nothing
#     -y, --yes       do not ask for confirmation
#     --main          afterwards switch to main, prune stale remote branches, fast-forward main
#
# Nothing is lost: before cleaning, every change is saved outside the repo in
#   ${XDG_STATE_HOME:-~/.local/state}/linux-hello-agent/rescue/<time>-<branch>/
# as changes.patch (tracked changes, incl. intent-to-add files), files.tar.gz (current copy of every
# changed or untracked file) and status.txt. RESTORE.txt in that folder says how to get them back.
# Ignored and excluded files (target/, .aider*, .vscode/, ...) are left alone.
set -euo pipefail
: "${CLONE_DIR:=$HOME/projects/LinuxHello/linux-hello}"
RESCUE_ROOT="${XDG_STATE_HOME:-$HOME/.local/state}/linux-hello-agent/rescue"
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '\033[1m==> %s\033[0m\n' "$*"; }
trap 'printf "ERROR: %s failed at line %s; tree not cleaned unless it says so above\n" "$0" "$LINENO" >&2' ERR

dry=0; yes=0; to_main=0
for a in "$@"; do
  case "$a" in
    -n|--dry-run) dry=1 ;;
    -y|--yes) yes=1 ;;
    --main) to_main=1 ;;
    -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option '$a' (see $0 --help)" ;;
  esac
done

command -v git >/dev/null || die "git not installed"
cd "$CLONE_DIR" 2>/dev/null || die "no clone at $CLONE_DIR"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "$CLONE_DIR is not a git work tree"
[[ ! -e "$(git rev-parse --git-path MERGE_HEAD)" ]] || die "a merge is in progress; resolve or 'git merge --abort' first"
[[ ! -d "$(git rev-parse --git-path rebase-merge)" && ! -d "$(git rev-parse --git-path rebase-apply)" ]] \
  || die "a rebase is in progress; finish or 'git rebase --abort' first"

branch=$(git symbolic-ref -q --short HEAD || echo detached)
status=$(git status --porcelain --untracked-files=all)

if [[ -n "$status" ]]; then
  log "uncommitted changes on '$branch':"
  printf '%s\n' "$status"
  (( dry )) && { log "dry run: would save these to $RESCUE_ROOT/ and remove them from the tree"; }
  if (( !dry )); then
    if (( !yes )); then
      [[ -t 0 ]] || die "not a terminal; pass -y to confirm"
      read -r -p "Save these outside the repo and remove them from the tree? [y/N] " ans
      [[ "$ans" =~ ^[Yy]$ ]] || die "aborted, nothing changed"
    fi

    # 1. Save. Abort before touching the tree if any step fails.
    mkdir -p "$RESCUE_ROOT"
    dir=$(mktemp -d "$RESCUE_ROOT/$(date +%Y%m%d-%H%M%S)-${branch//\//_}-XXXX")
    printf '%s\n' "$status" > "$dir/status.txt"
    git rev-parse HEAD > "$dir/HEAD.txt"
    git diff HEAD --binary > "$dir/changes.patch"
    # Every path that exists in the work tree and is changed or untracked (renames: the new path).
    git status --porcelain -z --untracked-files=all \
      | python3 -c '
import sys
e = sys.stdin.buffer.read().split(b"\0"); i = 0; out = []
while i < len(e):
    r = e[i]; i += 1
    if not r: continue
    xy, p = r[:2], r[3:]
    if b"R" in xy or b"C" in xy: i += 1          # skip the rename source
    out.append(p)
sys.stdout.buffer.write(b"".join(x + b"\0" for x in out))' \
      | while IFS= read -r -d '' p; do if [[ -e "$p" || -L "$p" ]]; then printf '%s\0' "$p"; fi; done \
      > "$dir/paths.bin"
    tar -czf "$dir/files.tar.gz" --null -T "$dir/paths.bin"
    # Verify every saved path is in the archive before anything is removed.
    want=$(tr '\0' '\n' < "$dir/paths.bin" | sort); have=$(tar -tzf "$dir/files.tar.gz" | sort)
    [[ "$want" == "$have" ]] || die "rescue archive incomplete; nothing removed (see $dir)"
    rm -f "$dir/paths.bin"
    cat > "$dir/RESTORE.txt" <<EOF
Saved by lh-reset.sh from branch '$branch' at commit $(cat "$dir/HEAD.txt").

Restore everything (from the clone, on a clean tree):
  git switch $branch            # if needed
  git apply --index $dir/changes.patch
  tar -xzf $dir/files.tar.gz    # also brings back untracked files

Restore one file:
  tar -xzf $dir/files.tar.gz path/to/file
EOF
    log "saved to $dir"

    # 2. Clean: tracked files back to HEAD (drops staged and intent-to-add entries), untracked removed.
    git reset -q --hard HEAD
    git clean -fdq
  fi
else
  log "tree already clean on '$branch'"
fi

# 3. Optionally back to an up-to-date main.
if (( to_main )); then
  if (( dry )); then
    log "dry run: would switch to main, fetch --prune origin, fast-forward main"
  else
    git switch -q main
    git fetch -q --prune origin
    git merge -q --ff-only origin/main || die "main has diverged from origin/main; not touching it"
    log "on main at $(git rev-parse --short HEAD)"
  fi
fi

(( dry )) && exit 0
[[ -z "$(git status --porcelain --untracked-files=all)" ]] || die "tree still not clean; check 'git status'"
log "clean: $(git symbolic-ref -q --short HEAD || echo detached) @ $(git rev-parse --short HEAD)"
