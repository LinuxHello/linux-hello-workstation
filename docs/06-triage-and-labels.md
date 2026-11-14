# 6. Triage and labels

**Goal:** every open issue of the project repository has exactly one `status:` and one `priority:` label, and dependencies are links, so `make next` shows the right work.

`make triage` and the backlog commands only act on **`LinuxHello/linux-hello`**. They do not touch issues in this repository or in the Ansible repository.

## What the labels mean

| Status | Lane | Meaning |
| :-- | :-- | :-- |
| `status:needs-brief` | brief or spike | Waiting for the lead's brief (or for a spike to be run) |
| `status:ready` | implement | A brief is posted; the implementer can take it |
| `status:in-progress` | | Someone has it (set while a run is going) |
| `status:in-review` | review | A pull request is open, or the maintainer has to act |
| `status:blocked` | stuck | **Unattended runs failed**; the lead diagnoses. It does **not** mean "waiting for another issue" |

| Priority | Meaning |
| :-- | :-- |
| `priority:now` | On the critical path of the current milestone |
| `priority:next` | Needed for the following step |
| `priority:later` | Parked until something changes |

**Next** = highest priority, no open blocker, lowest issue number.

## Steps: change one issue

1. Edit `issues/triage.tsv`. One row per issue, tab-separated:

   ```
   <issue>	<status>	<priority>	<blocked by: numbers separated by commas, or ->	<note>
   ```

   Example: `131	needs-brief	next	136,147	Umbrella; item 2 waits for the unlock-state ADR (#136), item 3b for #147`

2. See the plan (changes nothing):

   ```sh
   make triage
   ```

3. Apply it:

   ```sh
   make triage APPLY=1
   ```

   It sets exactly one status and one priority label, adds the blocked-by links, and never removes a link or closes an issue.

4. Refresh the board: `make board`.

## Steps: apply only some rows

`make triage APPLY=1` applies **every** row in the file, including rows nobody has applied yet. To apply one row, give the script a file with just that row:

```sh
f=$(mktemp)
grep -P '^131\t' issues/triage.tsv > "$f"
APPLY=1 bash scripts/triage.sh "$f"
rm -f "$f"
```

## An issue waits on another issue

Do **not** set `status:blocked`. Keep the status the issue would have (usually `needs-brief`) and put the blocking issue numbers in the fourth column. An issue whose blockers are open drops out of `make next` until they close.

## An issue is done

Close it: `gh issue close <n> --repo LinuxHello/linux-hello`. Labels do not change by themselves when a pull request merges.

## Find what is wrong

```sh
make backlog-check     # open issues without a status: or priority: label
make backlog           # the whole order, by lane
```

## A new issue

1. Create it on GitHub.
2. Add a row to `issues/triage.tsv` with its status, priority and blockers.
3. `make triage`, read the plan, then `make triage APPLY=1`.
