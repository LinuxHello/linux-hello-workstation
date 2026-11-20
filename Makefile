# Linux Hello workstation tooling. `make` (or `make help`) lists every task; RUNBOOK.md says when
# to use which. Override defaults on the command line, e.g. make next CLONE_DIR=/tmp/linux-hello
# Per-checkout overrides (git-ignored), e.g. CLONE_DIR := ../linux-hello
-include local.mk
export ORG ?= LinuxHello
export REPO ?= linux-hello
export OWNER ?= atterdag
# A clone kept under the short name (architecture, branding) from before the renaming is still found.
export CLONE_DIR ?= $(firstword $(wildcard $(HOME)/projects/$(ORG)/$(REPO) $(HOME)/projects/$(ORG)/$(patsubst linux-hello-%,%,$(REPO))) $(HOME)/projects/$(ORG)/$(REPO))
export ARCH_SRC ?= /srv/sync/GoogleDrive/Obsidian Vaults/Sovereign AI Workstation/Architecture
export REPO_SLUG ?= $(ORG)/$(REPO)
# The architecture repository (diagrams, the pinned Structurizr image and its scripts).
export ARCH_REPO_DIR ?= $(HOME)/projects/$(ORG)/architecture
BACKLOG := $(CLONE_DIR)/scripts/backlog/backlog.sh

.DEFAULT_GOAL := help
.PHONY: help next backlog backlog-check triage board map labels signoff \
        claude-gpu claude-cpu tpm-dev-deps adr-tools adr vm-deps vm-image vm-up vm-ssh vm-sync vm-down vm-reset vm-status \
        vm-test-agent vm-test-agent-all vm-test-provider vm-test-pam vm-test-rpbind vm-test-uhid vm-test-uhid-session vm-test-prompt-launch vm-test-prompt-identity vm-test-uvup image-check image-mirror implement implement-next draft-brief draft-next-brief draft-adr memory-venv memory-index memory-query memory-stats memory-expire models models-unload implementer-env reset test \
        all preflight org repo seed protect security sonar verify

help:
	@echo "Daily: backlog and merges (maintainer)"
	@echo "  make next                 the next issue in each lane, and the command that starts it"
	@echo "  make backlog              every open issue, by lane, in pick-up order"
	@echo "  make backlog-check        open issues missing a status: or priority: label"
	@echo "  make triage [APPLY=1]     apply issues/triage.tsv: labels and blocked-by links (dry run without APPLY=1)"
	@echo "  make board                mirror the issues onto the Roadmap project board"
	@echo "  make map                  write docs/dependency-map.md: which open issues wait for which (Mermaid)"
	@echo "  make signoff PR=<n> [REPO=<repo>]   certify a reviewed PR's commits with your DCO sign-off (default: $(REPO))"
	@echo
	@echo "Implementer on this workstation (attended)"
	@echo "  make claude-gpu           Claude Code on the GPU Ollama (gemma4 64k), never the billed account"
	@echo "  make claude-cpu           the same on the CPU-only Ollama (gemma4 128k, slow)"
	@echo "  make implement ISSUE=<n> [HARNESS=aider|claude]   implement one issue from its brief"
	@echo "  make implement-next       one tick of the unattended loop, by hand"
	@echo "  make draft-brief ISSUE=n  a local model drafts the brief into a file (never posts)"
	@echo "  make draft-next-brief [ISSUE=n] [DRY=1]   draft the next brief, have Claude check it, publish it only if it is clean"
	@echo "  make draft-adr TITLE=.. DECISION=..  a local model drafts an ADR into a file"
	@echo "  make models               models loaded now;  make models-unload frees the GPU"
	@echo
	@echo "Shared memory of the agents (ADR-0019; settings in ~/.config/linux-hello/memory.env, see local/memory.env.example)"
	@echo "  make memory-venv          create the virtualenv with lancedb (downloads packages)"
	@echo "  make memory-index         update the memory from the configured repositories, issues and notes"
	@echo "  make memory-query Q='..' [TIER=private]   what the memory holds on Q; the tier is public unless you say so"
	@echo "  make memory-stats | memory-expire         rows per kind; drop unverified agent rows older than 30 days"
	@echo "  make implementer-env      create ~/.config/linux-hello/implementer.env (never overwrites; make all does this too)"
	@echo "  make reset                clean the clone (rescues uncommitted work first)"
	@echo
	@echo "Spike prerequisites (Ubuntu)"
	@echo "  make tpm-dev-deps         install what the TPM spikes need: tss2 dev libraries, clang, swtpm, tpm2-tools (asks for sudo)"
	@echo
	@echo "Architecture decision records"
	@echo "  make adr-tools            install adr-tools (asks for sudo) and point it at the architecture repository's adr/"
	@echo "  make adr TITLE='...'      create the next numbered ADR there from templates/adr.md, status Proposed (nothing committed)"
	@echo
	@echo "Test VM (Ubuntu, KVM, emulated TPM; for the virtual CTAP spike and any test that must not touch this machine)"
	@echo "  Every vm-* target takes VM_RELEASE=24.04 (default) or 26.04: each release has its own image, disk and ssh port"
	@echo "  make vm-deps | vm-image   install the tools / download and verify the cloud image (once per release)"
	@echo "  make vm-up | vm-ssh | vm-sync | vm-down | vm-reset | vm-status   boot, log in, copy the clone in, stop, throw the disk away, show"
	@echo "  make vm-test-agent        install the Agent with its bus policy, unit and AppArmor profile in the VM and test the confinement"
	@echo "  make vm-test-agent-all    the same on every release (boots each VM; the images must be downloaded)"
	@echo "  make vm-test-provider     install the TPM provider with its unit and AppArmor profile in the VM and test it on the VM's TPM (the VM must be of this machine's release: it is a dynamic binary)"
	@echo "  make vm-test-pam vm-test-rpbind vm-test-uhid          spike 0007 at runtime: which bus a process reaches from inside sudo and a root PAM caller"
	@echo "  make vm-test-rpbind       spike 119: a credential key bound to its relying party inside the TPM"
	@echo "  make vm-test-uhid         spike 121: the uhid helper under a profile, and what a compromised one can do"
	@echo "  make vm-test-uhid-session spike 138: one virtual key per user and session, on a seat with two users"
	@echo "  make vm-test-prompt-identity spike 177: what tells the Agent the prompt is the real one, and what a same-user impostor can do"
	@echo "  make vm-test-prompt-launch spike 177 follow-up: a non-root Agent starts the prompt as a system unit, and what a same-user impostor can do"
	@echo "  make vm-test-uvup         spike 120: resident keys, presence and user verification in the virtual CTAP authenticator, browsers, and a same-user process against the prompt"
	@echo
	@echo "Architecture repository: the pinned Structurizr image (needs the architecture checkout at $(ARCH_REPO_DIR))"
	@echo "  make image-check [ENGINE=podman|docker]   pull the pinned image from the org's registry, else Docker Hub, and say which"
	@echo "  make image-mirror         copy the pinned image from Docker Hub to the org's registry (skopeo, after skopeo login ghcr.io)"
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
map: ; @bash scripts/map.sh
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
draft-brief:
	@test -n "$(ISSUE)" || { echo "usage: make draft-brief ISSUE=<number>"; exit 1; }
	@bash local/lh-draft.sh brief $(ISSUE)
