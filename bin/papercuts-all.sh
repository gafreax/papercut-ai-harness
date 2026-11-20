#!/bin/zsh -l
# papercuts-all.sh — one unattended pass over several repositories, in series.
#
# config/projects.json lists the repositories that share one tracker scope (one
# epic of paper cuts, with items for all of them and no label saying which).
# Each project is an override of the base config — the tracker, the owner and
# the run settings are shared, the checkout, hooks and checks are not — and
# this script runs bin/papercuts-daily.sh once per project, one after the
# other: the runs are unattended, so time is cheap, and two test suites on one
# machine at once is what makes tests time out.
#
# The first project's run routes every eligible item to a repository
# (bin/route.sh); the rest reuse that answer. Items nobody can place go to the
# default project, whose orchestrator drops or asks about them.
#
# Takes the same modes as papercuts-daily.sh (--dry, --replay-only is not
# supported here: replay a single project's run directly).

set -uo pipefail

MODE="${1:-full}"
[[ "$MODE" == "--replay-only" ]] && { print -r -- "--replay-only: run bin/papercuts-daily.sh on the project's run dir instead" >&2; exit 2; }

HARNESS_DIR="${0:A:h:h}"
PROJECTS="${PAPERCUTS_PROJECTS_FILE:-$HARNESS_DIR/config/projects.json}"
STATE_DIR="${PAPERCUTS_STATE_DIR:-$HARNESS_DIR/.state}"
[[ -f "$PROJECTS" ]] || { print -r -- "no $PROJECTS — copy config/projects.example.json" >&2; exit 1; }

BASE="$(jq -r '.base // "config/config.json"' "$PROJECTS")"
[[ "$BASE" == /* ]] || BASE="$HARNESS_DIR/$BASE"
[[ -f "$BASE" ]] || { print -r -- "base config not found: $BASE" >&2; exit 1; }
DEFAULT="$(jq -r '.default' "$PROJECTS")"

STAMP="$(date +%Y-%m-%dT%H%M%S)"
ALL_DIR="$STATE_DIR/runs/all-$STAMP"
mkdir -p "$ALL_DIR" "$STATE_DIR/logs"
LOG="$STATE_DIR/logs/papercuts-$(date +%Y-%m-%d)-all.log"
log() { print -r -- "[$(date +%H:%M:%S)] $*" >>"$LOG"; }

LOCK="$STATE_DIR/.lock-all"
if ! mkdir "$LOCK" 2>/dev/null; then
  log "SKIP: a previous multi-repo run still holds $LOCK"
  exit 0
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT INT TERM

# One merged config per project. Objects merge deeply and the project wins,
# except two places: `verify` is replaced whole (a Go repository shares no
# command with a pnpm one, and a half-inherited hook setting is worse than
# none), and the sandbox path and domain lists are added to the base's, never
# replace them, so a project can widen egress for its toolchain but cannot
# quietly drop a deny rule.
typeset -a names
for name in $(jq -r '.projects | keys_unsorted[]' "$PROJECTS"); do
  jq --argjson ov "$(jq -c --arg n "$name" '.projects[$n]' "$PROJECTS")" '
    . as $base
    | ($base * ($ov | del(.verify)))
    | .verify = ($ov.verify // $base.verify)
    # The scope is shared, so the tracker is read from one place: the base
    # project checkout, which is set up for the tracker CLI.
    | .tracker.cwd = ($base.tracker.cwd // $base.project.checkout)
    | reduce ("allowed_domains", "extra_write_paths", "deny_write_paths", "deny_read_paths") as $k
        (.; .sandbox[$k] = (($base.sandbox[$k] // []) + ($ov.sandbox[$k] // []) | unique))
  ' "$BASE" >"$ALL_DIR/config-$name.json" || { log "ABORT: could not build the config of $name"; exit 1; }
  [[ "$(jq -r '.project.name' "$ALL_DIR/config-$name.json")" == "$name" ]] \
    || { log "ABORT: projects.$name must set project.name to \"$name\""; exit 1; }
  names+=("$name")
done

# name<TAB>checkout, for the router.
PAPERCUTS_PROJECTS=""
for name in $names; do
  checkout="$(jq -r '.project.checkout' "$ALL_DIR/config-$name.json")"
  PAPERCUTS_PROJECTS+="$name"$'\t'"${checkout/#\~/$HOME}"$'\n'
done

log "=== multi-repo run start (mode=$MODE, projects: ${names[*]}, default: $DEFAULT) ==="

export PAPERCUTS_MULTI=1
export PAPERCUTS_PROJECTS
export PAPERCUTS_ROUTES="$ALL_DIR/routes.tsv"
export PAPERCUTS_DEFAULT_PROJECT="$DEFAULT"
export PAPERCUTS_SUMMARY="$ALL_DIR/summary.txt"
: >"$PAPERCUTS_SUMMARY"

# The default project goes first: it is the one that routes everything, and
# the one that receives what nobody else can place.
ordered=("$DEFAULT" ${names:#$DEFAULT})
for name in $ordered; do
  log "--- $name"
  PAPERCUTS_CONFIG="$ALL_DIR/config-$name.json" zsh "$HARNESS_DIR/bin/papercuts-daily.sh" "${@}"
  log "--- $name finished (exit $?)"
done

log "=== multi-repo run end ==="

# One notification for the whole pass, with a line per project, and the same
# lines in the journal. Per-project banners still fire for anything that needs
# a human (blocked, failed, work to publish); a quiet project only shows here.
summary="$(<"$PAPERCUTS_SUMMARY")"
journal="$(jq -r '.notify.journal // empty' "$BASE")"
if [[ "$(jq -r '.notify.enabled' "$BASE")" == "true" ]]; then
  if [[ -n "$journal" ]]; then
    journal="${${journal//\{date\}/$(date +%Y-%m-%d)}/#\~/$HOME}"
    mkdir -p "${journal:h}"
    { print -r -- "- $(date +%H:%M) **Paper cuts: all repositories done**"
      print -r -- "$summary" | sed 's/^/  - /'; } >>"$journal"
  fi
  if [[ "$(uname)" == "Darwin" ]]; then
    body="$(print -r -- "$summary" | cut -c1-80 | tr '\n' ';' | sed 's/"/\\"/g')"
    osascript -e "display notification \"$body\" with title \"Paper cuts: all repositories done\"" >>"$LOG" 2>&1
  fi
fi
