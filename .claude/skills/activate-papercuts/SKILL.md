---
name: activate-papercuts
description: Configure and activate the paper-cut harness for a project — asks which repo to work on, which tracker and backlog to mine, then writes config.json, rehearses a run and schedules it. Use when the user wants to set up, activate, reconfigure or schedule the papercut-ai-harness.
---

# Activate the paper-cut harness

Set up an unattended daily run that mines a backlog for genuinely small tickets
and leaves reviewable pull requests. Your job in this skill is to produce a
correct `config/config.json`, prove the wiring works with a rehearsal, and only
then schedule it.

**Never schedule before a rehearsal has passed.** A run that opens pull requests
every morning is not something to switch on hopefully.

## 1. Gather what the harness needs

Ask only for what you cannot detect. Detect the rest and confirm it.

**Project**
- Repository (`owner/name`) and the local checkout path. Detect with
  `git -C <path> remote get-url origin` if the user names a directory.
- Base branch — detect via `git symbolic-ref refs/remotes/origin/HEAD`.
- Worktree and branch naming. Look at how existing worktrees are named
  (`git worktree list`) and at recent branches (`git branch -r --sort=-committerdate`)
  before proposing a pattern: match the project's habit, don't invent one.

**Tracker** — `jira`, `trello`, `github-issues`, or something new.
- Only `jira` is implemented; the others are skeletons in `trackers/`. If the
  user needs one of those, say plainly that it must be written first, and offer
  to write it against the contract in `trackers/README.md`.
- What to mine: a parent/epic key, a label, or both. Ask which, then **verify it
  exists and see what is in it** before writing it into the config — a scope
  that matches nothing produces a harness that silently does nothing every
  morning.
- Which labels mean "a human must look first" (e.g. `hitl`). These are excluded
  from every run.
- The owner's tracker user, email, and GitHub username — used to filter what is
  eligible and to assign the PRs.

**Verification commands** — this is where most misconfigurations hide. Read the
repo's `package.json` / task runner and its git hooks:
- the install command, the checks (lint, typecheck, test, dead-code), and what
  the pre-push hook actually runs;
- whether any check needs credentials or network the sandbox will not have
  (a codegen step hitting a private API is the classic one — see
  `docs/HOW-IT-WORKS.md`);
- how gitignored environment files reach a fresh worktree. If the project has
  no answer for this, the harness cannot run the checks, and that is a blocker
  worth naming now rather than at 6am.

**Sandbox** — the defaults in `config.example.json` confine writes to the
workspace and egress to a domain allowlist. Adjust:
- extra write paths the package manager needs (its store, its cache);
- the domains the checks contact — package registry, code host, tracker, and
  any private API a codegen step introspects. A missing domain shows up as a
  DNS failure inside the run, not as a permission error.

**Schedule** — local time. Consider when the machine is actually awake, and
that several agents running checks in parallel will make it loud.

## 2. Write the config

Copy `config/config.example.json` to `config/config.json` and fill it in. Keep
the `$comment` keys: they are the field documentation and nothing reads them.

Then show the user the diff between example and config, in prose: what you
detected, what you assumed, what you could not determine.

## 3. Rehearse

```
zsh bin/papercuts-daily.sh --dry
```

The rehearsal does the real work — selection, worktrees, fixes, tests — but no
GitHub token is exported, so pushing and `gh` cannot succeed even if an agent
tried. Tracker actions are logged instead of executed.

Then **read the results and report honestly**:
- `.state/logs/papercuts-<date>.log` — did the tracker dump work? how many
  candidates were eligible?
- `.state/runs/<date>/report.md` — what was selected, what was dropped and why.
- `.state/runs/<date>/jira-actions.log` — what would have been written.
- The worktrees left behind: inspect the diffs. Do the fixes hold? Do the
  commits have valid scopes? Did the tests actually run, or were they collected
  by nothing?

A rehearsal that produces no delegated work is not a failure — it may mean the
backlog has nothing genuinely small in it, which is worth telling the user.

## 4. Schedule

Only once the rehearsal looks right:

```
zsh bin/install.sh
```

Report the label, the schedule, and how to stop it (`zsh bin/uninstall.sh`).
Tell the user the first run is the next occurrence — installing does not start
anything.

## Making the skill reachable

Skills load from the directory a session is opened in. If the user works from a
parent directory, symlink it:

```
mkdir -p ~/.claude/skills
ln -s <harness>/.claude/skills/activate-papercuts ~/.claude/skills/activate-papercuts
```

## Things worth saying out loud during setup

- The agents are **sandboxed and cannot authenticate to the tracker**. That is
  the design, not a limitation to route around: the runner brokers reads and
  validates writes, so an agent can propose a tracker change but never make one.
- The harness never passes `--no-verify`. If a repo's hooks are not installed in
  a fresh worktree, git skips them **silently** and the guarantee is empty —
  the worker instructions probe for this, and the setup should confirm the probe
  path is right for this repo.
- Nothing here judges whether a ticket is worth doing. It judges whether a
  ticket is *small and unambiguous enough* to hand to a worker unattended. Those
  are different questions, and the second one is the only one a machine should
  be answering at 6am.
