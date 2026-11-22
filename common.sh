# Shared defaults; every script sources this and may be run on its own.
: "${ORG:=LinuxHello}"
: "${REPO:=linux-hello}"
: "${OWNER:=atterdag}"
: "${CLONE_DIR:=$HOME/projects/$ORG/$REPO}"
# A clone kept under the short name (architecture, branding) from before the repositories were
# renamed to linux-hello-<name> is still found.
if [[ ! -d "$CLONE_DIR" && -d "$HOME/projects/$ORG/${REPO#linux-hello-}" ]]; then
  CLONE_DIR="$HOME/projects/$ORG/${REPO#linux-hello-}"
fi
: "${ARCH_SRC:=}"
BOOTSTRAP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${TEMPLATE_DIR:=$BOOTSTRAP_DIR/repo}"
log() { printf '\033[1m==> %s\033[0m\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
