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
#   PC_EXCLUDE_LABELS (space separated), PC_STATUS_IN_PROGRESS,
#   PC_STATUS_IN_REVIEW, PC_REPO, PC_CHECKOUT

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

# ---------------------------------------------------------------------------
# Neither CLI's exit code is evidence.
#
# `thomctl issue comment`, `acli … assign` and `acli … transition` all print
# "✗ Failure: <KEY> can't be transitioned: …" on stdout and **exit 0**. Trusting
# the status code logs "OK transition" for a transition that never happened —
# the same shape of defect as a git hook that is not installed: it looks exactly
# like success. So every write is confirmed by reading the item back afterwards.
# ---------------------------------------------------------------------------
item_status()   { acli jira workitem view "$1" --fields status   --json 2>/dev/null | jq -r '.fields.status.name // empty'; }
item_assignee() { acli jira workitem view "$1" --fields assignee --json 2>/dev/null | jq -r '.fields.assignee.emailAddress // .fields.assignee.displayName // empty'; }
comment_count() { acli jira workitem view "$1" --fields comment  --json 2>/dev/null | jq -r '.fields.comment.comments | length' 2>/dev/null; }

dry() { [[ "${PAPERCUTS_DRY_JIRA:-0}" == "1" ]]; }

run_jira() {
  if dry; then
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
        if dry; then
          run_jira thomctl issue comment "$key" -f "$body_file"
        else
          before=$(comment_count "$key")
          thomctl issue comment "$key" -f "$body_file" >/dev/null 2>&1
          after=$(comment_count "$key")
          if [[ -n "$before" && -n "$after" && "$after" -gt "$before" ]]; then
            jlog "OK comment $key (comments $before -> $after)"
          else
            jlog "FAIL comment $key (comment count stayed at ${before:-unknown} — nothing was posted)"
          fi
        fi
        ;;

      assign)
        is_eligible "$key" || { jlog "REJECT assign: $key not eligible"; continue; }
        if dry; then
          run_jira acli jira workitem assign --key "$key" --assignee "$PC_TRACKER_EMAIL"
        else
          acli jira workitem assign --key "$key" --assignee "$PC_TRACKER_EMAIL" >/dev/null 2>&1
          now=$(item_assignee "$key")
          if [[ "$now" == "$PC_TRACKER_EMAIL" || "$now" == "$PC_TRACKER_USER" ]]; then
            jlog "OK assign $key -> $now"
          else
            jlog "FAIL assign $key (assignee is '${now:-none}', not $PC_TRACKER_EMAIL)"
          fi
        fi
        ;;

      transition)
        want=$(jq -r '.status // empty' <<<"$line")
        pr=$(jq -r '.pr // empty' <<<"$line")
        is_eligible "$key" || { jlog "REJECT transition: $key not eligible"; continue; }

        # Two allowed destinations, and nothing else: a run can never mark an
        # item Done, reopen one, or invent a status. The review one additionally
        # demands evidence — see below.
        case "$want" in
          "${PC_STATUS_IN_PROGRESS:-__unset__}")
            ;;
          "${PC_STATUS_IN_REVIEW:-__unset__}")
            # A review transition is a claim that a pull request exists. The
            # agents cannot be trusted for that (a stalled run once queued one
            # with nothing pushed), and neither can a URL they typed: check it.
            if [[ -z "$pr" ]]; then
              jlog "REJECT transition $key -> $want: no pr field, and this status is only reachable with a pull request"; continue
            fi
            # Anchored at both ends, digits only. A glob like `pull/[0-9]*`
            # is not enough: `pull/1387/../../evil` matches it, and `gh` happily
            # normalises that back to PR 1387 — so a URL that is not a pull
            # request URL would pass the check by borrowing a real PR's number.
            if ! [[ "$pr" =~ ^https://github\.com/"$PC_REPO"/pull/[0-9]+$ ]]; then
              jlog "REJECT transition $key -> $want: pr '$pr' is not a pull request URL under $PC_REPO"; continue
            fi
            if [[ "${PAPERCUTS_DRY_JIRA:-0}" == "1" ]]; then
              jlog "DRY: would verify $pr before transitioning $key -> $want"
            else
              pr_state=$(gh pr view "$pr" --json state --jq '.state' 2>/dev/null)
              if [[ -z "$pr_state" ]]; then
                jlog "REJECT transition $key -> $want: $pr does not exist or is unreadable"; continue
              fi
              if [[ "$pr_state" != "OPEN" && "$pr_state" != "MERGED" ]]; then
                jlog "REJECT transition $key -> $want: $pr is $pr_state"; continue
              fi
              jlog "verified $pr is $pr_state"
            fi
            ;;
          *)
            jlog "REJECT transition $key: status '$want' not allowed (only '${PC_STATUS_IN_PROGRESS:-none}' and '${PC_STATUS_IN_REVIEW:-none}')"; continue
            ;;
        esac

        if dry; then
          run_jira acli jira workitem transition --key "$key" --status "$want" --yes
        else
          was=$(item_status "$key")
          acli jira workitem transition --key "$key" --status "$want" --yes >/dev/null 2>&1
          now=$(item_status "$key")
          if [[ "$now" == "$want" ]]; then
            jlog "OK transition $key -> $want"
          else
            # Usually the workflow does not allow this jump from where the item
            # currently sits. Name both statuses: that is the whole diagnosis,
            # and it saves opening the board to find it.
            jlog "FAIL transition $key -> $want (item is still in '${now:-unknown}'; the workflow may not allow that jump from '${was:-unknown}')"
          fi
        fi
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