draft-next-brief:
	@LH_ISSUE="$(ISSUE)" LH_DRY="$${DRY:-0}" bash local/lh-draft-next.sh
draft-adr:
	@test -n "$(TITLE)" -a -n "$(DECISION)" || { echo "usage: make draft-adr TITLE='...' DECISION='text or file'"; exit 1; }
	@bash local/lh-draft.sh adr "$(TITLE)" "$(DECISION)"
memory-venv:
	python3 -m venv $(HOME)/.local/share/linux-hello/venv
	$(HOME)/.local/share/linux-hello/venv/bin/pip install -r local/memory-requirements.txt
memory-index: ; @bash local/lh-memory-cli.sh index
memory-query:
	@test -n "$(Q)" || { echo "usage: make memory-query Q='text' [TIER=public|private]"; exit 1; }
	@LH_MEMORY_TIER=$${TIER:-public} bash local/lh-memory-cli.sh query "$(Q)" --clone "$(CLONE_DIR)"
memory-stats: ; @LH_MEMORY_TIER=$${TIER:-public} bash local/lh-memory-cli.sh stats
memory-expire: ; @LH_MEMORY_TIER=$${TIER:-public} bash local/lh-memory-cli.sh expire
models: ; @curl -fsS http://127.0.0.1:11434/api/ps | jq -r '.models[] | "\(.name)  \(.context_length) ctx  \(.size_vram / 1e9 | floor) GB in VRAM"'
models-unload: ; @for m in $$(curl -fsS http://127.0.0.1:11434/api/ps | jq -r '.models[].name'); do curl -fsS http://127.0.0.1:11434/api/generate -d "{\"model\":\"$$m\",\"keep_alive\":0}" >/dev/null && echo "unloaded $$m"; done
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

# --- ADR tooling -----------------------------------------------------------------------------
# adr-tools (https://github.com/npryce/adr-tools) provides the `adr` command. Ubuntu packages it, so
# apt is enough. scripts/adr.sh points it at the architecture repository ($(ARCH_REPO_DIR)/adr) and
# makes it use that repository's template, which adr-tools' own numbering and wording do not match.
adr-tools:
	@if command -v adr >/dev/null 2>&1; then echo "adr-tools: already installed ($$(command -v adr))"; \
	 else echo "installing: adr-tools"; sudo apt-get install -y adr-tools; fi
	@bash scripts/adr.sh setup
adr:
	@test -n "$(TITLE)" || { echo "usage: make adr TITLE='...'"; exit 1; }
	@bash scripts/adr.sh new "$(TITLE)"

# --- Test VM ---------------------------------------------------------------------------------
# scripts/vm.sh says what each step does. Each release has its own state directory and ssh port, so
# the guests run side by side; VM_RELEASE picks the one a target acts on (default 24.04, the release
# CI runs on). The values are set here, not taken from the environment, so a target that runs
# another release through $(MAKE) is not misled by what this make exported.
VM_RELEASES := 24.04 26.04
VM_RELEASE ?= 24.04
VM_DIR_24.04 := $(HOME)/.local/share/linux-hello-vm
VM_DIR_26.04 := $(HOME)/.local/share/linux-hello-vm-2604
VM_PORT_24.04 := 2222
VM_PORT_26.04 := 2223
$(if $(VM_DIR_$(VM_RELEASE)),,$(error VM_RELEASE=$(VM_RELEASE) is not one of: $(VM_RELEASES)))
export LH_VM_RELEASE := $(VM_RELEASE)
export LH_VM_DIR := $(VM_DIR_$(VM_RELEASE))
export LH_VM_SSH_PORT := $(VM_PORT_$(VM_RELEASE))
VM_PKGS := qemu-system-x86 qemu-utils swtpm swtpm-tools cloud-image-utils rsync openssh-client ubuntu-keyring gpgv curl
vm-deps:
	@missing=; for p in $(VM_PKGS); do dpkg -s $$p >/dev/null 2>&1 || missing="$$missing $$p"; done; \
	 if [ -z "$$missing" ]; then echo "vm-deps: everything is installed"; \
	 else echo "installing:$$missing"; sudo apt-get install -y $$missing; fi
vm-image: ; @bash scripts/vm.sh image
vm-up: ; @bash scripts/vm.sh up
vm-ssh: ; @bash scripts/vm.sh ssh
vm-sync: ; @bash scripts/vm.sh sync
vm-down: ; @bash scripts/vm.sh down
vm-reset: ; @bash scripts/vm.sh reset
vm-status: ; @echo "Ubuntu $(VM_RELEASE), ssh port $(LH_VM_SSH_PORT)"; bash scripts/vm.sh status
vm-test-agent: ; @bash scripts/vm-test-agent.sh
vm-test-provider: ; @bash scripts/vm-test-provider.sh
vm-test-pam: ; @bash scripts/vm-test-pam.sh
vm-test-rpbind: ; @bash scripts/vm-test-rpbind.sh
vm-test-uhid: ; @bash scripts/vm-test-uhid.sh
vm-test-uhid-session: ; @bash scripts/vm-test-uhid-session.sh
vm-test-prompt-launch: ; @bash scripts/vm-test-prompt-launch.sh
vm-test-prompt-identity: ; @bash scripts/vm-test-prompt-identity.sh
vm-test-uvup: ; @bash scripts/vm-test-uvup.sh
vm-test-agent-all:
	@for r in $(VM_RELEASES); do echo "==> Ubuntu $$r"; $(MAKE) --no-print-directory vm-up vm-test-agent VM_RELEASE=$$r || exit 1; done

# --- Architecture repository: the pinned Structurizr image ------------------------------------
# The scripts live in $(ARCH_REPO_DIR)/scripts (resolve-image.sh, mirror-image.sh, image.env).
ENGINE ?= podman
image-check:
	@test -f $(ARCH_REPO_DIR)/scripts/resolve-image.sh || { echo "$(ARCH_REPO_DIR)/scripts/resolve-image.sh missing: clone LinuxHello/linux-hello-architecture there and pull main (or set ARCH_REPO_DIR)"; exit 1; }
	@bash $(ARCH_REPO_DIR)/scripts/resolve-image.sh $(ENGINE) >/dev/null
image-mirror:
	@test -f $(ARCH_REPO_DIR)/scripts/mirror-image.sh || { echo "$(ARCH_REPO_DIR)/scripts/mirror-image.sh missing: clone LinuxHello/linux-hello-architecture there and pull main (or set ARCH_REPO_DIR)"; exit 1; }
	@bash $(ARCH_REPO_DIR)/scripts/mirror-image.sh

# --- Checks ---------------------------------------------------------------------------------
test:
	bash local/test-lh-env.sh
	bash local/test-lh-implement-next.sh
	bash local/test-lh-branch.sh
	bash local/test-lh-brief.sh
	bash local/test-lh-status.sh
	bash local/test-lh-prompts.sh
	bash local/test-map.sh
	bash local/test-lh-guard.sh
	bash local/test-lh-nothink-relay.sh
	bash local/test-lh-model.sh
	bash local/test-lh-draft.sh
	bash local/test-lh-draft-next.sh
	bash local/test-lh-memory.sh
	bash scripts/test-triage.sh
	bash scripts/test-next.sh
	bash scripts/test-implementer-env.sh
	bash scripts/test-dco-signoff.sh
	bash scripts/test-vm.sh
	@if command -v shellcheck >/dev/null; then shellcheck -S warning -x -P SCRIPTDIR scripts/*.sh local/*.sh && echo "shellcheck clean"; \
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
