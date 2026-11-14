# Guides

Step-by-step instructions for working with this repository's tooling. [RUNBOOK.md](../RUNBOOK.md) is the reference ("which target when"); these guides walk one job from start to end, say what you should see, and say what to do when you do not.

Run every command from this repository's root, on the workstation, unless a step says otherwise.

## The usual order

| Step | Guide | You do this when |
| :-- | :-- | :-- |
| 1 | [Pick the next task](01-pick-the-next-task.md) | You sit down and ask "what now?" |
| 2 | [Draft a brief](02-draft-a-brief.md) | `make next` shows an issue in the **brief** lane |
| 3 | [Implement an issue](03-implement-an-issue.md) | An issue has a posted brief |
| 4 | [When a run fails](04-when-a-run-fails.md) | `make implement` ended with an error |
| 5 | [Review, sign off and merge](05-review-sign-off-and-merge.md) | A pull request is waiting, or CI is red |
| 6 | [Triage and labels](06-triage-and-labels.md) | The labels or the order of the backlog are wrong |
| 7 | [The shared memory](07-shared-memory.md) | You set it up, update it, or query it |

## Words used in these guides

| Word | Meaning |
| :-- | :-- |
| **Lead** | The session that writes briefs and reviews (a Claude session). It never signs off, never holds a token, and never posts a brief without you reading it. |
| **Implementer** | The local model that codes one issue from its brief (`make implement`). |
| **Brief** | The `## Implementation brief` comment on an issue. The implementer takes the **last** such comment on the issue. |
| **Lane** | Where an issue waits: `implement`, `brief`, `spike`, `review`, `stuck`, `untriaged`. `make next` shows the first issue of each. |
| **Gates** | `make gates` in the `linux-hello` clone: formatting, clippy, tests, `cargo deny`, audit, the unsafe policy, fuzz seeds, docs and the C4 check. |
| **Sign-off** | Your DCO `Signed-off-by:` line on every commit. You add it with `make signoff PR=<n>`; nobody else does. |
| **Clone** | Your checkout of the project repository, `~/projects/LinuxHello/linux-hello` (`CLONE_DIR`). The tooling edits it, so keep it clean and on `main` between runs. |

`status:blocked` means "unattended runs failed". It does **not** mean "waiting for another issue". A dependency is a blocked-by link, and the issue keeps its status. [Triage and labels](06-triage-and-labels.md) says how.

## Where things are saved

| What | Where |
| :-- | :-- |
| Draft briefs and ADRs | `~/.cache/linux-hello-drafts/` (`brief-<n>.md`, with `.round0`, `.rejected` and similar files beside it) |
| Rescued work from `make reset` | `~/.local/state/linux-hello-agent/rescue/<time>-<branch>/` |
| Implementer run logs | `~/.local/state/linux-hello-implementer/logs/` |
| Your settings | `~/.config/linux-hello/` (`implementer.env`, `models.env`, `memory.env`); never committed |
| The shared memory's database | `/var/lib/lancedb/knowledge/` (`LH_MEMORY_DIR`), on the encrypted LanceDB volume |
