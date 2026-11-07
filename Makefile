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
        claude-gpu claude-cpu tpm-dev-deps implement implement-next implementer-env reset test \
        all preflight org repo seed protect security sonar verify

help:
	@echo "Daily: backlog and merges (maintainer)"
	@echo "  make next                 the next issue in each lane, and the command that starts it"
	@echo "  make backlog              every open issue, by lane, in pick-up order"
	@echo "  make backlog-check        open issues missing a status: or priority: label"
	@echo "  make triage [APPLY=1]     apply issues/triage.tsv: labels and blocked-by links (dry run without APPLY=1)"
	@echo "  make board                mirror the issues onto the Roadmap project board"
	@echo "  make signoff PR=<n> [REPO=<repo>]   certify a reviewed PR's commits with your DCO sign-off (default: $(REPO))"
	@echo
	@echo "Implementer on this workstation (attended)"
	@echo "  make claude-gpu           Claude Code on the GPU Ollama (gemma4 64k), never the billed account"
	@echo "  make claude-cpu           the same on the CPU-only Ollama (gemma4 128k, slow)"
	@echo "  make implement ISSUE=<n> [HARNESS=aider|claude]   implement one issue from its brief"
	@echo "  make implement-next       one tick of the unattended loop, by hand"
	@echo "  make implementer-env      create ~/.config/linux-hello/implementer.env (never overwrites; make all does this too)"
	@echo "  make reset                clean the clone (rescues uncommitted work first)"
	@echo
	@echo "Spike prerequisites (Ubuntu)"
	@echo "  make tpm-dev-deps         install what the TPM spikes need: tss2 dev libraries, clang, swtpm, tpm2-tools (asks for sudo)"
	@echo
	@echo "Checks"
	@echo "  make test                 the tooling's own tests and shellcheck"
	@echo
	@echo "Once: organisation and repository setup (done; idempotent if re-run)"
	@echo "  make preflight | org | repo | seed | protect | labels | security | sonar | verify | all"
	@echo "  (all also runs implementer-env)"

# --- Daily ----------------------------------------------------------------------------------
$(BACKLOG):
	@echo "$(BACKLOG) missing: clone $(REPO_SLUG) to $(CLONE_DIR) and pull main" >&2; exit 1
next: $(BACKLOG) ; @bash scripts/next.sh $(BACKLOG)
backlog: $(BACKLOG) ; @bash $(BACKLOG) list
backlog-check: $(BACKLOG) ; @bash $(BACKLOG) check
triage: ; @bash scripts/triage.sh
board: $(BACKLOG) ; @bash scripts/board.sh
signoff:
	@test -n "$(PR)" || { echo "usage: make signoff PR=<number>"; exit 1; }
	@bash scripts/dco-signoff.sh $(PR)

# --- Implementer ----------------------------------------------------------------------------
claude-gpu: ; @bash local/claude-local-gpu.sh
claude-cpu: ; @bash local/claude-local-cpu.sh
implement:
	@test -n "$(ISSUE)" || { echo "usage: make implement ISSUE=<number> [HARNESS=aider|claude]"; exit 1; }
	@LH_HARNESS=$${HARNESS:-$${LH_HARNESS:-aider}} bash local/lh-implement.sh $(ISSUE)
implement-next: ; @bash local/lh-implement-next.sh
implementer-env: ; @bash scripts/implementer-env.sh
reset: ; @bash local/lh-reset.sh

# --- Spike prerequisites ---------------------------------------------------------------------
# tss-esapi (spike 0011, the TPM provider) links the TSS2 libraries and generates its bindings with
# clang; swtpm is a software TPM, so a spike cannot lock or clear the hardware TPM.
TPM_DEV_PKGS := libtss2-dev clang libclang-dev pkg-config swtpm swtpm-tools tpm2-tools
tpm-dev-deps:
	@missing=; for p in $(TPM_DEV_PKGS); do dpkg -s $$p >/dev/null 2>&1 || missing="$$missing $$p"; done; \
	 if [ -z "$$missing" ]; then echo "tpm-dev-deps: everything is installed"; \
	 else echo "installing:$$missing"; sudo apt-get install -y $$missing; fi

# --- Checks ---------------------------------------------------------------------------------
test:
	bash local/test-lh-implement-next.sh
	bash local/test-lh-branch.sh
	bash local/test-lh-brief.sh
	bash local/test-lh-prompts.sh
	bash local/test-lh-guard.sh
	bash local/test-lh-nothink-relay.sh
	bash scripts/test-triage.sh
	bash scripts/test-implementer-env.sh
	bash scripts/test-dco-signoff.sh
	@if command -v shellcheck >/dev/null; then shellcheck -x -P SCRIPTDIR scripts/*.sh local/*.sh && echo "shellcheck clean"; \
	 else echo "shellcheck not installed: sudo apt install shellcheck"; fi

# --- Once -----------------------------------------------------------------------------------
all: preflight org repo seed protect verify implementer-env
preflight: ; @bash scripts/preflight.sh
org: preflight ; @bash scripts/org.sh
repo: preflight ; @bash scripts/repo.sh
seed: repo ; @bash scripts/seed.sh
protect: seed ; @bash scripts/protect.sh
labels: ; @bash scripts/labels.sh
security: ; @bash scripts/security.sh
sonar: ; @bash scripts/sonar.sh
verify: ; @bash scripts/verify.sh
