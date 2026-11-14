# 1. Pick the next task

**Goal:** know, in two minutes, what you have to decide today.

## Steps

1. Update your view of GitHub and the clone:

   ```sh
   git -C ~/projects/LinuxHello/linux-hello fetch --prune
   ```

2. Run:

   ```sh
   make next
   ```

3. Read the output in two parts.
   - **The lanes** (top): the first issue in each lane, in priority order. `(nothing)` means that lane is empty.
   - **What to do** (bottom): for each issue, one line saying what it is, a `You decide:` line, and the commands.

4. Act on what `You decide:` says. The lanes mean:

   | Lane | The issue is | You usually |
   | :-- | :-- | :-- |
   | `implement` | Has a posted brief | Run `make implement ISSUE=<n>` ([guide 3](03-implement-an-issue.md)), or leave it for the timer |
   | `brief` | Missing a brief | Check if anything is left to brief, then [draft one](02-draft-a-brief.md) |
   | `spike` | Needs hardware or the test VM | Run the spike yourself, or defer it |
   | `review` | Has a pull request | [Read it, sign off, merge](05-review-sign-off-and-merge.md) |
   | `stuck` | Failed an unattended run | [Diagnose it](04-when-a-run-fails.md) |
   | `untriaged` | Has no status or priority | [Label it](06-triage-and-labels.md) |

## Things `make next` can get wrong

`make next` reads **labels**, and labels lag. Check these before you trust a line:

| You see | What probably happened | Do |
| :-- | :-- | :-- |
| A **review** issue, and `make next` says every pull request that mentions it is merged | The work merged but nobody closed the issue | If the work is done, close it: `gh issue close <n> --repo LinuxHello/linux-hello` |
| A **brief** issue whose remaining parts wait on other issues | An umbrella issue: nothing is left to brief now | Give it blocked-by links ([guide 6](06-triage-and-labels.md)); it drops out of the list |
| A **review** issue with "no PR found" | The `status:in-review` label is wrong | Set its real status in `issues/triage.tsv` and `make triage APPLY=1` |
| Nothing at all, but you expected work | Everything is blocked, or in a lane for someone else | `make backlog` shows the whole order |

## See the whole backlog

```sh
make backlog          # every open issue, by lane, in pick-up order
make backlog-check    # open issues missing a status: or priority: label
```

## When you are done

Nothing was changed by these commands. If you merged or triaged something, run `make board` so the board matches.
