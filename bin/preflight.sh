#!/bin/zsh -l
# preflight.sh — are the credentials the run needs still valid?
#
# Some credentials cannot be stored for good. A cloud login bound to a person
# expires on the identity provider's schedule (every day, under a session
# length policy), and nothing on this machine can renew it without a human at
# a browser. Before this check existed, an expired login surfaced two minutes
# into the run, as "registry login failed", after the human had already
# stopped watching: the day's run was lost and only a banner said so.
#
# The checks are shell commands from `preflight.checks` in the config: each
# has a `name`, a `test` that exits 0 while the credential is valid, and the
# `fix` a human runs to renew it. The runner runs them outside the sandbox,
# like registry_login.
#
# Modes:
#   --warn   check, and notify if anything is expired. Opens nothing and
#            starts nothing, so it is safe at login or on a timer before the
#            run (install.sh schedules it at preflight.warn_at).
#   --wait   check; if anything is expired, notify and wait up to
#            preflight.wait_minutes for the human to log in, reminding every
#            preflight.remind_minutes. Exits 0 as soon as every check passes,
#            1 when the wait runs out. The runners call it before any project
#            starts.
#
# Usage: preflight.sh --warn|--wait [--config FILE] [--log FILE]

set -uo pipefail

HARNESS_DIR="${0:A:h:h}"
MODE="" CONFIG="${PAPERCUTS_CONFIG:-$HARNESS_DIR/config/config.json}" LOG=""
while (( $# )); do
  case "$1" in
    --warn|--wait) MODE="${1#--}" ;;
    --config) CONFIG="$2"; shift ;;
    --log)    LOG="$2"; shift ;;
    *) print -r -- "usage: preflight.sh --warn|--wait [--config FILE] [--log FILE]" >&2; exit 2 ;;
  esac
  shift
done
[[ -n "$MODE" ]] || { print -r -- "usage: preflight.sh --warn|--wait [--config FILE] [--log FILE]" >&2; exit 2; }
[[ -f "$CONFIG" ]] || { print -r -- "no config at $CONFIG" >&2; exit 2; }

TODAY="$(date +%Y-%m-%d)"
STATE_DIR="${PAPERCUTS_STATE_DIR:-$HARNESS_DIR/.state}"
[[ -n "$LOG" ]] || { mkdir -p "$STATE_DIR/logs"; LOG="$STATE_DIR/logs/papercuts-$TODAY-preflight.log"; }

cfg() { jq -r "$1 // empty" "$CONFIG"; }
log() { print -r -- "[$(date +%H:%M:%S)] preflight: $*" >>"$LOG"; }

# Same delivery as the runners: the journal outlasts the banner.
notify() {
  local title="$1" body="$2"
  [[ "$(cfg '.notify.enabled')" == "true" ]] || return 0
  local journal="$(cfg '.notify.journal')"
  if [[ -n "$journal" ]]; then
    journal="${${journal//\{date\}/$TODAY}/#\~/$HOME}"
    mkdir -p "${journal:h}" && print -r -- "- $(date +%H:%M) **$title** — $body" >>"$journal"
  fi
  local custom="$(cfg '.notify.command')"
  if [[ -n "$custom" ]]; then
    PC_TITLE="$title" PC_BODY="$body" sh -c "$custom" >>"$LOG" 2>&1
  elif [[ "$(uname)" == "Darwin" ]]; then
    local t="${title//\"/\\\"}" b="${body//\"/\\\"}"
    osascript -e "display notification \"$b\" with title \"$t\"" >>"$LOG" 2>&1
  elif command -v notify-send >/dev/null; then
    notify-send "$title" "$body" >>"$LOG" 2>&1
  fi
}

n_checks="$(jq '.preflight.checks // [] | length' "$CONFIG")"
(( n_checks > 0 )) || exit 0

# A check that fails once is not yet an expired credential: at login or on
# wake the network is often not up, and a token refresh that cannot reach the
# provider fails exactly like an expired one. Each check gets a few tries
# before it counts as failed.
RETRIES="$(cfg '.preflight.retries')";              : "${RETRIES:=3}"
RETRY_DELAY="${PAPERCUTS_PREFLIGHT_RETRY_DELAY:-20}"
CHECK_TIMEOUT="$(cfg '.preflight.check_timeout_seconds')"; : "${CHECK_TIMEOUT:=60}"

# Runs one test with a deadline: a command that hangs on a dead network must
# not hold the run forever.
run_test() {
  local cmd="$1"
  zsh -c "$cmd" >>"$LOG" 2>&1 &
  local pid=$! waited=0
  while kill -0 $pid 2>/dev/null; do
    (( waited >= CHECK_TIMEOUT )) && { kill $pid 2>/dev/null; wait $pid 2>/dev/null; return 124; }
    sleep 1; (( waited++ ))
  done
  wait $pid
}

# Sets FAILED to "<name> — run: <fix>" lines for the checks still failing.
check_all() {
  FAILED=()
  local i name test fix try ok
  for (( i = 0; i < n_checks; i++ )); do
    name="$(jq -r --argjson i $i '.preflight.checks[$i].name' "$CONFIG")"
    test="$(jq -r --argjson i $i '.preflight.checks[$i].test' "$CONFIG")"
    fix="$(jq -r --argjson i $i '.preflight.checks[$i].fix // "renew it by hand"' "$CONFIG")"
    ok=0
    for (( try = 1; try <= RETRIES; try++ )); do
      if run_test "$test"; then ok=1; break; fi
      (( try < RETRIES )) && sleep "$RETRY_DELAY"
    done
    if (( ok )); then
      log "ok: $name"
    else
      log "EXPIRED: $name (failed $RETRIES time(s)) — fix: $fix"
      FAILED+=("$name — run: $fix")
    fi
  done
}

typeset -a FAILED
check_all
(( ${#FAILED} == 0 )) && exit 0

what="${(j:; :)FAILED}"
schedule="$(cfg '.run.schedule')"

if [[ "$MODE" == "warn" ]]; then
  notify "Paper cuts: login needed before the run${schedule:+ at $schedule}" "$what"
  exit 1
fi

WAIT_MIN="$(cfg '.preflight.wait_minutes')";     : "${WAIT_MIN:=120}"
REMIND_MIN="$(cfg '.preflight.remind_minutes')"; : "${REMIND_MIN:=30}"
POLL="${PAPERCUTS_PREFLIGHT_POLL_SECONDS:-60}"
start=$SECONDS last_notice=$SECONDS

notify "Paper cuts: run waiting for a login" "$what. The run starts by itself once this passes; it gives up after $WAIT_MIN min."
log "waiting up to $WAIT_MIN min for: $what"

while (( SECONDS - start < WAIT_MIN * 60 )); do
  sleep "$POLL"
  # One try per poll while waiting: the human is the retry.
  RETRIES=1 check_all
  if (( ${#FAILED} == 0 )); then
    log "credentials valid after $(( (SECONDS - start) / 60 )) min of waiting — starting the run"
    exit 0
  fi
  what="${(j:; :)FAILED}"
  if (( SECONDS - last_notice >= REMIND_MIN * 60 )); then
    notify "Paper cuts: run still waiting for a login" "$what. Gives up in $(( WAIT_MIN - (SECONDS - start) / 60 )) min."
    last_notice=$SECONDS
  fi
done

notify "Paper cuts: run aborted, login not renewed" "Waited $WAIT_MIN min for: $what. Renew it and kickstart the job."
log "ABORT: waited $WAIT_MIN min, still expired: $what"
exit 1
