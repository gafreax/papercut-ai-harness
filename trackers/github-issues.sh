#!/bin/zsh
# GitHub Issues adapter — SKELETON, not implemented.
#
# The interesting one: here the tracker and the code host are the same system,
# so a run can close the loop (PR "Fixes #123" auto-closes the issue) in a way
# Jira cannot.
#
# Invoked as: github-issues.sh dump <run_dir> | github-issues.sh replay <run_dir>

set -uo pipefail

verb="${1:-}"
run_dir="${2:-}"

# ---------------------------------------------------------------------------
# Mapping notes — decide these before writing code
# ---------------------------------------------------------------------------
#
# scope         A label ("paper-cut") and/or a milestone. GitHub sub-issues
#               exist now, so `parent` can map to a real parent issue.
# key           `#123`. Branch names become `123-<slug>` — fine, but the
#               branch loses the project prefix; consider `issue-123-<slug>`.
# eligibility   `gh issue list --assignee` — eligible = unassigned or the
#               owner's, minus `exclude_labels`. `gh issue list --json` gives
#               everything the dump needs in one call.
# description   `gh issue view <n> --json body,comments`.
# transition    GitHub has no In Progress state. Options, in order of how
#               little they lie: a project board column (needs the Projects v2
#               GraphQL API), an `in-progress` label, or nothing at all — the
#               linked draft PR already signals the work started.
# create-slice  `gh issue create` + `gh issue edit --add-sub-issue` if the repo
#               uses sub-issues, otherwise a task-list checkbox in the parent
#               body.
#
# Auth: `gh` reads the keyring. Same rule as everywhere else — this adapter
# runs in the runner, outside the sandbox, and the agents only queue actions.
#
# Note: the harness already passes a GitHub token into the sandbox for push and
# `gh pr create`. Resist reusing it here to let the agents write issues
# directly: the whole point of the broker is that tracker writes are validated
# against `eligible.txt` before they happen.
#
# ---------------------------------------------------------------------------

print -r -- "github-issues.sh: not implemented yet (verb='${verb}', run_dir='${run_dir}')" >&2
print -r -- "Implement dump/replay per trackers/README.md, then set tracker.kind=github-issues." >&2
exit 64
