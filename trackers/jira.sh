#!/bin/zsh
# Jira adapter — see trackers/README.md for the contract.
#
# Reads Jira through `thomctl` (the repo's own wrapper: PRD / sub-issue verbs,
# markdown bodies) and falls back to `acli` for assign/transition, which
# thomctl does not expose. Both authenticate from the login keyring, which is
# why this runs in the runner and never inside the agent sandbox.
#
# Invoked as: jira.sh dump <run_dir> | jira.sh replay <run_dir>
# Configuration arrives through the environment, exported by bin/papercuts-daily.sh:
#   PC_TRACKER_PARENT, PC_TRACKER_LABEL, PC_TRACKER_USER, PC_TRACKER_EMAIL,
#   PC_EXCLUDE_LABELS (space separated), PC_IN_PROGRESS_STATUS, PC_CHECKOUT

set -uo pipefail

verb="${1:-}"
run_dir="${2:-}"

[[ -n "$verb" && -n "$run_dir" ]] || { print -r -- "usage: jira.sh <dump|replay> <run_dir>" >&2; exit 2; }

# thomctl resolves its config by walking up from the cwd, so every call has to
# happen inside the project checkout — not in the harness directory.
cd "$PC_CHECKOUT" || { print -r -- "jira.sh: cannot cd into $PC_CHECKOUT" >&2; exit 1; }

jlog() { print -r -- "[$(date +%H:%M:%S)] $*" | tee -a "$run_dir/jira-actions.log"; }

# --------------------------------------------------------------------------
# dump
# --------------------------------------------------------------------------
if [[ "$verb" == "dump" ]]; then
  mkdir -p "$run_dir/issues"

  if [[ -n "${PC_TRACKER_PARENT:-}" ]]; then
    thomctl issue list --parent "$PC_TRACKER_PARENT" --json >"$run_dir/candidates.json" || exit 1
  else
    thomctl issue list --json >"$run_dir/candidates.json" || exit 1
  fi

  # Labels the owner has declared off-limits (typically `hitl`: a human has to
  # look first). thomctl filters by label, so ask it once per label and
  # subtract the union.
  : >"$run_dir/excluded.txt"
  for label in ${=PC_EXCLUDE_LABELS:-}; do
    if [[ -n "${PC_TRACKER_PARENT:-}" ]]; then
      thomctl issue list --parent "$PC_TRACKER_PARENT" --label "$label" --json 2>/dev/null
    else
      thomctl issue list --label "$label" --json 2>/dev/null
    fi | jq -r '.[].key' >>"$run_dir/excluded.txt"
  done

  # Eligible = unassigned or the owner's, minus the excluded labels. This file
  # is the authorisation list `replay` validates against.
  jq -r --arg me "$PC_TRACKER_USER" \
    '.[] | select(.assignee == null or .assignee == $me) | .key' \
    "$run_dir/candidates.json" \
    | { grep -vxF -f "$run_dir/excluded.txt" || true; } >"$run_dir/eligible.txt"

  while read -r key; do
    [[ -z "$key" ]] && continue
    thomctl issue view "$key" --json >"$run_dir/issues/$key.json" 2>/dev/null \
      || print -r -- "jira.sh: could not dump $key" >&2
  done <"$run_dir/eligible.txt"

  print -r -- "$(wc -l <"$run_dir/eligible.txt" | tr -d ' ') eligible"
  exit 0
fi

# --------------------------------------------------------------------------
# replay
# --------------------------------------------------------------------------
if [[ "$verb" != "replay" ]]; then
  print -r -- "jira.sh: unknown verb '$verb'" >&2
  exit 2
fi

[[ -f "$run_dir/eligible.txt" ]] || { print -r -- "jira.sh: no eligible.txt in $run_dir" >&2; exit 1; }

is_eligible() { grep -qxF "$1" "$run_dir/eligible.txt"; }

run_jira() {
  if [[ "${PAPERCUTS_DRY_JIRA:-0}" == "1" ]]; then
    jlog "DRY: $*"
    return 0
  fi
  "$@" >/dev/null 2>&1
}

setopt NULL_GLOB
for f in "$run_dir"/jira-actions/*.jsonl; do
  while read -r line; do
    [[ -z "$line" ]] && continue
    if ! action=$(jq -r '.action // empty' <<<"$line" 2>/dev/null); then
      jlog "REJECT (unparseable): $line"
      continue
    fi
    key=$(jq -r '.key // empty' <<<"$line")

    case "$action" in
      comment)
        body_file=$(jq -r '.body_file // empty' <<<"$line")
        is_eligible "$key" || { jlog "REJECT comment: $key not eligible"; continue; }
        if [[ ! -f "$body_file" || "$body_file" != "$run_dir"/* ]]; then
          jlog "REJECT comment on $key: body_file outside the run dir or missing"; continue
        fi
        run_jira thomctl issue comment "$key" -f "$body_file" \
          && jlog "OK comment $key" || jlog "FAIL comment $key"
        ;;

      assign)
        is_eligible "$key" || { jlog "REJECT assign: $key not eligible"; continue; }
        run_jira acli jira workitem assign --key "$key" --assignee "$PC_TRACKER_EMAIL" \
          && jlog "OK assign $key -> $PC_TRACKER_EMAIL" || jlog "FAIL assign $key"
        ;;

      transition)
        want=$(jq -r '.status // empty' <<<"$line")
        is_eligible "$key" || { jlog "REJECT transition: $key not eligible"; continue; }
        if [[ "$want" != "$PC_IN_PROGRESS_STATUS" ]]; then
          jlog "REJECT transition $key: status '$want' not allowed"; continue
        fi
        run_jira acli jira workitem transition --key "$key" --status "$want" --yes \
          && jlog "OK transition $key -> $want" || jlog "FAIL transition $key (status probably unreachable)"
        ;;

      create-slice)
        title=$(jq -r '.title // empty' <<<"$line")
        body_file=$(jq -r '.body_file // empty' <<<"$line")
        mode=$(jq -r '.mode // "hitl"' <<<"$line")
        relates=$(jq -r '.relates_to // empty' <<<"$line")
        if [[ -z "$title" || ! -f "$body_file" || "$body_file" != "$run_dir"/* ]]; then
          jlog "REJECT create-slice: missing title or body_file outside the run dir"; continue
        fi
        if [[ -n "$relates" ]] && ! is_eligible "$relates"; then
          jlog "REJECT create-slice: relates_to $relates not eligible"; continue
        fi
        [[ "$mode" == "afk" ]] && flag="--afk" || flag="--hitl"
        if [[ "${PAPERCUTS_DRY_JIRA:-0}" == "1" ]]; then
          jlog "DRY: thomctl issue create --parent $PC_TRACKER_PARENT --title '$title' -f $body_file $flag (then link relates-to ${relates:-none})"
          continue
        fi
        new=$(thomctl issue create --parent "$PC_TRACKER_PARENT" --title "$title" \
                -f "$body_file" $flag --json 2>/dev/null | jq -r '.key // empty')
        if [[ -n "$new" ]]; then
          jlog "OK create-slice $new ($title)"
          if [[ -n "$relates" ]]; then
            thomctl issue link add "$new" --relates-to "$relates" >/dev/null 2>&1 \
              && jlog "OK link $new relates-to $relates" \
              || jlog "FAIL link $new relates-to $relates"
          fi
        else
          jlog "FAIL create-slice ($title)"
        fi
        ;;

      *)
        jlog "REJECT: unknown action '$action'"
        ;;
    esac
  done <"$f"
done
