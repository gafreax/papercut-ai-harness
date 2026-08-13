#!/bin/zsh -l
# papercuts-daily.sh — one unattended pass over the paper-cut backlog.
#
# An orchestrator model picks a few genuinely small tickets, delegates each to
# a worker agent in its own git worktree, and leaves reviewable pull requests.
# The agents run sandboxed; this script is the unsandboxed broker around them:
#
#   before  — dumps the tracker (the agents cannot authenticate, by design)
#   during  — hands down a GitHub token so push and `gh` work inside the sandbox
#   after   — replays the tracker actions the agents queued, validating each
#
# Everything project-specific comes from config/config.json. See
# docs/HOW-IT-WORKS.md for why it is shaped this way.
#
# Modes:
#   (none)         full run: agents work, push, open PRs, tracker is updated
#   --dry          rehearsal: agents do the real work but CANNOT publish — the
#                  GitHub token is withheld, so push and `gh` fail by
#                  construction rather than by good behaviour — and tracker
#                  actions are only logged
#   --replay-only  skip dump and agents; only execute the queued actions of an
#                  existing run dir (override with PAPERCUTS_RUN_DIR)
#
# Shebang is `zsh -l` on purpose: launchd starts jobs with a bare environment,
# so the login profile is what puts node/pnpm, the tracker CLIs and gh on PATH.

set -uo pipefail

MODE="${1:-full}"

HARNESS_DIR="${0:A:h:h}"
CONFIG="${PAPERCUTS_CONFIG:-$HARNESS_DIR/config/config.json}"

# PAPERCUTS_DRY_JIRA only silences the tracker broker. On a full run that would
# be a trap: the agents would still push branches and open real PRs while the
# name suggests nothing happens. Only --dry, which also withholds the token,
# may set it alongside an agent run.
if [[ "${PAPERCUTS_DRY_JIRA:-0}" == "1" && "$MODE" == "full" ]]; then
  print -r -- "PAPERCUTS_DRY_JIRA only suppresses tracker writes — the agents would still push and open PRs. Use --dry for a rehearsal, or --replay-only to test the broker." >&2
  exit 2
fi

