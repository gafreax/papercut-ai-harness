# How it works

An unattended run, once a day: pick a few genuinely small tickets from a
backlog, fix each one in its own git worktree, leave reviewable pull requests.

The interesting part is not the prompt. It is everything around it — what the
agents are allowed to touch, what they are structurally unable to do, and how
the guarantees are made real instead of merely stated.

## Shape of a run

```
launchd (06:00)
  └── papercuts-daily.sh          ← NOT sandboxed: holds credentials
       ├── tracker dump           → run_dir/{candidates.json, eligible.txt, issues/*.json}
       ├── render prompt+settings → run_dir/{prompt.md, sandbox-settings.json}
       ├── claude -p (orchestrator, sandboxed)
       │     └── N worker agents in parallel, one worktree each
       │           └── fix → tests → hooks → push → PR
       │           └── queue tracker actions → run_dir/jira-actions/<KEY>.jsonl
       └── tracker replay         ← validates every queued action, then executes
```

The runner is the only component holding credentials. Everything the model does
happens between those two brokered steps.

## Why it runs locally, not in the cloud

The first design was a cloud routine. It died on one requirement: **never
`--no-verify`**.

The repo's `pre-push` hook runs a GraphQL codegen step that introspects a live
private API and needs secrets from gitignored `.env` files. A cloud runner gets
a fresh clone: no `.env`, no introspection, no codegen — so the hook cannot
pass, and the only way to push would be the flag we refuse to use. Exporting the
introspection token to a cloud environment was possible; it was also the wrong
trade for a job whose whole point is to run unattended every morning.

Locally the environment files already exist, the tracker CLIs are already
authenticated, and the worktrees are real directories the human can open and
inspect. The cost is that the machine must be awake — launchd catches up on
wake, so a missed 06:00 becomes a run at first login.

**The general lesson:** find the step that needs credentials or network and let
it decide where the harness lives. Do not decide first and then negotiate with
the checks.

## Containment: sandbox, not obedience

The agents run under the Claude Code sandbox, configured per run in
`sandbox-settings.json` (rendered from `config.json`):

| Setting | Effect |
|---|---|
| `enabled` + `failIfUnavailable` | no sandbox, no run |
| `allowUnsandboxedCommands: false` | `dangerouslyDisableSandbox` is ignored |
| `filesystem.allowWrite` | writes confined to the workspace (+ package store, cache, tmp) |
| `filesystem.denyWrite` | the env-file source and the harness's own prompt are read-only |
| `filesystem.denyRead` | `~/.ssh`, `~/.aws`, keychain |
| `network.strictAllowlist` | egress denied deterministically outside the domain list |
| `permissions.defaultMode: acceptEdits` | no `bypassPermissions` anywhere |

Verified by trying: writing outside the workspace fails, reading `~/.ssh` fails,
`curl https://example.com` fails, while the package registry, the code host and
the codegen API all work.

Note what is *not* enforced by the sandbox: "each agent stays in its own
worktree". Sibling agents share one process and one sandbox, so that rule is
prompt-level. The orchestrator therefore has to *verify* it before reporting —
`git diff --stat` per branch, overlaps stated explicitly. Where a guarantee
cannot be structural, make it checkable and check it.

## Credentials: the two brokered edges

The sandbox blocks the macOS keyring, which is where `gh`, `git` and the tracker
CLI all keep their tokens. That single fact shapes the whole architecture.

**GitHub — handed down.** The runner reads the token once, outside the sandbox,
and passes it through the environment: `GH_TOKEN` for `gh`, plus a credential
helper injected via `GIT_CONFIG_*` so `git push` works without touching global
config. Scoped to the run, never written to disk.

One wrinkle worth knowing: `gh` is a Go binary and verifies TLS through
`trustd`, which the sandbox blocks — it fails with `x509: OSStatus -26276` even
though `curl` to the same host works. `SSL_CERT_FILE` does not help on macOS.
The supported escape is `sandbox.enableWeakerNetworkIsolation`, which reopens
`com.apple.trustd.agent`. It is a real (if narrow) exfiltration side-channel;
egress stays confined to the allowlist.

