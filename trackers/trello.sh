#!/bin/zsh
# Trello adapter — SKELETON, not implemented.
#
# Kept as a stub on purpose: it is the second implementation that keeps the
# contract in trackers/README.md honest, instead of letting it drift into
# "whatever Jira happens to do".
#
# Invoked as: trello.sh dump <run_dir> | trello.sh replay <run_dir>

set -uo pipefail

verb="${1:-}"
run_dir="${2:-}"

# ---------------------------------------------------------------------------
# Mapping notes — decide these before writing code
# ---------------------------------------------------------------------------
#
# scope         A Trello *list* (e.g. "Paper cuts") or a *label*. Jira's
#               parent/epic has no direct equivalent; a list is the closest
#               thing to "the backlog we mine".
# key           Card shortLink (e.g. "aBcD1234"). Short, stable, URL-safe —
#               unlike the card id. Branch names would become
#               `papercut-aBcD1234-<slug>`, which is uglier than `PROJ-123`:
#               consider adding a human-set "ref" custom field instead.
# eligibility   Trello has no assignee-vs-reporter split: use *members*.
#               Eligible = no member, or the owner is a member. `hitl` becomes
#               a label check, same as Jira.
# description   Card `desc` (markdown) + comments via /1/cards/{id}/actions.
# transition    Trello has no status field: "In Progress" is a *list move*.
#               So `in_progress_status` must name a list, and the adapter must
#               resolve list name -> idList on the board.
# create-slice  A new card in the same list, with a linked-card attachment
#               back to the parent (Trello's attach-to-card is the closest
#               thing to Jira's "relates to").
#
# Auth: key + token as env vars (TRELLO_KEY / TRELLO_TOKEN), read by the runner
# outside the sandbox — never handed to the agents.
#
# ---------------------------------------------------------------------------

print -r -- "trello.sh: not implemented yet (verb='${verb}', run_dir='${run_dir}')" >&2
print -r -- "Implement dump/replay per trackers/README.md, then set tracker.kind=trello." >&2
exit 64
