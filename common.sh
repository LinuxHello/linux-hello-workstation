# Shared defaults; every script sources this and may be run on its own.
: "${ORG:=LinuxHello}"
: "${REPO:=linux-hello}"
: "${OWNER:=atterdag}"
: "${CLONE_DIR:=$HOME/projects/$ORG/$REPO}"
: "${ARCH_SRC:=/srv/sync/GoogleDrive/Obsidian Vaults/Sovereign AI Workstation/Architecture}"
BOOTSTRAP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${TEMPLATE_DIR:=$BOOTSTRAP_DIR/repo}"
log() { printf '\033[1m==> %s\033[0m\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
