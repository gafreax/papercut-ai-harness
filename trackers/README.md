# Tracker adapters

The harness never talks to an issue tracker directly. It shells out to one
adapter, chosen by `tracker.kind` in `config.json`. Swapping Jira for Trello,
GitHub Issues or anything else means writing one file here — nothing else in
the harness changes.

## Why an adapter and not a library call

The agents run **sandboxed** and cannot authenticate: CLIs like `acli` and `gh`
read their credentials from the macOS keyring, which the sandbox blocks by
design (see `docs/HOW-IT-WORKS.md`). So the adapter runs **outside** the
sandbox, in the runner, twice per run:

- **before** the agents start — dump everything they need to read into files;
- **after** they exit — replay the actions they queued, validating each one.

That is not a workaround, it is the security boundary: the agents can propose
tracker writes but never perform them, and the runner is the only thing holding
credentials.

## Contract

An adapter is an executable shell script sourced with `TRACKER_CMD` set to one
of the verbs below. It must implement exactly these:

### `dump <run_dir>`

Write, into `<run_dir>`:

| File | Content |
|---|---|
| `candidates.json` | array of `{key, summary, status, assignee, labels, url}` |
| `eligible.txt` | one key per line — the **only** keys the agents may act on |
| `issues/<KEY>.json` | full item: description **and** comments |
| `updated.tsv` | optional: `<KEY> TAB <last-updated>` per eligible key, the tracker's value verbatim |

Eligibility is the adapter's job: drop anything closed, assigned to somebody
other than `tracker.owner.tracker_user`, or carrying a label in
`tracker.exclude_labels`. Whatever lands in `eligible.txt` is what `replay`
will accept later — the two must agree, because that file is the authorisation
list.

Exit non-zero if the tracker cannot be reached. The runner aborts rather than
starting agents with a stale or empty view.

### `replay <run_dir>`

Read every `<run_dir>/jira-actions/*.jsonl` (one file per item, one JSON object
per line) and execute the actions. **Validate before executing** — the queue is
written by agents and is untrusted input:

- reject any `key` not in `eligible.txt`;
- reject any `body_file` outside `<run_dir>`;
- reject any status other than the two in `tracker.statuses`;
- for `tracker.statuses.in_review`, additionally require a `pr` field matching
  `https://github.com/<project.repo>/pull/<digits>` **exactly** (anchored at
  both ends — a glob lets `pull/1/../../x` through, and the code host will
  cheerfully resolve it back to PR 1) and confirm with the code host that the
  pull request exists;
- assign only to `tracker.owner`;
- reject unknown verbs.

Log every outcome — accepted and rejected — to `<run_dir>/jira-actions.log`.
Honour `PAPERCUTS_DRY_JIRA=1` by logging what would run instead of running it.

Optionally write `<run_dir>/parked.tsv`: `<KEY> TAB <last-updated>` for every
key that received a comment that was really posted and no `assign` or
`transition`, with the last-updated value read back **after** all of this
replay's writes. Together with `updated.tsv` from `dump`, it lets the runner
hold back items a previous run already dropped until they change (see the
README). An adapter that writes neither file simply never parks anything.

**Confirm every write by reading the item back.** Do not report success from a
CLI's exit code: `thomctl` and `acli` both print `✗ Failure: …` and exit `0`, so
a status trusted blindly logs `OK transition` for a transition that never
happened. Read the status back and compare it to the target; read the assignee
back; compare the comment count before and after. This is the same defect class
as an uninstalled git hook — it looks exactly like success.

### Action verbs

```json
{"action":"comment","key":"ABC-1","body_file":"<abs path inside run dir>"}
{"action":"assign","key":"ABC-1"}
{"action":"transition","key":"ABC-1","status":"In Progress"}
{"action":"transition","key":"ABC-1","status":"In Review","pr":"https://github.com/my-org/my-app/pull/42"}
{"action":"create-slice","title":"...","body_file":"<abs path>","mode":"afk|hitl","relates_to":"ABC-1"}
```

`create-slice` is how an agent says "this is too big, here are the pieces". The
adapter creates each piece under the configured scope and links it back.

## Status

| Adapter | State |
|---|---|
| `jira.sh` | working — Jira via `thomctl` (PRD/sub-issue verbs) and `acli` (assign/transition) |
| `trello.sh` | skeleton — verbs stubbed, mapping notes inside |
| `github-issues.sh` | skeleton — verbs stubbed, mapping notes inside |

The two skeletons exist to keep the seam honest: if the contract only ever had
one implementation, it would quietly grow Jira-shaped assumptions.
