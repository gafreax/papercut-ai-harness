#!/bin/zsh
# Proves the credential preflight stops a run on an expired login and lets it
# through once the human renews it.
#
# Background: on 2026-11-21 and 2026-11-23 the cloud login behind the package
# registry had expired overnight; the run aborted two minutes in with
# "registry login failed" and the day's work was lost. Nothing here talks to a
# cloud: the "credential" is a file in a temp dir, valid while it exists, and
# notifications go to a file instead of the screen.
#
# Usage: tests/preflight.sh
# It runs the suite against bin/preflight.sh (must pass), then against a copy
# whose check always reports valid (must fail) — the mutation check that shows
# the tests cover the check and not just the exit path.

set -uo pipefail
HERE="${0:A:h}"
REAL="$HERE/../bin/preflight.sh"

fails=0
check() { # <description> <expected> <actual>
  if [[ "$2" == "$3" ]]; then print -r -- "  ok   $1"
  else print -r -- "  FAIL $1 (expected $2, got $3)"; (( fails++ )); fi
}

make_config() { # <sandbox> [jq object merged into the check]
  local sb="$1" extra="${2:-{\}}"
  jq -n --arg sb "$sb" "$extra"' as $extra | {
    run: {schedule: "10:00"},
    notify: {enabled: true, journal: null, command: ("printf \"%s|%s\\n\" \"$PC_TITLE\" \"$PC_BODY\" >>" + $sb + "/notified")},
    preflight: {
      checks: [{name: "Test login", test: ("test -e " + $sb + "/valid"), fix: "touch valid"} + $extra],
      wait_minutes: 1, remind_minutes: 30, retries: 2, check_timeout_seconds: 5
    }
  }' >"$sb/config.json"
}

zmodload zsh/datetime
age_file() { # <hours> <file>: create the file as if written <hours> ago
  local stamp; strftime -s stamp '%Y%m%d%H%M.%S' $(( EPOCHSECONDS - $1 * 3600 ))
  touch -t "$stamp" "$2"
}

lines() { [[ -e "$1" ]] && wc -l <"$1" | tr -d ' ' || print 0; }
hits() { [[ -e "$2" ]] && grep -c -- "$1" "$2" || print 0; }

