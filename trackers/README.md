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
- reject any status other than `tracker.in_progress_status`;
- assign only to `tracker.owner`;
- reject unknown verbs.

Log every outcome — accepted and rejected — to `<run_dir>/jira-actions.log`.
Honour `PAPERCUTS_DRY_JIRA=1` by logging what would run instead of running it.

### Action verbs

```json
{"action":"comment","key":"ABC-1","body_file":"<abs path inside run dir>"}
{"action":"assign","key":"ABC-1"}
{"action":"transition","key":"ABC-1","status":"In Progress"}
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
