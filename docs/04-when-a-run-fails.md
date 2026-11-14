# 4. When a run fails

**Goal:** find out in a few minutes why `make implement` stopped, choose how to recover, and not lose any work.

When a run fails, the issue goes back to `status:ready` and the branch `issue-<n>` keeps the model's edits **uncommitted in the clone**. Nothing is pushed.

## Steps

1. Find the line that starts with `ERROR:` in the last lines of the output. The full log of each run is in `~/.local/state/linux-hello-implementer/logs/`.

2. Look it up in the table.

   | The error says | Cause | Do |
   | :-- | :-- | :-- |
   | `working tree not clean in ...` | The clone has uncommitted changes, usually from the previous failed run | `make reset`, then run again. Your edits are saved first (step 5) |
   | `issue #<n> has no '## Implementation brief'` | No brief on the issue | [Draft and post one](02-draft-a-brief.md) |
   | `brief must list 1-5 files under **Files:** or a 'Files' heading` | The Files section is not a list of bullets that start with a backticked path | Correct the brief |
   | `every test the brief names already exists on main: issue #<n> looks implemented` | The brief describes work that already merged, so a run would find nothing to change. It stops before touching labels or files | Check `gh pr list --repo LinuxHello/linux-hello --state merged --search "<n>"`. If the issue has more to do, it needs a new brief. If the brief really changes existing tests rather than adding any, run with `LH_ALLOW_EXISTING_TESTS=1` |
   | `branch issue-<n> already has K commit(s) ahead of main: this issue was implemented` | A finished run exists | Review its pull request: `gh pr list --repo LinuxHello/linux-hello --head issue-<n>`. To run again, use another branch: `LH_BRANCH=issue-<n>-2 make implement ISSUE=<n>` |
   | `not starting issue #<n> on a stale branch` | The local branch is behind `main` | `bash local/lh-reset.sh -y --main`; if it still complains and the branch has no work you want, `git branch -D issue-<n>` in the clone |
   | `commit signing is not enabled` | `commit.gpgsign` is off in the clone | `git config commit.gpgsign true` in the clone |
   | `model '...' not available` | The model is not pulled | `ollama pull` it, or fix `OLLAMA_MODEL` in `implementer.env` |
   | `gates still failing after 2 repair rounds`, with a failing test above it | The code does not pass | See "A test fails" below |
   | `These tests were removed or renamed, and the brief does not allow it` | The model dropped tests, or the brief told it to rename one | See "Tests were removed" below |
   | `Tests named in the brief are missing: ...` | The model did not write them, or wrote them under other names | Retry, or finish by hand |
   | `changes outside the brief's files: ...` | The model edited a file the brief does not list | If the file is needed, add it to the brief; otherwise retry |
   | Aider prints `has hit a token limit` | A reply was longer than the output limit | See "Tests were removed": the cause is the same |

### A test fails

1. Read the failing test and its error in the output.
2. Decide whose mistake it is. Open the brief and find that test's input. A **wrong example in the brief** (a snippet that does not parse, a missing required key) produces exactly this failure, and the model cannot repair it. The model's own code is often right.
3. If the brief is wrong: [correct the brief](02-draft-a-brief.md#correcting-a-posted-brief) and retry (see "Retry" below), or fix the test by hand ("Finish by hand").

### Tests were removed

The guard fails the run if any existing test is gone or renamed. Two causes:

- **The brief asked for a rename.** A faithful implementation would fail. Correct the brief: keep the old test's name and change only its expected value; add the new test beside it.
- **The file was too long for one reply.** In `whole` edit format the model returns the entire file, about 8,000 tokens at most. A file of several hundred lines plus new code does not fit, and the model silently drops parts. Correct the brief so that the new code and tests go into a small file, and the edit to the long file is only a few lines. Or run `HARNESS=claude`, which edits through tools instead of rewriting whole files.

## Recover: pick one

**A. Fix the brief and retry** (best when the brief was wrong or too big for the model)

1. Post a corrected brief as a new comment ([guide 2](02-draft-a-brief.md#correcting-a-posted-brief)).
2. `make reset` (saves the failed edits, cleans the clone).
3. `make implement ISSUE=<n>`.

**B. Retry with Claude Code on the local model**

```sh
make reset
make implement ISSUE=<n> HARNESS=claude
```

**C. Finish by hand** (best when the model's code is right and only a small piece is wrong)

1. Stay on the branch the run left, in the clone: `cd ~/projects/LinuxHello/linux-hello`.
2. Look at what the model did: `git status`, `git diff`.
3. Make the small fix.
4. Run the project's own checks: `cargo test -p <crate>` for the crate, then `make gates`. Everything must pass.
5. Compare against the brief's acceptance list (mutation checks, PR description).
6. Commit and open the pull request yourself, or ask the lead session to do it. Commits are signed; the sign-off comes from `make signoff` ([guide 5](05-review-sign-off-and-merge.md)).

Note that a hand-finished branch does not move the issue's labels: set them yourself ([guide 6](06-triage-and-labels.md)).

## Your edits are never lost

`make reset` writes them outside the repository before it cleans anything:

```
~/.local/state/linux-hello-agent/rescue/<time>-<branch>/
    changes.patch      tracked changes
    files.tar.gz       a copy of every changed or untracked file
    status.txt
    RESTORE.txt        how to get them back
```

Dry run first if you want to see what it would do: `bash local/lh-reset.sh -n --main`.
