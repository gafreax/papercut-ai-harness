# papercut-ai-harness

An unattended daily run that mines a backlog for genuinely small tickets, fixes
a few of them — each in its own git worktree, with tests and the project's own
checks — and leaves reviewable pull requests.

Named after Ubuntu's [One Hundred Papercuts](https://wiki.ubuntu.com/One%20Hundred%20Papercuts):
small annoyances that are quick to fix and never quite worth a sprint.

## What makes it different from "prompt a model to fix a ticket"

- **The agents cannot authenticate to the issue tracker.** They run sandboxed;
  the runner dumps what they need to read and validates every write they queue.
- **No `--no-verify`, ever** — and the harness checks that the hooks are really
  installed, because git skips missing hooks in silence.
- **A rehearsal mode that cannot publish**, enforced by withholding the GitHub
  token rather than by asking the agents nicely.
- **Splitting instead of shrinking.** A ticket too big to delegate comes back as
  tracked slices with a comment explaining why, not as a partial fix.

Read [docs/HOW-IT-WORKS.md](docs/HOW-IT-WORKS.md) for the design and for the
defects the first rehearsal caught.

## Requirements

macOS (launchd), `claude`, `git`, `gh`, `jq`, and the CLI of your tracker.
The project you point it at supplies its own package manager and checks.

## Quickstart

```sh
cp config/config.example.json config/config.json
$EDITOR config/config.json          # or: run the activate-papercuts skill

zsh bin/papercuts-daily.sh --dry    # rehearsal: real work, publishes nothing
zsh bin/install.sh                  # schedule it, once the rehearsal looks right
```

Guided setup: open a Claude Code session here and invoke the
**activate-papercuts** skill — it detects what it can, asks for the rest,
rehearses, reads the results with you, and only then schedules.

## Layout

```
bin/papercuts-daily.sh   the runner: tracker dump → agents → validated replay
bin/papercuts-lib.sh     the runner's after-the-fact decisions (pending, parking), callable on their own
bin/render.sh            materialises prompt.md + sandbox-settings.json per run
bin/install.sh           generates and loads the launchd job from config.json
bin/uninstall.sh         unloads it, keeps the logs
config/config.example.json   every project-specific value lives here
prompts/orchestrator.md  the orchestrator prompt ({{placeholders}} from config)
trackers/                one adapter per tracker — jira works, others are skeletons
sandbox/                 notes on the containment settings
docs/HOW-IT-WORKS.md     design, trade-offs, and what the rehearsal caught
.state/                  logs and per-run directories (created on first run)
```

## Modes

| Command | Agents | GitHub | Tracker |
|---|---|---|---|
| `papercuts-daily.sh` | work | push + real PRs | real writes |
| `papercuts-daily.sh --dry` | work | **impossible** — no token exported | logged only |
| `papercuts-daily.sh --replay-only` | skipped | untouched | executes an existing queue |

`--replay-only` is also how you recover: if a run dies after the agents queued
their tracker actions, it drives them without redoing the work.

## Notifications

Every run ends with one, success or failure — a job that fails silently at 06:00
is indistinguishable from a job that never ran, which is how three days of
finished-but-unpublished work once went unnoticed here.

| Situation | Notification |
|---|---|
| PRs opened, nothing left over | *"N PR opened — all work published"* |
| Work committed but not pushed | *"N branch(es) to publish"* + branch names |
| GitHub could not be asked about a branch | *"N branch(es) not verified"* + branch names |
| Aborted early (PATH, auth, tracker down) | *"run aborted"* + the reason |
| Nothing eligible | *"nothing to do"* |

macOS notifications by default; set `notify.command` to route them elsewhere —
the command receives `$PC_TITLE` and `$PC_BODY`. Set `notify.enabled` to false
to silence them.

Only branches matching the job's own `branch_pattern` count as pending: the
worktree glob also matches the human's worktrees, and reporting their unpushed
work would make the notification untrustworthy.

A branch whose remote copy is gone is checked against GitHub before it counts.
The project squash-merges and deletes merged branches, so the original commits
never appear on `main` by SHA and would look unpublished forever — three merged
PRs were reported as "to publish" every morning from 2026-08-15 to 2026-10-01
that way. If GitHub reports a PR for the branch as merged or closed **and**
that PR contains the local HEAD, the branch is done; a commit made after the
merge still counts as pending. If `gh` fails, the branch is reported as *not verified*, on its own
line and in the notification, rather than guessed either way.

## After a run

```sh
tail -40 .state/logs/papercuts-$(date +%F).log   # what the runner did
cat .state/runs/$(date +%F)/report.md            # what the orchestrator decided
cat .state/runs/$(date +%F)/jira-actions.log     # accepted and rejected writes
git -C <checkout> worktree list                  # what is still on disk
```

Worktrees with unpushed commits are left in place on purpose — they are the
evidence when something went wrong.

## Status

Working against Jira + GitHub + a pnpm/turbo monorepo. `trackers/trello.sh` and
`trackers/github-issues.sh` are deliberate skeletons: they carry the mapping
notes needed to implement them and keep the adapter contract from silently
becoming Jira-shaped. See [trackers/README.md](trackers/README.md).
