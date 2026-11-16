# 7. The shared memory

**Goal:** set up the agents' shared memory once, keep it current, and know what it will and will not tell the models.

The design is [ADR-0019](https://github.com/LinuxHello/linux-hello-architecture/blob/main/adr/0019-shared-agent-memory.md). In short: a LanceDB index of the repositories, their issues and briefs, and your private notes, plus a log of what agents concluded. It returns **evidence with its source, date and status, never an answer**, and marks what a model must not trust. It is not a source of truth: issues, pull requests, ADRs and code are.

## Set it up (once)

1. Install the database library into a virtualenv (this downloads packages):

   ```sh
   make memory-venv
   ```

2. Check that the CPU Ollama has the embedding model:

   ```sh
   curl -s http://127.0.0.1:11435/api/tags | jq -r '.models[].name' | grep nomic-embed-text
   ```

   If it prints nothing, pull it on that instance first.

3. Create your settings from the template (it is never committed):

   ```sh
   cp local/memory.env.example ~/.config/linux-hello/memory.env
   ```

   Edit it. The lines that matter:

   | Setting | Meaning |
   | :-- | :-- |
   | `LH_MEMORY_REPOS` | Repositories to index, each `public:<path>` or `private:<path>`. A path with no prefix is **private**. A repository is public only if you say so. Add `@<ref>` to name a branch other than `origin/main` |
   | `LH_MEMORY_ISSUES` | Issues (with the briefs in their comments) of these repositories, read with `gh` |
   | `LH_MEMORY_NOTES` | Your notes vault, text only. Always private. Leave it unset until you want it indexed |
   | `LH_MEMORY_DIR` | Where the databases live: `<dir>/public` and `<dir>/private`. Default `/var/lib/lancedb/knowledge`; leave the line out to use it |
   | `LH_EMBED_HOST`, `LH_EMBED_MODEL` | The embedding server and model |

4. Index:

   ```sh
   make memory-index
   ```

   The first run embeds everything and takes several minutes. It prints, for each source, how many files were added, changed, removed or unchanged. Run it again: nothing should change, and it should finish in seconds.

## Keep it current

```sh
git -C ~/projects/LinuxHello/linux-hello fetch --prune      # the index reads origin/main, not your checked-out branch
make memory-index
```

Do this after merges, and before you draft a brief. The index is incremental: unchanged files are not read again, changed files replace their old rows, and files that no longer exist are removed. The repositories are read **as committed on `origin/main`**, never from your working tree, so unmerged work does not enter the memory.

## Ask it something

```sh
make memory-query Q='how does the Agent record a user policy change'
make memory-query Q='...' TIER=private          # also searches your notes
make memory-stats                               # rows per kind (TIER=private shows both stores)
```

Each hit looks like `[1] kind | where | date | status` followed by its text. The kinds, in the order the memory ranks them: `code` (what the repository holds, including its Markdown), `decision` (an accepted ADR), `issue` (a claim by its author), `note` (your private notes), `agent` (what an agent concluded).

Marks you will see, and what to do:

| Mark | Meaning | Do |
| :-- | :-- | :-- |
| `CONFLICT C1` (same label on several hits) | The hits are about the same thing, differ, and come from different kinds or dates | Do not pick one. Settle it from the code, or ask the lead |
| `UNVERIFIED` | An agent wrote it and nobody has verified it | Treat it as a lead to check, never as a premise |
| `NOT IN REPOSITORY: x, y` | A note or agent row cites a name that the repository does not contain | Do not use that name |
| `SOURCE CHANGED SINCE READ` | The note on disk changed after it was indexed | Run `make memory-index` |

## Public and private

- Rows live in `<dir>/public` or `<dir>/private`. A public-tier caller never opens the private directory.
- **Drafting a brief is always public-tier**, whatever `LH_MEMORY_TIER` says in your environment or in `memory.env`. A brief is posted to a public repository, so it must not be able to quote your notes.
- `make memory-query` is public-tier unless you pass `TIER=private`. That is your choice as the person at the keyboard; do not set `LH_MEMORY_TIER` in a profile.
- The default location is `/var/lib/lancedb/knowledge`: the LanceDB volume, which is a required, encrypted, `noexec` mount. AnythingLLM mounts only `/var/lib/lancedb/anythingllm` from it, so it cannot see this directory. The private directory is created with mode 0700. If the volume is not mounted, the index would land on the root disk: check `findmnt /var/lib/lancedb` before the first run. Creating the directory and installing the virtualenv by role is tracked in `LemcheNET/workstation#6`.

## Maintenance

| Task | Command |
| :-- | :-- |
| Drop unverified agent rows older than 30 days | `make memory-expire` |
| Mark an agent row as verified | `LH_MEMORY_TIER=public bash local/lh-memory-cli.sh promote <id> --by <you>`. The id is printed when the row is written (`remember`); a query does not show ids yet. Promotion never changes the row's tier |
| Rebuild everything | Delete `<dir>` and run `make memory-index`. Only agent rows are lost, and they are unverified by design |
| Changed the embedding model | Rows from the old model are left out of every search until `make memory-index` re-embeds them; `make memory-query` prints a note with the count |

## If something is wrong

| Symptom | Cause | Do |
| :-- | :-- | :-- |
| `has no origin/main or main to index` | A repository in `LH_MEMORY_REPOS` has neither | Name a ref: `public:<path>@<ref>` |
| `issues <repo>: skipped (...)` | `gh` could not list the issues (issues are disabled on that repository, or the network is down) | Remove it from `LH_MEMORY_ISSUES`, or retry; the rest of the index still ran |
| A draft prints `WARNING: the memory could not be read, continuing without it` | The database or the embedding server is unavailable | The draft still worked without the memory. Check `make memory-stats` |
| A query finds nothing relevant | The thing is new, or lives in an unindexed source | `git fetch`, then `make memory-index` |
| A hit looks stale or wrong | The memory reproduces what its sources say, including their mistakes | Check the source it names. That is what the marks are for |

## What it does not do (yet)

It has no loopback service (the command line is the interface), agents do not write conclusions into it automatically, and the implementer does not recall from it. These are tracked as issues #43, #44 and #45 in this repository.