**The tracker — never handed down.** No env-var override exists for its OAuth
token, and opening the keyring to the agents would defeat the point. So the
tracker is brokered instead:

- **before**: the adapter dumps candidates, full descriptions and comments, and
  computes `eligible.txt` — items unassigned or owned by the human, minus the
  "needs a human first" labels;
- **after**: agents queue actions as JSONL; the adapter validates each one
  against `eligible.txt`, rejects bodies pointing outside the run directory,
  allows only the two configured target statuses and one assignee, and logs
  every accept and reject.

The two statuses are the whole vocabulary: `in_progress` for work that is
committed, `in_review` for work that has a pull request. Nothing else is
reachable, so a run cannot mark an item done or reopen one even if it decides it
should. The review one carries evidence rather than a claim — the queued action
must include the pull request URL, matched against the configured repository and
then confirmed to exist with `gh pr view` before anything moves. A transition
queued by a run that pushed nothing is rejected, with the reason on the record.

Which status to queue is a table in the prompt, not a judgement call: nothing
written → comment only; committed but unpushed → `in_progress`; pull request
open → `in_review`. Leaving that to the model's discretion produced runs that
did correct work and told the board nothing, on the reasonable-sounding grounds
that a transition "would overstate the state" — and a board that says nothing is
how finished-but-unpublished work goes unnoticed for days.

This turned out better than direct access. The agents can *propose* tracker
changes; a deterministic script decides whether they happen. Tested by feeding
it hostile input — another person's ticket, a transition to `Done`, a body file
pointing at `/etc/passwd`, an unknown verb, a malformed line: all rejected, with
the reason on the record.

## Rehearsal mode

`--dry` runs everything for real except publishing. It is enforced by
**withholding the GitHub token**, so push and `gh` fail by construction rather
than by the agents' good behaviour, and tracker actions are logged instead of
executed.

An earlier version had a `DRY_RUN` variable that only silenced the tracker. On a
full run it would have let the agents push branches and open real pull requests
while the name promised nothing would happen. It now refuses to run in that
combination and says why. **A flag that only half-stops the dangerous thing is
worse than no flag.**

## What the rehearsal caught

The first rehearsal produced two decent fixes and three defects worth more than
the fixes.

**Hooks that were never there.** `core.hooksPath` points at a directory
generated by the package manager's `prepare` script and *not tracked in git*.
Every fresh worktree lacks it — and git skips missing hooks **silently**. The
first push completed in seconds, having run no dead-code check, no codegen, no
typecheck, no tests, and looking completely successful. This is more dangerous
than `--no-verify`, because there is no flag to notice.

The first fix — make the worker run `prepare` and probe for the hook file —
turned the silent failure into a loud one, and then the loud one stopped every
run: `husky@9` unconditionally runs `git config core.hooksPath …` first, and in
a worktree that writes the *shared* `.git/config` of the main checkout, which
an unattended sandboxed agent cannot do (nor should it: hooks are executable
code that runs outside the sandbox, so an agent that can write them can rewrite
the mechanism that verifies it).

The real fix is one command in the main checkout, run once by a human:

```sh
git config core.hooksPath "$(git rev-parse --show-toplevel)/.husky/_"
```

…except that fix does not hold on its own. `husky` runs
`git config core.hooksPath .husky/_` on *every* install, and since worktrees
share the main checkout's config, one `pnpm install` in any worktree silently
puts the relative value back — hooks stop resolving again, everywhere. The next
run diagnosed exactly that, with the config file's mtime landing inside the run
window. So the fix is two-part, and both halves are in `config.json`:

- the **runner pins** `core.hooksPath` to `verify.hooks_path` before every run,
  from outside the sandbox where writing `.git/config` is allowed;
- the agents install with the hook installer disabled (`HUSKY=0`), so they
  cannot undo the pin.

