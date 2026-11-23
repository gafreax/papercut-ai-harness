#!/bin/zsh
# uninstall.sh — unload the scheduled run and remove its launchd plist.
#
# Leaves .state/ (logs, run directories) alone: it is the record of what the
# harness did, and deleting it is a separate decision.

set -uo pipefail

HARNESS_DIR="${0:A:h:h}"
CONFIG="${PAPERCUTS_CONFIG:-$HARNESS_DIR/config/config.json}"
LABEL="ai.papercuts.$(jq -r '.project.name' "$CONFIG" 2>/dev/null || print -r -- unknown)"
[[ -f "$HARNESS_DIR/config/projects.json" ]] && LABEL="ai.papercuts.all"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

if launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
  launchctl bootout "gui/$(id -u)/$LABEL" && print -r -- "unloaded $LABEL"
else
  print -r -- "$LABEL was not loaded"
fi

if [[ -f "$PLIST" ]]; then
  rm "$PLIST" && print -r -- "removed $PLIST"
fi

PF_LABEL="ai.papercuts.preflight"
launchctl bootout "gui/$(id -u)/$PF_LABEL" 2>/dev/null && print -r -- "unloaded $PF_LABEL"
[[ -f "$HOME/Library/LaunchAgents/$PF_LABEL.plist" ]] \
  && rm "$HOME/Library/LaunchAgents/$PF_LABEL.plist" && print -r -- "removed $PF_LABEL.plist"

print -r -- "run directories and logs kept in $HARNESS_DIR/.state/"