suite() { # <preflight script>
  local script="$1" sb rc
  export PAPERCUTS_PREFLIGHT_RETRY_DELAY=0 PAPERCUTS_PREFLIGHT_POLL_SECONDS=1

  sb="$(mktemp -d)"; make_config "$sb"; touch "$sb/valid"
  zsh "$script" --warn --config "$sb/config.json" --log "$sb/log"; rc=$?
  check "valid login: --warn exits 0" 0 $rc
  check "valid login: no notification" 0 "$(lines $sb/notified)"
  rm -rf "$sb"

  sb="$(mktemp -d)"; make_config "$sb"
  zsh "$script" --warn --config "$sb/config.json" --log "$sb/log"; rc=$?
  check "expired login: --warn exits 1" 1 $rc
  check "expired login: --warn notifies once" 1 "$(lines $sb/notified)"
  check "expired login: notification names the fix" 1 "$(hits 'touch valid' $sb/notified)"
  rm -rf "$sb"

  # The human logs in three seconds into the wait.
  sb="$(mktemp -d)"; make_config "$sb"
  ( sleep 3; touch "$sb/valid" ) &
  zsh "$script" --wait --config "$sb/config.json" --log "$sb/log"; rc=$?
  wait
  check "login during the wait: --wait exits 0" 0 $rc
  check "login during the wait: log says it resumed" 1 "$(hits 'credentials valid after' $sb/log)"
  rm -rf "$sb"

  # Nobody logs in: the wait (1 min) runs out.
  sb="$(mktemp -d)"; make_config "$sb"
  zsh "$script" --wait --config "$sb/config.json" --log "$sb/log"; rc=$?
  check "no login: --wait exits 1" 1 $rc
  check "no login: abort is notified" 1 "$(hits 'run aborted, login not renewed' $sb/notified)"
  rm -rf "$sb"

  # A login under a session-length policy passes its test right up to the
  # minute it expires. On 2026-11-25 the 09:00 check said ok, the session ran
  # out at 09:19 and the 10:00 run waited two hours for nobody. With
  # max_age_hours the check also asks how long ago the login happened.
  sb="$(mktemp -d)"; make_config "$sb" '{issued_file: ($sb + "/valid"), max_age_hours: 22}'
  age_file 23 "$sb/valid"
  zsh "$script" --warn --config "$sb/config.json" --log "$sb/log"; rc=$?
  check "old login, test still passing: --warn exits 1" 1 $rc
  check "old login: notification names the fix" 1 "$(hits 'touch valid' $sb/notified)"
  check "old login: log says how old it is" 1 "$(hits 'logged in 23 h ago' $sb/log)"
  rm -rf "$sb"

  sb="$(mktemp -d)"; make_config "$sb" '{issued_file: ($sb + "/valid"), max_age_hours: 22}'
  age_file 21 "$sb/valid"
  zsh "$script" --warn --config "$sb/config.json" --log "$sb/log"; rc=$?
  check "login within max age: --warn exits 0" "0 0" "$rc $(lines $sb/notified)"
  rm -rf "$sb"

  # Renewing the login rewrites the file: the wait ends.
  sb="$(mktemp -d)"; make_config "$sb" '{issued_file: ($sb + "/valid"), max_age_hours: 22}'
  age_file 23 "$sb/valid"
  ( sleep 3; touch "$sb/valid" ) &
  zsh "$script" --wait --config "$sb/config.json" --log "$sb/log"; rc=$?
  wait
  check "old login renewed during the wait: --wait exits 0" 0 $rc
  rm -rf "$sb"

  # No checks configured: nothing to do, nothing said.
  sb="$(mktemp -d)"; print -r -- '{"notify":{"enabled":true,"command":"touch '"$sb"'/notified"}}' >"$sb/config.json"
  zsh "$script" --wait --config "$sb/config.json" --log "$sb/log"; rc=$?
  check "no checks: exits 0 without notifying" "0 no" "$rc $([[ -e $sb/notified ]] && print yes || print no)"
  rm -rf "$sb"
}

print -r -- "bin/preflight.sh:"
suite "$REAL"
real_fails=$fails

mutant="$(mktemp -d)/preflight.sh"
sed 's/^      if run_test "\$test"; then ok=1; break; fi/      ok=1; break/' "$REAL" >"$mutant"
cmp -s "$REAL" "$mutant" && { print -r -- "mutation did not apply"; exit 2; }
fails=0
print -r -- "mutant (every check reports valid) — expected to fail:"
suite "$mutant" >/dev/null
mutant_fails=$fails
rm -rf "${mutant:h}"

# Second mutant: the age is never looked at, only the test. The 2026-11-25
# failure, exactly.
mutant="$(mktemp -d)/preflight.sh"
sed 's/^    if (( ok )) \&\& \[\[ -n "\$max_age" \]\]; then/    if false; then/' "$REAL" >"$mutant"
cmp -s "$REAL" "$mutant" && { print -r -- "mutation did not apply (age check)"; exit 2; }
fails=0
print -r -- "mutant (login age ignored) — expected to fail:"
suite "$mutant" >/dev/null
age_mutant_fails=$fails
rm -rf "${mutant:h}"
(( mutant_fails = age_mutant_fails > 0 ? mutant_fails : 0 ))

print -r -- ""
if (( real_fails == 0 && mutant_fails > 0 )); then
  print -r -- "PASS: suite green on the real script, every mutant caught (age mutant: $age_mutant_fails failure(s))"
  exit 0
fi
print -r -- "FAIL: real=$real_fails failure(s), mutant=$mutant_fails failure(s)"
exit 1
