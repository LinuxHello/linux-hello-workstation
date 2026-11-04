#!/usr/bin/env bash
# Every label of the monorepo, with colour and meaning. Idempotent: creates or updates, never
# deletes. The lanes and priorities are explained in the public repo's docs/project/backlog.md.
set -euo pipefail
source "$(dirname "$0")/../common.sh"

log "labels on $ORG/$REPO"
while IFS='|' read -r name color desc; do
  gh label create "$name" --repo "$ORG/$REPO" --color "$color" --description "$desc" --force >/dev/null
done <<'LABELS'
container:dbus|1d76db|linuxhello-dbus interface crate
container:agent|1d76db|Linux Hello Agent
container:pam|1d76db|pam_linuxhello
container:tpm-provider|1d76db|TPM credential provider
container:kpxc-bridge|1d76db|KeePassXC provider bridge
container:plasma|1d76db|Plasma integration
container:ctl|1d76db|linuxhello-ctl
container:security|1d76db|AppArmor, Tetragon, alert rules
container:policy|1d76db|Policy schema and stores
container:workspace|1d76db|Cross-cutting: workspace, CI, governance, docs
type:spike|fbca04|Time-boxed investigation of an unverified assumption
type:feature|0e8a16|New capability
type:bug|d73a4a|Behaviour differs from the documented intent
type:security|b60205|Security property, hardening or vulnerability fix
type:docs|c5def5|Documentation and architecture
one-way-door|5319e7|Hard to reverse; needs an ADR
upstream|bfdadc|Work lands in an upstream project
status:needs-brief|ededed|Lane brief (or spike): waiting for the lead
status:ready|c2e0c6|Lane implement: brief posted, ready to code
status:in-progress|fef2c0|Lane doing: someone has it
status:in-review|d4c5f9|Lane review: pull request open, or the maintainer must act
status:blocked|e99695|Lane stuck: unattended runs failed; the lead diagnoses
priority:now|b60205|On the critical path of the current milestone
priority:next|fbca04|Needed for the following step
priority:later|c5def5|Parked until something changes
LABELS
log "labels done"
