#!/bin/zsh
# Proves the Jira broker does not repeat an action that already succeeded.
#
# Background: on 2026-11-11 two runs shared one run directory, the queue file
# EXP-1843.jsonl still held the morning's lines, and the afternoon replay
# posted the morning comment again. Nothing here talks to Jira: `acli`,
# `thomctl` and `gh` are stubs on PATH that keep their state in a temp dir and
# log every call.
#
# Usage: tests/replay-once.sh
# It runs the suite against trackers/jira.sh (must pass), then against a copy
# with the ledger check disabled (must fail) — the mutation check that shows
# the tests cover the fix and not just the happy path.

set -uo pipefail
HERE="${0:A:h}"
REAL="$HERE/../trackers/jira.sh"

fails=0
check() { # <description> <expected> <actual>
  if [[ "$2" == "$3" ]]; then print -r -- "  ok   $1"
  else print -r -- "  FAIL $1 (expected $2, got $3)"; (( fails++ )); fi
}

make_stubs() { # <sandbox>
  local sb="$1"; mkdir -p "$sb/bin"
  print -r -- "0" >"$sb/comments"; print -r -- "Open" >"$sb/status"; print -r -- "nobody" >"$sb/assignee"
  cat >"$sb/bin/acli" <<'STUB'
#!/bin/zsh
# acli jira workitem view KEY --fields F --json | assign | transition
sub="$3"
case "$sub" in
  view)
    case "$6" in
      comment)  jq -nc --argjson n "$(<$SB/comments)" '{fields:{comment:{comments:[range($n)|{id:"\(.)",body:{}}]}}}' ;;
      status)   jq -nc --arg s "$(<$SB/status)" '{fields:{status:{name:$s}}}' ;;
      assignee) jq -nc --arg a "$(<$SB/assignee)" '{fields:{assignee:{emailAddress:$a}}}' ;;
      updated)  print -r -- '{"fields":{"updated":"2026-11-11T10:00:00.000+0100"}}' ;;
    esac ;;
  assign)     print -r -- "assign $*" >>$SB/calls; [[ -e $SB/fail ]] || print -r -- "me@example.com" >$SB/assignee ;;
  transition) print -r -- "transition $*" >>$SB/calls; [[ -e $SB/fail ]] || print -r -- "In Progress" >$SB/status ;;
esac
STUB
  cat >"$sb/bin/thomctl" <<'STUB'
#!/bin/zsh
if [[ "$1 $2" == "issue comment" ]]; then
  print -r -- "comment $3 $(cat "$5")" >>$SB/calls
  [[ -e $SB/fail ]] || print -r -- $(( $(<$SB/comments) + 1 )) >$SB/comments
fi
STUB
  print -r -- '#!/bin/zsh' >"$sb/bin/gh"
  chmod +x "$sb"/bin/*
}

run_suite() { # <jira.sh to test>
  local jira="$1" sb run
  sb="$(mktemp -d)"; run="$sb/run"
  mkdir -p "$run/jira-actions" "$run/comments" "$sb/checkout"
  make_stubs "$sb"
  export SB="$sb" PATH="$sb/bin:$PATH" PC_CHECKOUT="$sb/checkout" PC_TRACKER_EMAIL=me@example.com \
         PC_TRACKER_USER=me PC_STATUS_IN_PROGRESS="In Progress" PC_STATUS_IN_REVIEW="In Review" \
         PC_REPO=org/repo PC_EXCLUDE_LABELS=hitl
  unset PAPERCUTS_DRY_JIRA
  print -r -- "EXP-1" >"$run/eligible.txt"
  local q="$run/jira-actions/EXP-1.jsonl"
  replay() { zsh "$jira" replay "$run" >/dev/null 2>&1; }
  calls() { grep -c "^$1 " "$sb/calls" 2>/dev/null || print 0; }

  print -r -- "morning" >"$run/comments/EXP-1.md"
  { print -r -- '{"action":"comment","key":"EXP-1","body_file":"'$run'/comments/EXP-1.md"}'
    print -r -- '{"action":"assign","key":"EXP-1"}'
    print -r -- '{"action":"transition","key":"EXP-1","status":"In Progress"}'; } >"$q"

  print -r -- "same file replayed twice"
  replay; replay
  check "one comment" 1 "$(calls comment)"
  check "one assign" 1 "$(calls assign)"
  check "one transition" 1 "$(calls transition)"

  print -r -- "second run appends to the same queue (the 2026-11-11 incident)"
  print -r -- "afternoon" >"$run/comments/EXP-1b.md"
  print -r -- '{"action":"comment","key":"EXP-1","body_file":"'$run'/comments/EXP-1b.md"}' >>"$q"
  replay
  check "only the new comment is added" 2 "$(calls comment)"
  check "morning comment not reposted" 1 "$(grep -c 'comment EXP-1 morning' $sb/calls)"

  print -r -- "same line, rewritten body file = a new comment"
  print -r -- "rewritten" >"$run/comments/EXP-1.md"
  replay
  check "rewritten body is posted" 3 "$(calls comment)"

  print -r -- "failed actions stay retryable"
  print -r -- "retry me" >"$run/comments/EXP-1c.md"
  print -r -- '{"action":"comment","key":"EXP-1","body_file":"'$run'/comments/EXP-1c.md"}' >>"$q"
  touch "$sb/fail"; replay
  check "nothing posted while failing" 3 "$(<$sb/comments)"
  rm "$sb/fail"; replay
  check "posted once the tracker recovers" 4 "$(<$sb/comments)"

  rm -rf "$sb"
}

print -r -- "== real trackers/jira.sh"
run_suite "$REAL"
real_fails=$fails

print -r -- "== mutant: ledger check disabled (must FAIL)"
mutant="$(mktemp -d)/jira.sh"
sed 's/^already_applied() .*/already_applied() { return 1; }/' "$REAL" >"$mutant"
cmp -s "$REAL" "$mutant" && { print -r -- "mutation did not apply"; exit 2; }
fails=0
run_suite "$mutant"
mutant_fails=$fails

print -r -- "real failures: $real_fails, mutant failures: $mutant_fails"
(( real_fails == 0 && mutant_fails > 0 ))