[[ -f "$CONFIG" ]] || { print -r -- "no config at $CONFIG — copy config/config.example.json and edit it (or run the activate-papercuts skill)" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || { print -r -- "jq is required" >&2; exit 1; }

# --------------------------------------------------------------------------
# Config
# --------------------------------------------------------------------------
cfg() { jq -r "$1 // empty" "$CONFIG"; }
cfg_arr() { jq -r "$1 // [] | .[]" "$CONFIG"; }
expand() { print -r -- "${1/#\~/$HOME}"; }

PROJECT_NAME="$(cfg '.project.name')"
CHECKOUT="$(expand "$(cfg '.project.checkout')")"
MAX_ITEMS="$(cfg '.run.max_items')"
ORCH_MODEL="$(cfg '.run.orchestrator_model')"
WORKER_MODEL="$(cfg '.run.worker_model')"
TURBO_CONCURRENCY="$(cfg '.run.turbo_concurrency')"
TRACKER_KIND="$(cfg '.tracker.kind')"
WORKSPACE_ROOT="$(expand "$(cfg '.sandbox.workspace_root')")"

TRACKER="$HARNESS_DIR/trackers/${TRACKER_KIND}.sh"
[[ -f "$TRACKER" ]] || { print -r -- "unknown tracker kind '$TRACKER_KIND' (no $TRACKER)" >&2; exit 1; }

STATE_DIR="${PAPERCUTS_STATE_DIR:-$HARNESS_DIR/.state}"
LOG_DIR="$STATE_DIR/logs"
mkdir -p "$LOG_DIR"
TODAY="$(date +%Y-%m-%d)"
LOG="$LOG_DIR/papercuts-$TODAY.log"
RUN_DIR="${PAPERCUTS_RUN_DIR:-$STATE_DIR/runs/$TODAY}"
LOCK="$STATE_DIR/.lock"

log() { print -r -- "[$(date +%H:%M:%S)] $*" >>"$LOG"; }

# A run that fails at 06:00 and says nothing is indistinguishable from a run
# that never happened — which is how three days of blocked work went unnoticed.
# Every run ends with a notification, success or not.
notify() {
  local title="$1" body="$2"
  [[ "$(cfg '.notify.enabled')" == "true" ]] || return 0
  local custom="$(cfg '.notify.command')"
  if [[ -n "$custom" ]]; then
    PC_TITLE="$title" PC_BODY="$body" sh -c "$custom" >>"$LOG" 2>&1
  elif [[ "$(uname)" == "Darwin" ]]; then
    # osascript needs its own quotes escaped, and a stray one silently drops
    # the whole notification.
    local t="${title//\"/\\\"}" b="${body//\"/\\\"}"
    osascript -e "display notification \"$b\" with title \"$t\"" >>"$LOG" 2>&1
  fi
}

# One run at a time: a previous run still chewing through worktrees must not be
# joined by a second one.
if ! mkdir "$LOCK" 2>/dev/null; then
  log "SKIP: a previous run still holds $LOCK"
  exit 0
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT INT TERM

log "=== run start (mode=$MODE, project=$PROJECT_NAME, tracker=$TRACKER_KIND) ==="

# Belt and braces on PATH. install.sh freezes the installing shell's PATH into
# the plist, but a job started another way (or a profile that moved) can still
# arrive without the directories that hold the toolchain: `zsh -l` skips .zshrc
# when non-interactive, which is where version-manager shims usually live.
for extra in "$HOME/bin" "$HOME/.local/bin" /opt/homebrew/bin /usr/local/bin; do
  [[ -d "$extra" && ":$PATH:" != *":$extra:"* ]] && PATH="$extra:$PATH"
done
export PATH

# The tracker CLI is required too, but only the adapter knows its name.
required=(claude git gh jq)
[[ "$TRACKER_KIND" == "jira" ]] && required+=(thomctl acli)
for bin in $required; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    log "ABORT: $bin not found on PATH"
    log "       PATH was: $PATH"
    notify "Paper cuts: run aborted" "$bin not found on PATH"
    log "       If this ran from launchd, reinstall with bin/install.sh from an interactive shell that can see $bin."
    exit 1
  fi
done

cd "$CHECKOUT" || { log "ABORT: checkout $CHECKOUT not found"; notify "Paper cuts: run aborted" "checkout not found: $CHECKOUT"; exit 1; }

# Config the tracker adapter reads from the environment.
export PC_CHECKOUT="$CHECKOUT"
export PC_TRACKER_PARENT="$(cfg '.tracker.scope.parent')"
export PC_TRACKER_LABEL="$(cfg '.tracker.scope.label')"
export PC_TRACKER_USER="$(cfg '.tracker.owner.tracker_user')"
export PC_TRACKER_EMAIL="$(cfg '.tracker.owner.tracker_email')"
export PC_IN_PROGRESS_STATUS="$(cfg '.tracker.in_progress_status')"
export PC_EXCLUDE_LABELS="$(cfg_arr '.tracker.exclude_labels' | tr '\n' ' ')"

agent_status=0
if [[ "$MODE" == "--replay-only" ]]; then
  log "replay-only: skipping the tracker dump and the agent run, brokering $RUN_DIR"
  [[ -f "$RUN_DIR/eligible.txt" ]] || { log "ABORT: no eligible.txt in $RUN_DIR"; exit 1; }
else

# Pin core.hooksPath to an absolute path, every run, from out here where we are
# allowed to write .git/config.
#
# Worktrees share the main checkout's config, and hook installers rewrite that
# key to a RELATIVE path on every install — which then resolves against each
# worktree, where the hook directory does not exist. Git skips missing hooks
# *silently*, so the result is pushes that run no checks and look successful.
# An absolute value makes every worktree inherit the hooks that do exist; the
# agents install with the installer disabled so they cannot undo it.
hooks_path="$(cfg '.verify.hooks_path')"
if [[ -n "$hooks_path" ]]; then
  hooks_path="$(expand "${hooks_path//\{checkout\}/$CHECKOUT}")"
  if [[ -d "$hooks_path" ]]; then
    current="$(git config --get core.hooksPath 2>/dev/null)"
    if [[ "$current" != "$hooks_path" ]]; then
      git config core.hooksPath "$hooks_path" \
        && log "pinned core.hooksPath: '$current' -> '$hooks_path'" \
        || log "WARN: could not pin core.hooksPath (hooks may not run in worktrees)"
    fi
  else
    log "WARN: verify.hooks_path does not exist ($hooks_path) — hooks will not run in fresh worktrees"
  fi
fi

git fetch origin --prune >>"$LOG" 2>&1 || log "WARN: git fetch failed, continuing"

mkdir -p "$RUN_DIR/issues" "$RUN_DIR/jira-actions" "$RUN_DIR/slices" "$RUN_DIR/comments" "$RUN_DIR/pr-bodies"

# `gh pr create --label` fails outright when the label does not exist, losing
# an otherwise finished PR at the last step. Create them here, from outside the
# sandbox, rather than making the agents handle it.
repo="$(cfg '.project.repo')"
for label in $(cfg_arr '.pull_request.labels'); do
  if ! gh label list -R "$repo" --limit 200 2>/dev/null | grep -qF "$label"; then
    gh label create "$label" -R "$repo" --color D4C5F9 \
      --description "Opened by the unattended paper-cut run" >>"$LOG" 2>&1 \
      && log "created missing label: $label" \
      || log "WARN: could not create label '$label' — PRs asking for it will fail"
  fi
done

# Snapshot of remote branches, to tell afterwards what this run actually
# published rather than trusting the report's own account of itself.
git ls-remote --heads origin 2>/dev/null | awk '{print $2}' | sort >"$RUN_DIR/refs-before.txt"

# --------------------------------------------------------------------------
# Before the run: dump the tracker
# --------------------------------------------------------------------------
# The agents are sandboxed and the tracker CLIs authenticate from the keyring,
# which the sandbox blocks. So everything they need to READ is dumped here;
# everything they want to WRITE goes through the broker at the bottom.
if ! zsh "$TRACKER" dump "$RUN_DIR" >>"$LOG" 2>&1; then
  log "ABORT: tracker dump failed (is the CLI authenticated?)"
  notify "Paper cuts: run aborted" "tracker dump failed — is the CLI still authenticated?"
  exit 1
fi

eligible_count=$(wc -l <"$RUN_DIR/eligible.txt" | tr -d ' ')
log "eligible candidates: $eligible_count ($(tr '\n' ' ' <"$RUN_DIR/eligible.txt"))"
if [[ "$eligible_count" -eq 0 ]]; then
  log "nothing eligible today — not starting the agent"
  notify "Paper cuts: nothing to do" "No eligible item in the backlog today."
  exit 0
fi

# --------------------------------------------------------------------------
# Materialise the prompt and the sandbox settings for this run
# --------------------------------------------------------------------------
"$HARNESS_DIR/bin/render.sh" "$CONFIG" "$RUN_DIR" >>"$LOG" 2>&1 || { log "ABORT: could not render prompt/settings"; notify "Paper cuts: run aborted" "could not render prompt/settings"; exit 1; }

export TURBO_CONCURRENCY="${TURBO_CONCURRENCY:-2}"

# gh and git read their credentials from the macOS keyring, which the sandbox
# blocks by design. This script is NOT sandboxed, so it reads the token once
# and hands it down: gh picks up GH_TOKEN, git gets a credential helper via
# GIT_CONFIG_* (no global git config is touched).
if [[ "$MODE" == "--dry" ]]; then
  # The rehearsal withholds the token on purpose: without it nothing inside the
  # sandbox can reach GitHub with write rights, so "do not push" is enforced by
  # the absence of credentials instead of by the agents' obedience.
  export PAPERCUTS_NO_PUBLISH=1
  export PAPERCUTS_DRY_JIRA=1
  log "dry run: no GitHub token exported, tracker actions will only be logged"
else
  GH_TOKEN="$(gh auth token 2>/dev/null)"
  if [[ -z "$GH_TOKEN" ]]; then
    log "ABORT: could not read a gh token (is the login keyring unlocked?)"
    notify "Paper cuts: run aborted" "no GitHub token — is the login keyring unlocked?"
    exit 1
  fi
  export GH_TOKEN
  export GIT_CONFIG_COUNT=1
  export GIT_CONFIG_KEY_0=credential.helper
  export GIT_CONFIG_VALUE_0='!f() { test "$1" = get && printf "username=x-access-token\npassword=%s\n" "$GH_TOKEN"; }; f'
fi

export PAPERCUTS_RUN_DIR="$RUN_DIR"
export PAPERCUTS_WORKER_MODEL="$WORKER_MODEL"
export PAPERCUTS_MAX_ITEMS="$MAX_ITEMS"

# Containment, not trust: the rendered settings turn the sandbox on with
# failIfUnavailable, confine writes to the workspace root and forbid escaping
# via dangerouslyDisableSandbox. acceptEdits + additionalDirectories keeps the
# file tools inside the workspace too — no bypassPermissions anywhere.
claude -p "$(<"$RUN_DIR/prompt.md")" \
  --model "$ORCH_MODEL" \
  --settings "$RUN_DIR/sandbox-settings.json" \
  --permission-mode acceptEdits \
  --add-dir "$WORKSPACE_ROOT" \
  >>"$LOG" 2>&1
agent_status=$?
log "agent run finished (exit $agent_status)"

fi  # end of the full-run block skipped by --replay-only

# --------------------------------------------------------------------------
# After the run: replay the queued tracker actions
# --------------------------------------------------------------------------
zsh "$TRACKER" replay "$RUN_DIR" >>"$LOG" 2>&1
log "tracker replay done — outcomes in $RUN_DIR/jira-actions.log"

# --------------------------------------------------------------------------
# Outcome: what got out, and what is stuck
# --------------------------------------------------------------------------
published=0
if [[ -f "$RUN_DIR/refs-before.txt" ]]; then
  git ls-remote --heads origin 2>/dev/null | awk '{print $2}' | sort >"$RUN_DIR/refs-after.txt"
  published=$(comm -13 "$RUN_DIR/refs-before.txt" "$RUN_DIR/refs-after.txt" | wc -l | tr -d ' ')
fi

# Worktrees holding commits that never reached the remote. This is the state the
# job sat in for three days without telling anyone: work done, nothing shipped.
typeset -a pending
wt_glob="$(expand "$(cfg '.project.worktree_pattern')")"
wt_glob="${wt_glob//\{project\}/$PROJECT_NAME}"
wt_glob="${wt_glob//\{key\}/*}"
setopt NULL_GLOB
# Only branches this job would have created. The worktree glob also matches the
# human's own worktrees next to them, and reporting their unpushed work as "the
# job has something to publish" would make the notification untrustworthy — the
# one thing it cannot afford to be.
branch_re="^$(cfg '.project.branch_pattern')"
branch_re="${branch_re//\{key\}/[A-Z]+-[0-9]+}"
branch_re="${branch_re//\{slug\}/.+}"

for d in ${~wt_glob}; do
  [[ -e "$d/.git" ]] || continue
  branch="$(git -C "$d" branch --show-current 2>/dev/null)" || continue
  [[ -n "$branch" ]] || continue
  [[ "$branch" =~ $branch_re ]] || continue
  if git -C "$d" rev-parse --verify -q "origin/$branch" >/dev/null 2>&1; then
    ahead=$(git -C "$d" rev-list --count "origin/$branch..HEAD" 2>/dev/null || print 0)
  else
    ahead=$(git -C "$d" rev-list --count "origin/$(cfg '.project.base_branch')..HEAD" 2>/dev/null || print 0)
  fi
  (( ahead > 0 )) && pending+=("$branch")
done

summary="published: $published, pending: ${#pending}"
[[ ${#pending} -gt 0 ]] && log "UNPUBLISHED WORK: ${pending[*]}"
log "outcome — $summary"

if [[ $agent_status -ne 0 ]]; then
  notify "Paper cuts: run failed" "exit $agent_status. See $LOG"
elif [[ ${#pending} -gt 0 ]]; then
  notify "Paper cuts: ${#pending} branch(es) to publish" \
         "${pending[*]} — committed but not pushed. $published PR opened."
elif [[ "$published" -gt 0 ]]; then
  notify "Paper cuts: $published PR opened" "All work published. Nothing pending."
else
  notify "Paper cuts: nothing to do" "No eligible quick win today. Run OK."
fi

log "=== run end (exit $agent_status) ==="
exit $agent_status
