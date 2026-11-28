#!/usr/bin/env bash
# Turns a test VM into one with a desktop, for the login and lock screens: Plasma on Wayland from
# Ubuntu's archive, without SDDM, and greetd with cage (a compositor that shows one program full
# screen) for Linux Hello's greeter. Also the Qt Quick runtime and PySide6, for spike greeters
# written in QML with a Python part. It changes only the VM; run it once after scripts/vm.sh up.
#
#   export LH_VM_RELEASE=26.04 LH_VM_NAME=linux-hello-vm-2604-desktop LH_VM_SSH_PORT=2224 \
#          LH_VM_MEM=8192 LH_VM_DISK=40G
#   scripts/vm.sh up && scripts/vm-desktop.sh && scripts/vm.sh screenshot screen.png
#
# The packages come from the Ubuntu archive inside the VM (about 1.5 GB). greetd is installed but
# left disabled: a spike configures its greeter and starts it.
set -euo pipefail
source "$(dirname "$0")/../common.sh"
vm="$(dirname "$0")/vm.sh"
bash "$vm" status | grep -q '^running' || die "the VM is not running: scripts/vm.sh up"

log "installing Plasma (Wayland), greetd, cage and the Qt Quick runtime in the VM"
bash "$vm" ssh 'bash -s' <<'REMOTE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
cloud-init status --wait >/dev/null 2>&1 || true
sudo apt-get update -q >/dev/null
# "sddm-" keeps SDDM out: the display manager here is greetd.
sudo apt-get install -y -q plasma-desktop plasma-workspace kwin-wayland plasma-session-wayland \
  konsole greetd cage qt6-wayland python3-pyside6.qtquick python3-pyside6.qtqml \
  qml6-module-qtquick qml6-module-qtquick-controls qml6-module-qtquick-layouts \
  qml6-module-qtquick-window fprintd sddm- >/dev/null
sudo systemctl disable --now greetd >/dev/null 2>&1 || true
sudo systemctl set-default graphical.target >/dev/null
echo "plasma $(dpkg-query -W -f='${Version}' plasma-workspace), greetd $(dpkg-query -W -f='${Version}' greetd), cage $(dpkg-query -W -f='${Version}' cage), pyside6 $(dpkg-query -W -f='${Version}' python3-pyside6.qtquick)"
ls /usr/share/wayland-sessions /usr/share/xsessions 2>/dev/null
df -h / | tail -1
REMOTE
log "done: the VM has a desktop (greetd is installed and disabled)"
