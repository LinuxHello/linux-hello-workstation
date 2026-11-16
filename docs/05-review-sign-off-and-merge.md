# 5. Review, sign off and merge

**Goal:** a pull request that you have read, that carries your sign-off on every commit, and that is merged with green checks.

The lead (a Claude session) opens pull requests and reviews them. It never adds your sign-off and never merges. You certify and merge.

## Steps

1. Find the pull request:

   ```sh
   gh pr list --repo LinuxHello/linux-hello           # or: --repo LinuxHello/linux-hello-workstation
   gh pr view <n> --repo LinuxHello/linux-hello
   ```

2. Read it. At least:

   - [ ] The description: what changed, and the proof the brief asked for.
   - [ ] The diff, for behaviour and tests, not only formatting (`gh pr diff <n> --repo ...`).
   - [ ] The checks: `gh pr checks <n> --repo ...`.

3. If something is wrong, **get it fixed before you sign off.** Sign-off rewrites the branch (next step); any commit pushed on top of the old branch is then rejected as a non-fast-forward.

4. Sign off, in the repositories that require it. **`linux-hello` and `architecture` have a `dco` check; `linux-hello-workstation` does not**, so a workstation pull request needs no sign-off: read it and merge it (skip to step 6).

   ```sh
   make signoff PR=<n>                                  # the project repository
   make signoff PR=<n> REPO=linux-hello-architecture         # the architecture repository
   ```

   The script lists every commit of the pull request that lacks a `Signed-off-by:` line and asks for an explicit `yes`. It then rebases the branch onto its base (`main`) with `--signoff`, re-signing with your local key, and force-pushes with a lease. It works in a temporary worktree, so your clone is untouched. It refuses to run when the clone's `origin` is not that repository.

   Because it rebases, the branch on GitHub gets **new commit hashes** and may include newer commits of `main`.

5. Wait for the checks to run again (about two minutes), then look:

   ```sh
   gh pr checks <n> --repo ...
   ```

6. Merge on GitHub (squash is the only method enabled).

## After the merge

```sh
git checkout main && git pull --ff-only origin main        # in the repository you merged into
bash local/lh-reset.sh -y --main                           # in the linux-hello clone, if a run left it on a branch
make triage                                                # then APPLY=1 if the plan is right
make board
make memory-index                                          # so the memory sees what merged
```

If the pull request did not close its issue ("Closes #n" was missing), close it yourself: `gh issue close <n> --repo LinuxHello/linux-hello`.

## If a check fails

### `dco`

Your sign-off is missing on one or more commits (this check exists in `linux-hello` and `linux-hello-architecture`, not in `linux-hello-workstation`). Run `make signoff PR=<n>` again; it lists the commits that lack it before it changes anything.

### `SonarCloud Code Analysis`

The project is private, so Sonar's own API shows nothing without a token. GitHub keeps the file and line of each finding as an annotation:

```sh
sha=$(gh pr view <n> --repo LinuxHello/<repo> --json headRefOid --jq .headRefOid)
id=$(gh api repos/LinuxHello/<repo>/commits/$sha/check-runs --jq '.check_runs[] | select(.name | test("Sonar")) | .id')
gh api repos/LinuxHello/<repo>/check-runs/$id --jq '.output.summary'          # what failed: smells, vulnerabilities
gh api repos/LinuxHello/<repo>/check-runs/$id/annotations --jq '.[] | "\(.path):\(.start_line) \(.title)"'
```

The annotation gives a file, a line and a title, not an explanation. Findings seen so far, and what satisfied the gate:

| Title | What it was | What fixed it |
| :-- | :-- | :-- |
| Command Argument Injection / Path Traversal via command-line argument | Text from an input (stdin, a command-line argument) reached a `subprocess` call or an `open()` | Do not pass input-derived text to the command or the path at all: run the command with fixed arguments and process its output in the program |
| A regular expression flagged for slow matching | A heading regex with a repetition after a whitespace class | Split the text with plain string checks instead of a regex |
| A subprocess call with a bare executable name | `git` or `gh` found through `PATH` | Resolve the path once with `shutil.which` and call that |

A check on a regular expression or a validation of the input is **not** enough for the analyser. After a fix, push, wait about two minutes, and read the annotations again: it reports one finding at a time.

### `notes` or `dsl` (architecture repository)

`notes` checks frontmatter and relative links; run `python3 scripts/check-docs.py` in the architecture clone. `dsl` checks that `workspace.dsl` parses.

### Gates (project repository)

Run `make gates` in the clone on the pull request's branch and read the first failure.

## When your push is rejected

If `git push` says non-fast-forward after a sign-off, the branch on GitHub was rewritten. Do not force-push. Fetch it, put your new commit on top, push:

```sh
git fetch origin <branch>
git rebase --onto origin/<branch> <the last commit of your old branch>
git push origin <branch>
```

Then run `make signoff PR=<n>` again, because the new commit has no sign-off (only in a repository with a `dco` check).