An **absolute** hooks path is inherited by every worktree, so hooks resolve
without any per-worktree install. The hook scripts come from the main checkout
while the commands inside them run in the pushing worktree's directory — which
is both correct and a small bonus: a branch cannot weaken the checks that
validate it. Verified by creating a fresh worktree and watching commitlint
reject a non-conventional commit message, which before the change was silently
accepted.

The worker instruction is now *probe first, install only if the probe fails,
and stop if it still fails* — with an explicit ban on hand-creating hook files
or rewriting `core.hooksPath`.

**A test collected by nothing.** A worker added a Storybook interaction test
next to its fix. The runner's globs did not cover that path, so the assertion
ran nowhere — a guarantee that guaranteed nothing. The lesson generalised into
the prompt: writing the test is half the job, proving the runner collects it is
the other half. (Sharding hides this too: the project's story command runs
`--shard=1/4`, so a single invocation covers a quarter of the files and can look
like confirmation.)

**A tracker CLI that reported success by exiting zero.** Both tracker CLIs print
`✗ Failure: <KEY> can't be transitioned: …` on stdout and **exit `0`**. The
broker suppressed their output and trusted the status code, so it wrote
`OK transition <KEY> -> In Progress` to the log for a transition that had not
happened — and the log is the only place anyone looks afterwards, because the
run has already exited. Found by feeding the broker a key that does not exist:
it claimed the transition worked.

Every write is now confirmed by reading the item back — the status compared
against the target, the assignee re-read, the comment count compared before and
after — and `OK` means the board actually changed. This is rule 4 again, in a
place I had not thought to look: the *verifier* of the tracker writes was itself
unverified.

**A pull request URL that borrowed a real one.** The evidence check for a review
transition first matched the URL with a glob, `pull/[0-9]*`. That accepts
`…/pull/1387/../../evil`, and `gh` normalises it straight back to PR 1387 — so a
URL that was not a pull request URL passed the check by borrowing a real PR's
number. Anchored regex, digits only, both ends. Globs are not validators.

**A commit scope that lied.** The commit linter's `scope-enum` had no entry for
one of the apps in the monorepo, so the agent picked the nearest valid scope and
labelled the change after a package it had not touched. The agent was doing the
best it could inside a broken constraint. Fixing the constraint was the actual
work.

None of these are model failures. They are harness failures the model surfaced
by walking into them — which is the argument for rehearsing before scheduling,
and for reading the diffs rather than the summary.

## Selection is the hard part

Anyone can prompt a model to fix a ticket. The difficulty is deciding *which*
tickets can be fixed unattended.

The orchestrator uses a viability test with an explicit bias: **when in doubt,
drop it.** An item qualifies only if the expected behaviour is unambiguous, the
fix is localised, it needs no regeneration of contracts the run cannot verify,
and "done" can be stated in two sentences. A run that delegates nothing is a
good run; a run that hands a worker an underspecified ticket costs a human a
review and produces a pull request to close.

The escape hatch matters as much as the filter. When an item is too big, the
orchestrator does not shrink it silently: it writes the slices, files them as
children of the same parent, links them back, and comments explaining the split.
In the first real run one ticket turned out to be an entire architectural
decision record — it came back as five tracked slices, four marked as needing a
human decision first, with a note that part of the ticket had already landed and
the remainder was smaller than the description suggested.

That is the shape of the value: not "the machine fixed three things", but "the
backlog is now more honest than it was yesterday".

## Design rules worth stealing

1. **Let the credential-bound step choose where the harness runs.**
2. **Contain with the sandbox, not with the prompt.** Prompts are for
   judgement; boundaries belong in configuration.
3. **Broker what you cannot contain.** Reads dumped in, writes queued out and
   validated by a deterministic script.
4. **Verify the verifier.** A hook that is not installed, a test that is not
   collected, a check that returns instantly — all look like success.
5. **Make half-safety impossible.** If a flag does not stop the dangerous thing,
   it must refuse to run.
6. **Rehearse before scheduling.** The first rehearsal is where the harness's
   defects live, not the model's.
7. **Prefer an honest stop to a plausible result.** Both the workers and the
   orchestrator are told that reporting a blocker beats producing something
   green-looking.
