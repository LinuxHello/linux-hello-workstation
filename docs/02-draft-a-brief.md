# 2. Draft a brief

**Goal:** an `## Implementation brief` comment on an issue that the implementer can follow without guessing, written by a local model and checked by you. The draft is saved to a file and **never posted for you**.

A brief that is wrong makes the implementer fail slowly (a run takes a long time), so the review in step 5 is where your time pays off.

## Before you start

1. The GPU is free of other models and of an interactive Claude session:

   ```sh
   make models
   ```

   `make draft-brief` unloads the other models to make room, but it refuses to unload one that an interactive session is using ("interactive session" in the error). Close that session first.

2. The `linux-hello` clone is on `main`:

   ```sh
   git -C ~/projects/LinuxHello/linux-hello branch --show-current     # should print: main
   git -C ~/projects/LinuxHello/linux-hello fetch --prune
   ```

   If it prints another branch, run `bash local/lh-reset.sh -y --main` (it saves uncommitted work first, see [guide 4](04-when-a-run-fails.md)). The drafter reads the files of the clone as they are checked out, so on a feature branch it describes unmerged code. It warns you, but it continues.

3. Optional but useful: update the [shared memory](07-shared-memory.md) with `make memory-index`, so the draft can recall earlier decisions.

## Steps

1. Read the issue yourself first:

   ```sh
   gh issue view <n> --repo LinuxHello/linux-hello
   ```

   Look for a **Progress** list. If most items are ticked or point at other issues, there may be nothing left to brief (this happened with #131).

2. Draft:

   ```sh
   make draft-brief ISSUE=<n>
   ```

   It takes several minutes. The harness collects the files and identifiers the issue names, the highest ADR and spike numbers on the architecture repository, and what the memory recalls, and gives them to the model. The model has no tools in its first pass. Then up to two *refine rounds* send the draft back with a list of defects the harness found.

3. Read the messages it prints:

   | Message | Meaning | You do |
   | :-- | :-- | :-- |
   | `WARNING: ... is on <branch>, not main` | The clone is not on `main` | Stop; fix the clone; draft again |
   | `draft written to ~/.cache/linux-hello-drafts/brief-<n>.md` | The first draft exists | Nothing yet |
   | `refine round N: K open point line(s)` | The harness found defects and asked the model to fix them | Wait |
   | `refine: nothing left to resolve` | The brief passed every mechanical check | Go to step 4 |
   | `WARNING: round N gave no usable brief; keeping the previous version` | The revision had no `## Implementation brief` heading, or fewer test names than before | Open `brief-<n>.md.rejected`: it is sometimes the better brief with a different bullet format |
   | `WARNING: still open after refining` | The lines that follow are what the harness could not resolve | Read each one in step 4 |
   | `unrecognized_model` and the connectors notice | Claude Code does not know the local model's name | Ignore |

   What the open-point headings mean:

   | Heading | Meaning |
   | :-- | :-- |
   | `HEDGES` | The brief leaves something for the implementer to decide or look up ("unverified", "if none exists", "## To look up") |
   | `FORMAT` | No test names were found: list each test as `- \`name\`: what it checks` under "Properties and tests first" |
   | `INCONSISTENT` | Two sections disagree: a file count against the list, a file used but not listed, a file or test both in scope and out, a test listed twice, a "new" test that already exists |
   | `NAMES NOT FOUND` | The brief cites a name that exists nowhere in the repository or the issue |

   A finding that says a "new" test **already exists** often means the issue is already implemented: check before you go on.

4. Review the draft against this list. The harness cannot check these:

   - [ ] **The scope matches the issue.** The model's reading of an issue can change between runs. Reread the issue's own text.
   - [ ] **Nothing is already done.** `git log --oneline -5 origin/main -- <file>` for each named file.
   - [ ] **Numbers are real.** ADR and spike numbers match what the "FACTS" line says (next free ADR number, highest spike; spikes are numbered by their issue number).
   - [ ] **Every example parses.** A TOML or code snippet in the brief is valid against the code, with all required keys. (A brief for #133 failed because `[context.session]` lacked the required `methods`.)
   - [ ] **No existing test is removed, renamed or moved.** The implementer's guard fails the run if one is. If a test's expectation changes, the brief says to keep its name and change only the expected value.
   - [ ] **Files: one to five**, each listed as a bullet starting with its backticked path, together under 100,000 bytes. Put new tests in a small file, not in a file of several hundred lines: in the default `whole` edit format the model rewrites the entire file, and a long file does not fit its reply limit.
   - [ ] **Test names are bullets** of the form `- \`name\`: ...` under "Properties and tests first".
   - [ ] **No hedges the implementer would have to resolve.**
   - [ ] **Nothing private**: no hostnames, home paths, hardware details or model names (invariant 8 for the public repository).

5. Fix what you find. Either edit the file by hand, or ask the lead session to patch it. Keep the original: `cp brief-<n>.md brief-<n>.md.orig`.

6. Post it yourself:

   ```sh
   gh issue comment <n> --repo LinuxHello/linux-hello --body-file ~/.cache/linux-hello-drafts/brief-<n>.md
   ```

   The file must start with the line `## Implementation brief`. The implementer uses the **last** comment (or the issue body) that has that heading.

7. **Set the issue to ready.** `make next` and the backlog follow the **labels**, not the comments: a posted brief changes nothing until the status says so. Put the issue's row in `issues/triage.tsv` at `status ready` (keep its priority and blockers), then apply only that row ([guide 6](06-triage-and-labels.md#steps-apply-only-some-rows)):

   ```sh
   f=$(mktemp); grep -P '^<n>\t' issues/triage.tsv > "$f"; APPLY=1 bash scripts/triage.sh "$f"; rm -f "$f"
   ```

   Then `make next` lists the issue in the **implement** lane. Before you do, check that the harness reads your test names: `source local/lh-brief.sh; lh_brief_test_names "$(cat ~/.cache/linux-hello-drafts/brief-<n>.md)"` must list them. The implementer's test gate has nothing to check when it finds none.

## Correcting a posted brief

Post a **new full comment** that starts with `## Implementation brief`, with a short note at the top saying what changed and why. The implementer takes the last one. Do not delete the old one; people read the history.

## Settings

| Variable | Default | Effect |
| :-- | :-- | :-- |
| `LH_DRAFT_ROUNDS` | 2 | Refine rounds; 0 turns refining off |
| `LH_DRAFT_REFINE_CALLS` | 10 | Tool calls the model may use per refine round |
| `LH_DRAFT_MAX_OUTPUT` | 6000 | Reply cap in tokens |
| `LH_THINK` | 0 | 0 switches the model's thinking off through a local relay; thinking filled the whole reply cap before this |
| `LH_EXAMPLE_BRIEF` | 106 | The issue whose brief is shown to the model as the example |
| `LH_DRAFT_CONTEXT_BYTES` / `LH_DRAFT_CONTEXT_FILES` | 24000 / 8 | How much of the repository outline goes into the prompt |
| `LH_MODEL_DRAFT`, `LH_CTX_DRAFT` | in `~/.config/linux-hello/models.env` | Which model drafts, and its window (it must equal the window the model is served with) |

Example: `LH_DRAFT_ROUNDS=0 make draft-brief ISSUE=<n>`.

## If it fails

| Error | Cause | Do |
| :-- | :-- | :-- |
| `Response exceeded the ... output token maximum` | The model is thinking, or the reply is longer than the cap | Check `LH_THINK` is 0 |
| `Prompt is too long` | The context outgrew the window | Lower `LH_DRAFT_CONTEXT_BYTES`, or choose a larger window in `models.env` |
| `Reached max turns` | The model used its tool calls exploring | Re-run; if it repeats, set `LH_DRAFT_ROUNDS=0` and finish by hand |
| An error naming an "interactive session" | A Claude session has the model loaded | Close it |
| `No rule to make target 'draft-brief'` | You are in the wrong directory | `cd ~/projects/LinuxHello/linux-hello-workstation` |
