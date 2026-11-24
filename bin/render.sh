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

# Repository-dependent steps of the worker brief. A repository without
# environment files, without git hooks or without a pre-push hook gets a step
# that says so, rather than a command that cannot work.
if [[ -n "$env_sync" ]]; then
  env_step="- **Environment files are gitignored, so a fresh worktree has none. Never
  hand-copy them between worktrees — that causes silent drift:**
  \`$env_sync\`"
else
  env_step="- This repository needs no environment files for its checks: do not
  create any."
fi

hook_probe="$(cfg '.verify.hook_probe')"
hook_install="$(cfg '.verify.hook_install')"
if [[ -n "$hook_probe" ]]; then
  hook_step="- **Then prove the git hooks will actually run, before writing any code:**
  \`$hook_probe\`
  git skips missing hooks *silently*, so without this your commits never see
  the commit linter and your push never runs the checks — while looking
  perfectly successful. If the probe fails, try \`$hook_install\` once and
  probe again. If it still fails, **stop and report it**: pushing unverified is
  not an option, and the blocker is worth more than the ticket.
  Do not try to create hook files by hand or to rewrite \`core.hooksPath\`: hooks
  are executable code that runs outside your sandbox, and an agent editing the
  mechanism that verifies it is exactly what nobody wants."
else
  hook_step="- This repository has no git hooks: nothing checks your commit for you.
  The checks below are the only gate before CI, so run them, all of them."
fi

package_checks="$(cfg '.verify.package_checks')"
[[ -n "$package_checks" ]] || package_checks="the repository checks ($checks_list) scoped to what you touched where they allow it"
single_test="$(cfg '.verify.single_test')"
[[ -n "$single_test" ]] || single_test="the test runner on that one file"

push_checks_list="$(jq -r '.verify.push_checks // [] | map("`" + . + "`") | join(", ")' "$CONFIG")"
if [[ -n "$push_checks_list" ]]; then
  push_checks="1. This repository has no pre-push hook that runs its checks, so you run
   them, in the worktree, after the rebase and before pushing: $push_checks_list.
   Push only when every one passes; a failure is classified as in step 3."
else
  push_checks=""
fi

repo_notes="$(jq -r '.verify.notes // [] | map("- " + .) | join("\n")' "$CONFIG")"
[[ -n "$repo_notes" ]] && repo_notes="$repo_notes"$'\n'

# Review gate between a worker returning and its item being published. The
# worker cannot run it itself: the review skill fans out to sub-agents, and a
# worker is already one. No `review` block, or no skill in it, means no gate.
review_skill="$(cfg '.review.skill')"
if [[ -n "$review_skill" ]]; then
  review_rounds="$(cfg '.review.max_fix_rounds')"
  [[ -n "$review_rounds" ]] || review_rounds=1
  review_advisors="$(jq -r '.review.advisors // [] | map("`" + . + "`") | join(", ")' "$CONFIG")"
  # A headless run loads agents from its own project only: one defined in a
  # parent directory (a .claude/agents shared by every repo under it) is
  # not there. So the definitions are read here and handed to claude with
  # --agents; an advisor whose file is missing is left out, and the prompt
  # tells the orchestrator to report it rather than improvise one.
  agents_dir="$(expand "$(cfg '.review.agents_dir')")"
  if [[ -n "$agents_dir" ]]; then
    agents_json='{}'
    for name in ${(f)"$(jq -r '.review.advisors // [] | .[]' "$CONFIG")"}; do
      file="$agents_dir/$name.md"
      [[ -f "$file" ]] || { print -r -- "render: advisor $name has no definition in $agents_dir" >&2; continue; }
      front="$(awk 'NR==1 && /^---$/ {f=1; next} f && /^---$/ {exit} f' "$file")"
      body="$(awk 'NR==1 && /^---$/ {f=1; next} f==1 && /^---$/ {f=2; next} f==2' "$file")"
      field() { print -r -- "$front" | sed -n "s/^$1:[[:space:]]*//p" | head -1; }
      agents_json="$(jq --arg n "$name" --arg d "$(field description)" --arg t "$(field tools)" \
        --arg m "$(field model)" --arg p "$body" '
        .[$n] = ({description: $d, prompt: $p}
          + (if $t != "" then {tools: ($t | split(",") | map(gsub("^ +| +$"; "")))} else {} end)
          + (if $m != "" then {model: $m} else {} end))' <<<"$agents_json")"
    done
    print -r -- "$agents_json" >"$RUN_DIR/agents.json"
  fi
  if [[ -n "$review_advisors" ]]; then
    advisor_step="3. **Advisory review.** Spawn, one at a time, each of these agents —
   Agent tool, \`subagent_type\` set to the name: $review_advisors. They are
   read-only, so brief each with paths, not with what you think of the change:
   the item key and title, \`\$PAPERCUTS_RUN_DIR/issues/<KEY>.json\`, the diff
   file and the worktree path. Ask one question: is this change safe to release
   on its own, what could it break, and how would anyone notice? Skip an
   advisor only when the diff gives it nothing to judge — a deployability
   reviewer on a pure styling change — and say so in the report. If an agent
   type is not available in this run, note it and go on: do not stand in for it
   with a general agent."
  else
    advisor_step="3. No advisory agents are configured: go on."
  fi
  review_phase="## Phase 2b — review each item before it can be published

Run this for each item **as soon as its worker returns, and before you spawn
the next one**: the worktree is quiet, and only one agent at a time ever works
in it. A branch an earlier run left unpublished (Phase 0) is reviewed the
same way before Phase 3 publishes it. An item whose worker stopped without
committing skips the review.
Rehearsals run it too: it needs no network.

1. \`mkdir -p \$PAPERCUTS_RUN_DIR/reviews\` and save the change:
   \`git -C <worktree> diff origin/{{BASE_BRANCH}}...HEAD > \$PAPERCUTS_RUN_DIR/reviews/<KEY>.diff\`.
2. **Code review.** \`cd <worktree>\` (the skill diffs \`HEAD\` of the current
   directory), then invoke the Skill tool with \`$review_skill\`. Nobody is
   there to answer its questions, so put in its arguments everything it would
   ask for: the fixed point \`origin/{{BASE_BRANCH}}\`; the spec, which is
   \`\$PAPERCUTS_RUN_DIR/issues/<KEY>.json\` — the tracker is unreachable from
   this run, so it must not try to fetch it; and that the run is unattended,
   so it reports findings instead of asking. Save what it returns to
   \`\$PAPERCUTS_RUN_DIR/reviews/<KEY>.md\`, then \`cd {{CHECKOUT}}\` again.
$advisor_step
4. **Judge the findings yourself**, one by one, against the diff and the
   ticket. A **defect** is something you would refuse to merge: wrong
   behaviour, an acceptance criterion missed, a rule the repository documents
   broken, a test that does not fail when the behaviour it covers is broken,
   a change that cannot be released alone. Everything else — preferences,
   optional improvements, work outside the ticket — is a **note**. The number
   of findings decides nothing; a reviewer that found nothing is not proof
   either, so read the diff.
5. **Defects go back to a worker**, in the same worktree: spawn a fresh agent
   (same type and model as the worker) with the item's brief, the defects
   verbatim with the evidence for each, and the same verbatim instructions.
   It fixes them in new commits, re-runs the checks and rewrites the PR file.
   Then review again from step 1. At most **$review_rounds** fix round(s) per
   item.
6. If a defect is still there after the last round, **do not publish the
   item**: it counts as committed but not pushed — queue a \`comment\` listing
   the open defects, \`assign\` and \`{{IN_PROGRESS}}\`, and say why in the
   report.
7. Append to the item's PR file a **Review** section: what the review and each
   advisor checked, what was fixed because of them, and the notes left open.
   That is where notes go — never as comments on the pull request.
"
else
  review_phase=""
fi

template="$(<"$HARNESS_DIR/prompts/orchestrator.md")"

subst() { template="${template//$1/$2}"; }
# First: the review phase carries placeholders of its own.
subst '{{REVIEW_PHASE}}'     "$review_phase"
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
subst '{{ENV_STEP}}'         "$env_step"
subst '{{HOOK_STEP}}'        "$hook_step"
subst '{{PACKAGE_CHECKS}}'   "$package_checks"
subst '{{SINGLE_TEST}}'      "$single_test"
subst '{{PUSH_CHECKS}}'      "$push_checks"
subst '{{REPO_NOTES}}'       "$repo_notes"
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
      # The sandbox only lets traffic out through its own proxy, advertised in
      # HTTP(S)_PROXY. Node ignores those variables unless told otherwise, so a
      # Node fetch (graphql-codegen in a pre-push hook) resolves the host
      # itself and fails with ENOTFOUND even for an allowed domain.
      env: {
        NODE_USE_ENV_PROXY: "1"
      },
      permissions: {
        defaultMode: "acceptEdits",
        additionalDirectories: [$ws],
        # autoAllowBashIfSandboxed is not enough on its own: headless Claude
        # Code still asks approval for some sandboxed commands (on 2026-11-04
        # `HUSKY=0 pnpm install --frozen-lockfile` got "This command requires
        # approval"), and with nobody to answer, the worker stops before it
        # can write a line. So every verify command the prompt hands the
        # worker is allowed by name, with and without its leading VAR=value
        # assignments. The sandbox still confines what they can write and
        # reach.
        allow: (
          [$cfg.verify.install, $cfg.verify.hook_install, $cfg.verify.hook_probe]
          + ($cfg.verify.checks // [])
          + ($cfg.verify.push_checks // [])
          # Command prefixes a worker needs in forms no check spells out, such
          # as `go test ./services/core/...` when only `go test ./...` is a check.
          + ($cfg.verify.extra_allow // [])
          | map(select(. != null and . != ""))
          | map(., sub("^([A-Za-z_][A-Za-z0-9_]*=[^ ]* +)+"; ""))
          | unique
          | map("Bash(" + . + ":*)")
        )
        # The review gate invokes one skill; headless, an unapproved Skill call
        # would wait for an answer nobody gives.
        + (if ($cfg.review.skill // "") != "" then ["Skill(" + $cfg.review.skill + ")"] else [] end),
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
          allowLocalBinding: ($cfg.sandbox.allow_local_binding // false),
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
