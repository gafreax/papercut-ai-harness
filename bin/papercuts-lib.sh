#!/bin/zsh
# papercuts-lib.sh — decisions the runner makes about the world after a run,
# kept out of papercuts-daily.sh so they can be called and checked on their
# own. Sourced, not executed. Every function expects the caller to define
# `log` (the runner's goes to the day's log file).

# --------------------------------------------------------------------------
# Is a branch still waiting to be published?
# --------------------------------------------------------------------------
# Prints one of:
#   pending   commits exist that are not on the remote and not in any PR
#   landed    every local commit is in a PR that GitHub reports MERGED or CLOSED
#   unknown   GitHub could not be asked — distinct from both, on purpose
#   clean     nothing ahead
#
# Counting commits against the base branch is not enough once the remote
# branch is gone. The project squash-merges, and deletes the branch after the
# merge: the squash commit on main has a new SHA, so the original commits stay
# "ahead" forever. That is how three merged PRs were reported every morning as
# "3 branch(es) to publish" from 2026-08-15 to 2026-10-01. Only the code host
# knows the branch landed, so it is asked — but only in that one case, to keep
# a run with nothing to report from making network calls.
#
# A merged PR settles it only if it contains what is on disk: a commit made
# locally after the merge is still unpublished work, so the local HEAD must be
# one of the PR's commits. And a failed `gh` is reported as `unknown`, never
# folded into `landed` or `pending`: a network error must not read as
# "all clear", and it must not raise a false alarm either.
branch_publication_state() {
  local dir="$1" branch="$2" repo="$3" base="$4"
  local ahead head prs

  if git -C "$dir" rev-parse --verify -q "origin/$branch" >/dev/null 2>&1; then
    # The remote branch exists, so it is the honest reference: anything ahead
    # of it was not pushed, whatever any PR says.
    ahead=$(git -C "$dir" rev-list --count "origin/$branch..HEAD" 2>/dev/null || print 0)
    (( ahead > 0 )) && print pending || print clean
    return 0
  fi

  ahead=$(git -C "$dir" rev-list --count "origin/$base..HEAD" 2>/dev/null || print 0)
  (( ahead > 0 )) || { print clean; return 0; }

  head=$(git -C "$dir" rev-parse HEAD 2>/dev/null)
  # stderr kept apart from the JSON: gh prints notices there ("a new release is
  # available") even when it succeeds, and mixed in they would break the parse.
  local errf="${TMPDIR:-/tmp}/papercuts-gh.$$" err
  prs=$(gh pr list -R "$repo" --head "$branch" --state all --json state,commits 2>"$errf")
  local gh_status=$?
  err="$(<"$errf")"; rm -f "$errf"
  if (( gh_status != 0 )) || ! jq -e 'type == "array"' <<<"$prs" >/dev/null 2>&1; then
    log "WARN: could not ask GitHub about $branch ($ahead commit(s) ahead of origin/$base): exit $gh_status ${err//$'\n'/ }"
    print unknown
    return 0
  fi

  # An open PR means the work is still in flight; it outranks an older closed
  # one on the same head. A merged or closed PR only counts if it holds HEAD.
  if jq -e 'any(.[]; .state == "OPEN")' <<<"$prs" >/dev/null 2>&1; then
    print pending
  elif jq -e --arg head "$head" \
         'any(.[]; (.state == "MERGED" or .state == "CLOSED") and any(.commits[]; .oid == $head))' \
         <<<"$prs" >/dev/null 2>&1; then
    log "not pending: $branch is $ahead commit(s) ahead of origin/$base by SHA, but its PR is $(jq -r '[.[].state] | unique | join("/")' <<<"$prs") and contains HEAD (${head[1,9]})"
    print landed
  else
    print pending
  fi
}

# --------------------------------------------------------------------------
# Items a previous run already dropped
# --------------------------------------------------------------------------
# The orchestrator is told to read an item's comments before re-judging it,
# but the dump never contains them (`thomctl issue view` does not return
# comments). So it re-judged the same two items every morning, reached the
# same verdict, and posted the same explanation again: one new comment per
# item per day.
#
# The fix lives here, outside the agents: the ledger records, for every item a
# run touched with comments only, the item's `updated` timestamp as read back
# right after the run's own last write. While the tracker still reports that
# exact value, nobody has touched the item since — no human comment, no edit —
# and it is held out of eligible.txt. Any change moves `updated`, and the item
# is a candidate again. Exact string equality, not a date comparison: no
# timezone parsing, no clock skew between this machine and the tracker.
#
# Ledger lines: <KEY> TAB <updated as the tracker reported it> TAB <date parked>

# Removes parked, unchanged items from <eligible> in place and lists them in
# <parked_out>. <updated> holds "<KEY> TAB <updated>" for this run's dump.
# An item whose current `updated` could not be read stays eligible: a missed
# read must cost one duplicate comment at worst, never hide an item for good.
park_filter() {
  local eligible="$1" updated="$2" ledger="$3" parked_out="$4"
  local key upd on
  local -A now was since
  local -a keep

  : >"$parked_out"
  [[ -s "$ledger" ]] || return 0

  if [[ -r "$updated" ]]; then
    while IFS=$'\t' read -r key upd; do
      [[ -n "$key" ]] && now[$key]="$upd"
    done <"$updated"
  fi
  while IFS=$'\t' read -r key upd on; do
    [[ -n "$key" ]] || continue
    was[$key]="$upd"
    since[$key]="$on"
  done <"$ledger"

  while read -r key; do
    [[ -n "$key" ]] || continue
    if [[ -z "${was[$key]:-}" ]]; then
      keep+=("$key")
    elif [[ -z "${now[$key]:-}" ]]; then
      log "WARN: $key was dropped on ${since[$key]}, but its last update could not be read — re-evaluating it rather than hiding it"
      keep+=("$key")
    elif [[ "${now[$key]}" == "${was[$key]}" ]]; then
      log "parked: $key — dropped on ${since[$key]}, unchanged on the tracker since"
      print -r -- "$key" >>"$parked_out"
    else
      log "unparked: $key changed on the tracker after it was dropped on ${since[$key]} (${was[$key]} -> ${now[$key]})"
      keep+=("$key")
    fi
  done <"$eligible"

  # `print -l` with no arguments still prints a newline, which `wc -l` would
  # count as one eligible item.
  if (( ${#keep} )); then
    print -rl -- "${keep[@]}" >"$eligible"
  else
    : >"$eligible"
  fi
}

# Merges this run's "<KEY> TAB <updated>" lines into the ledger, replacing any
# older entry for the same key, stamped with <date>.
park_record() {
  local run_parked="$1" ledger="$2" date="$3"
  [[ -s "$run_parked" ]] || return 0
  local tmp="$ledger.tmp.$$"
  [[ -e "$ledger" ]] || : >"$ledger"
  awk -F'\t' -v OFS='\t' -v date="$date" '
    NR == FNR { if ($1 != "") fresh[$1] = $2; next }
    !($1 in fresh)
    END { for (k in fresh) print k, fresh[k], date }
  ' "$run_parked" "$ledger" >"$tmp" && mv "$tmp" "$ledger"
  log "parked for the next runs: $(cut -f1 "$run_parked" | tr '\n' ' ')"
}
