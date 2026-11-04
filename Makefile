# Linux Hello workstation tooling. `make` (or `make help`) lists every task; RUNBOOK.md says when
# to use which. Override defaults on the command line, e.g. make next CLONE_DIR=/tmp/linux-hello
# Per-checkout overrides (git-ignored), e.g. CLONE_DIR := ../linux-hello
-include local.mk
export ORG ?= LinuxHello
export REPO ?= linux-hello
export OWNER ?= atterdag
export CLONE_DIR ?= $(HOME)/projects/$(ORG)/$(REPO)
export ARCH_SRC ?= /srv/sync/GoogleDrive/Obsidian Vaults/Sovereign AI Workstation/Architecture
export REPO_SLUG ?= $(ORG)/$(REPO)
BACKLOG := $(CLONE_DIR)/scripts/backlog/backlog.sh

.DEFAULT_GOAL := help
.PHONY: help next backlog backlog-check triage board labels signoff \
        claude implement implement-next reset test \
        all preflight org repo seed protect security sonar verify

help:
	@echo "Daily: backlog and merges (maintainer)"
	@echo "  make next                 the next issue in each lane"
	@echo "  make backlog              every open issue, by lane, in pick-up order"
	@echo "  make backlog-check        open issues missing a status: or priority: label"
	@echo "  make triage [APPLY=1]     apply issues/triage.tsv: labels and blocked-by links (dry run without APPLY=1)"
	@echo "  make board                mirror the issues onto the Roadmap project board"
	@echo "  make signoff PR=<n>       certify a reviewed PR's commits with your DCO sign-off"
	@echo
	@echo "Implementer on this workstation (attended)"
	@echo "  make claude               Claude Code on the local model, never the billed account"
	@echo "  make implement ISSUE=<n> [HARNESS=aider|claude]   implement one issue from its brief"
	@echo "  make implement-next       one tick of the unattended loop, by hand"
	@echo "  make reset                clean the clone (rescues uncommitted work first)"
	@echo
	@echo "Checks"
	@echo "  make test                 the tooling's own tests and shellcheck"
	@echo
	@echo "Once: organisation and repository setup (done; idempotent if re-run)"
	@echo "  make preflight | org | repo | seed | protect | labels | security | sonar | verify | all"

# --- Daily ----------------------------------------------------------------------------------
$(BACKLOG):
	@echo "$(BACKLOG) missing: clone $(REPO_SLUG) to $(CLONE_DIR) and pull main" >&2; exit 1
next: $(BACKLOG) ; @bash $(BACKLOG) next
backlog: $(BACKLOG) ; @bash $(BACKLOG) list
backlog-check: $(BACKLOG) ; @bash $(BACKLOG) check
triage: ; @bash scripts/triage.sh
board: $(BACKLOG) ; @bash scripts/board.sh
signoff:
	@test -n "$(PR)" || { echo "usage: make signoff PR=<number>"; exit 1; }
	@bash scripts/dco-signoff.sh $(PR)

# --- Implementer ----------------------------------------------------------------------------
claude: ; @bash local/claude-local.sh
implement:
	@test -n "$(ISSUE)" || { echo "usage: make implement ISSUE=<number> [HARNESS=aider|claude]"; exit 1; }
	@LH_HARNESS=$${HARNESS:-$${LH_HARNESS:-aider}} bash local/lh-implement.sh $(ISSUE)
implement-next: ; @bash local/lh-implement-next.sh
reset: ; @bash local/lh-reset.sh

# --- Checks ---------------------------------------------------------------------------------
test:
	bash local/test-lh-implement-next.sh
	bash local/test-lh-branch.sh
	bash scripts/test-triage.sh
	@if command -v shellcheck >/dev/null; then shellcheck -x -P SCRIPTDIR scripts/*.sh local/*.sh && echo "shellcheck clean"; \
	 else echo "shellcheck not installed: sudo apt install shellcheck"; fi

# --- Once -----------------------------------------------------------------------------------
all: preflight org repo seed protect verify
preflight: ; @bash scripts/preflight.sh
org: preflight ; @bash scripts/org.sh
repo: preflight ; @bash scripts/repo.sh
seed: repo ; @bash scripts/seed.sh
protect: seed ; @bash scripts/protect.sh
labels: ; @bash scripts/labels.sh
security: ; @bash scripts/security.sh
sonar: ; @bash scripts/sonar.sh
verify: ; @bash scripts/verify.sh
