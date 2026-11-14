# 3. Implement an issue

**Goal:** a draft pull request that implements an issue's brief, made by the local model, with every gate green.

The model only edits code. A script does everything else: it reads the brief, runs the gates, gives the model up to two repair rounds, refuses changes outside the brief's files, and opens the draft PR.

## Before you start

1. The issue has a posted brief ([guide 2](02-draft-a-brief.md)), and you have read it: a brief you have not read is a brief you cannot defend later.

2. The clone is clean and on `main`:

   ```sh
   make reset
   ```

   `make reset` saves any uncommitted work to `~/.local/state/linux-hello-agent/rescue/` first, then cleans the clone. Add `--main` to also switch to `main` and fast-forward it: `bash local/lh-reset.sh -y --main`. The run refuses to start on a dirty clone ("working tree not clean").

3. The model server is up and no interactive session holds the GPU (`make models`).

4. Your commits will be signed: `git config --get commit.gpgsign` in the clone must print `true` (an attended run signs and signs off; an unattended run does neither).

## Steps

1. Start the run:

   ```sh
   make implement ISSUE=<n>
   ```

   To use Claude Code against the same local model instead of Aider: `make implement ISSUE=<n> HARNESS=claude`.

2. Wait. It takes a long time and keeps the GPU busy. In order, it:
   1. reads the brief and lists the files it names (one to five);
   2. refuses a brief whose files are too large for the window;
   3. runs the model on exactly those files, with `cargo test` after each edit;
   4. runs the gates, and if they fail gives the model up to two repair rounds with the failure output;
   5. checks that every test the brief names exists, and that no existing test was removed or renamed;
   6. refuses changes in files the brief does not list;
   7. commits, pushes branch `issue-<n>`, opens a **draft** pull request and moves the issue to `status:in-review`.

3. If it ends with a pull request URL, it worked. Go to [guide 5](05-review-sign-off-and-merge.md).

4. If it ends with `ERROR`, the issue is back at `status:ready` and the branch `issue-<n>` keeps the model's edits for you to inspect. Go to [guide 4](04-when-a-run-fails.md).

## What to read in the pull request before you trust it

The brief asks for proof; the harness does not check it. Open the draft PR and confirm:

- [ ] The description names the **mutation checks** the brief asked for and what each showed.
- [ ] The description names every existing test whose **expected value** changed. Compare with the diff.
- [ ] No test was deleted: `git diff origin/main --stat` and a look at the test lists.
- [ ] The changed files are exactly the brief's files.
- [ ] The behaviour is what the issue asked for, not only what the tests assert.

## Settings

Your settings are in `~/.config/linux-hello/implementer.env` (copy the template with `make implementer-env`). The ones that matter:

| Variable | Default | Effect |
| :-- | :-- | :-- |
| `LH_HARNESS` | `aider` | `aider` or `claude` |
| `OLLAMA_MODEL`, `LH_NUM_CTX` | `gemma4-26b-64k:latest`, 65536 | The model and its window |
| `LH_AIDER_EDIT_FORMAT` | `whole` | Leave it. `diff` appended copies of files on four earlier issues |
| `LH_MAX_OUTPUT` | 12000 | Claude Code's reply cap |
| `LH_THINK` | 0 | The model does not think (thinking overflowed the window) |
| `LH_BRANCH` | `issue-<n>` | Use a different branch to run the same brief twice |

## Limits to know about

- In the default `whole` edit format the model returns each edited file **in full**, and one reply is limited to roughly 8,000 tokens. A file of several hundred lines plus new code does not fit; the model then drops parts of the file. The remedy is in the brief: put new code and tests in a small file and keep the edit to a long file small.
- A model of this size follows the brief closely, including its mistakes. A wrong example in the brief becomes a failing test.
