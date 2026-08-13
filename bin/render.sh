#!/bin/zsh
# render.sh <config.json> <run_dir>
#
# Materialises, for one run:
#   <run_dir>/prompt.md            prompts/orchestrator.md with {{PLACEHOLDERS}} filled
#   <run_dir>/sandbox-settings.json  the Claude Code settings that confine the run
#
# Rendering per run (instead of shipping a static settings file) keeps the
# containment honest: the paths and domains the agents get are exactly the ones
# in config.json, and both artefacts stay in the run dir as a record of what
# the run was actually allowed to do.

set -uo pipefail

CONFIG="${1:?usage: render.sh <config.json> <run_dir>}"
RUN_DIR="${2:?usage: render.sh <config.json> <run_dir>}"
HARNESS_DIR="${0:A:h:h}"

cfg() { jq -r "$1 // empty" "$CONFIG"; }
expand() { print -r -- "${1/#\~/$HOME}"; }

# --------------------------------------------------------------------------
# prompt.md
# --------------------------------------------------------------------------
scope_parent="$(cfg '.tracker.scope.parent')"
scope_label="$(cfg '.tracker.scope.label')"
if [[ -n "$scope_parent" && -n "$scope_label" ]]; then
  scope_desc="items under **$scope_parent** carrying the label \`$scope_label\`"
elif [[ -n "$scope_parent" ]]; then
  scope_desc="items under **$scope_parent**"
else
  scope_desc="items labelled \`$scope_label\`"
fi

checks_list="$(jq -r '.verify.checks // [] | map("`" + . + "`") | join(", ")' "$CONFIG")"
project="$(cfg '.project.name')"
checkout="$(expand "$(cfg '.project.checkout')")"
worktree_pattern="$(expand "$(cfg '.project.worktree_pattern')")"
worktree_pattern="${worktree_pattern//\{project\}/$project}"
env_sync="$(expand "$(cfg '.verify.env_sync')")"
env_sync="${env_sync//\{project\}/$project}"

template="$(<"$HARNESS_DIR/prompts/orchestrator.md")"

subst() { template="${template//$1/$2}"; }
subst '{{PROJECT}}'          "$project"
subst '{{REPO}}'             "$(cfg '.project.repo')"
subst '{{CHECKOUT}}'         "$checkout"
subst '{{BASE_BRANCH}}'      "$(cfg '.project.base_branch')"
subst '{{WORKTREE_PATTERN}}' "$worktree_pattern"
subst '{{BRANCH_PATTERN}}'   "$(cfg '.project.branch_pattern')"
subst '{{SCOPE_DESC}}'       "$scope_desc"
subst '{{SCOPE_PARENT}}'     "$scope_parent"
subst '{{MAX_ITEMS}}'        "$(cfg '.run.max_items')"
subst '{{WORKER_MODEL}}'     "$(cfg '.run.worker_model')"
subst '{{GITHUB_USER}}'      "$(cfg '.tracker.owner.github_user')"
subst '{{IN_PROGRESS}}'      "$(cfg '.tracker.statuses.in_progress // .tracker.in_progress_status')"
subst '{{IN_REVIEW}}'        "$(cfg '.tracker.statuses.in_review')"
subst '{{INSTALL_CMD}}'      "$(cfg '.verify.install')"
subst '{{HOOK_INSTALL}}'     "$(cfg '.verify.hook_install')"
subst '{{HOOK_PROBE}}'       "$(cfg '.verify.hook_probe')"
subst '{{ENV_SYNC}}'         "$env_sync"
subst '{{CHECKS}}'           "$checks_list"
subst '{{DRIFT_COMMIT}}'     "$(cfg '.verify.generated_drift_commit')"
subst '{{PR_LABELS}}'        "$(jq -r '.pull_request.labels // [] | join(", ") | if . == "" then "none" else . end' "$CONFIG")"

print -r -- "$template" >"$RUN_DIR/prompt.md"

# --------------------------------------------------------------------------
# sandbox-settings.json
# --------------------------------------------------------------------------
# Written with jq so the paths keep their real values (no placeholder left to
# expand at read time) and so an unreadable config fails here, loudly, rather
# than producing a settings file that silently allows more than intended.
home="$HOME"
jq -n \
  --arg home "$home" \
  --argjson cfg "$(cat "$CONFIG")" '
  def expand: if startswith("~") then ($home + .[1:]) else . end;

  ($cfg.sandbox.workspace_root | expand) as $ws
  | {
      permissions: {
        defaultMode: "acceptEdits",
        additionalDirectories: [$ws],
        # Absolute-path rules take a leading "//" and the expanded path already
        # starts with "/", so concatenate a single slash here — "///Users/..."
        # matches nothing.
        deny: (
          ($cfg.sandbox.deny_read_paths // [] | map("Read(/" + expand + "/**)")) +
          ($cfg.sandbox.deny_write_paths // [] | map("Edit(/" + expand + "/**)"))
        )
      },
      sandbox: {
        enabled: true,
        failIfUnavailable: true,
        autoAllowBashIfSandboxed: true,
        allowUnsandboxedCommands: false,
        enableWeakerNetworkIsolation: ($cfg.sandbox.weaker_network_isolation // false),
        network: {
          strictAllowlist: true,
          allowedDomains: ($cfg.sandbox.allowed_domains // [])
        },
        filesystem: {
          allowWrite: ([$ws] + ($cfg.sandbox.extra_write_paths // [] | map(expand))),
          denyWrite: ($cfg.sandbox.deny_write_paths // [] | map(expand)),
          denyRead: ($cfg.sandbox.deny_read_paths // [] | map(expand))
        }
      }
    }' >"$RUN_DIR/sandbox-settings.json" || exit 1

print -r -- "rendered $RUN_DIR/prompt.md and $RUN_DIR/sandbox-settings.json"
