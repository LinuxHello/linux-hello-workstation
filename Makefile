# Linux Hello: GitHub organisation and monorepo bootstrap. UNTESTED against the GitHub API.
# Override defaults on the command line, e.g. make all ARCH_SRC=/tmp/arch
export ORG ?= LinuxHello
export REPO ?= linux-hello
export OWNER ?= atterdag
export CLONE_DIR ?= $(HOME)/projects/$(ORG)/$(REPO)
export ARCH_SRC ?= /srv/sync/GoogleDrive/Obsidian Vaults/Sovereign AI Workstation/Architecture

.PHONY: all preflight org repo seed protect verify
all: preflight org repo seed protect verify

preflight: ; @bash scripts/preflight.sh
org: preflight ; @bash scripts/org.sh
repo: preflight ; @bash scripts/repo.sh
seed: repo ; @bash scripts/seed.sh
protect: seed ; @bash scripts/protect.sh
verify: ; @bash scripts/verify.sh
