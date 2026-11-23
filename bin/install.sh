#!/bin/zsh
# install.sh — schedule the daily run with launchd (macOS).
#
# Generates the plist from config.json (so the schedule lives in one place),
# installs it, and loads it. Run it with `zsh bin/install.sh` — no chmod needed
# to get started.
#
# Uninstall: zsh bin/uninstall.sh

set -uo pipefail

HARNESS_DIR="${0:A:h:h}"
CONFIG="${PAPERCUTS_CONFIG:-$HARNESS_DIR/config/config.json}"
LABEL="ai.papercuts.$(jq -r '.project.name' "$CONFIG" 2>/dev/null || print -r -- unknown)"
RUNNER="$HARNESS_DIR/bin/papercuts-daily.sh"
# With a project list, one job runs every repository in series
# (bin/papercuts-all.sh) and replaces the single-project job, which is removed
# so the same repository is not run twice a day.
if [[ -f "$HARNESS_DIR/config/projects.json" ]]; then
  SINGLE_LABEL="$LABEL"
  LABEL="ai.papercuts.all"
  RUNNER="$HARNESS_DIR/bin/papercuts-all.sh"
  CONFIG="$HARNESS_DIR/$(jq -r '.base // "config/config.json"' "$HARNESS_DIR/config/projects.json")"
  if [[ -f "$HOME/Library/LaunchAgents/$SINGLE_LABEL.plist" ]]; then
    launchctl bootout "gui/$(id -u)/$SINGLE_LABEL" 2>/dev/null
    rm -f "$HOME/Library/LaunchAgents/$SINGLE_LABEL.plist"
    print -r -- "removed the single-project job $SINGLE_LABEL"
  fi
fi
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

[[ -f "$CONFIG" ]] || { print -r -- "no config at $CONFIG — copy config/config.example.json and edit it first" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { print -r -- "jq is required" >&2; exit 1; }

schedule="$(jq -r '.run.schedule // "06:00"' "$CONFIG")"
hour="${schedule%%:*}"
minute="${schedule##*:}"
hour="${hour#0}"; minute="${minute#0}"
: "${hour:=0}"; : "${minute:=0}"

if ! [[ "$hour" =~ '^[0-9]+$' && "$minute" =~ '^[0-9]+$' ]] || (( hour > 23 || minute > 59 )); then
  print -r -- "run.schedule must be HH:MM local time, got '$schedule'" >&2
  exit 1
fi

chmod +x "$RUNNER" "$HARNESS_DIR/bin/papercuts-daily.sh" "$HARNESS_DIR/bin/render.sh" "$HARNESS_DIR/bin/route.sh" 2>/dev/null
mkdir -p "$HOME/Library/LaunchAgents" "$HARNESS_DIR/.state/logs"

# RunAtLoad stays false: installing the job should never be the thing that
# starts opening pull requests. If the Mac is asleep at the scheduled time,
# launchd runs the job when it wakes.
cat >"$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>$RUNNER</string>
	</array>
	<key>WorkingDirectory</key>
	<string>$HARNESS_DIR</string>
	<key>StartCalendarInterval</key>
	<dict>
		<key>Hour</key>
		<integer>$hour</integer>
		<key>Minute</key>
		<integer>$minute</integer>
	</dict>
	<!-- The PATH of the shell that ran install.sh, frozen in.
	     launchd starts jobs with a minimal environment, and \`zsh -l\` does NOT
	     read .zshrc when it is non-interactive — so anything added to PATH
	     there (~/bin, version-manager shims) is invisible to the job. That is
	     not hypothetical: three consecutive runs of the first version of this
	     harness aborted at 06:00 with "thomctl not found on PATH". -->
	<key>EnvironmentVariables</key>
	<dict>
		<key>PATH</key>
		<string>$PATH</string>
	</dict>
	<key>RunAtLoad</key>
	<false/>
	<key>StandardOutPath</key>
	<string>$HARNESS_DIR/.state/logs/launchd.out.log</string>
	<key>StandardErrorPath</key>
	<string>$HARNESS_DIR/.state/logs/launchd.err.log</string>
	<!-- Standard, not Background. Background confines the job and every
	     process it starts to the efficiency cores with throttled CPU and I/O,
	     and the pre-push hook runs the whole unit suite from inside the job:
	     measured on 2026-11-20, a monorepo unit suite took 391 s with 29 tests
	     past their 5 s timeout under Background, against 43 s and none under
	     Standard. Every push of 2026-11-19/20 failed that way. -->
	<key>ProcessType</key>
	<string>Standard</string>
	<!-- Nice 10 still lets the human's own work go first, but unlike
	     Background it does not cap the job when the CPU is idle: the suite
	     took 37 s at Nice 10, with turbo running one package at a time. -->
	<key>Nice</key>
	<integer>10</integer>
</dict>
</plist>
PLIST_EOF

plutil -lint "$PLIST" >/dev/null || { print -r -- "generated plist is invalid: $PLIST" >&2; exit 1; }

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
launchctl bootstrap "gui/$(id -u)" "$PLIST" || { print -r -- "launchctl bootstrap failed" >&2; exit 1; }

print -r -- "installed $LABEL — daily at $schedule local time"

# The early warning: preflight.sh --warn at login and at preflight.warn_at, so
# an expired login is renewed before the run instead of during it. It only
# checks and notifies, which is why RunAtLoad is safe here. A Mac asleep at
# warn_at runs it on wake. Without checks there is nothing to warn about, and
# a leftover job from an earlier install is removed.
PF_LABEL="ai.papercuts.preflight"
PF_PLIST="$HOME/Library/LaunchAgents/$PF_LABEL.plist"
launchctl bootout "gui/$(id -u)/$PF_LABEL" 2>/dev/null
if (( $(jq '.preflight.checks // [] | length' "$CONFIG") > 0 )); then
  warn_at="$(jq -r '.preflight.warn_at // empty' "$CONFIG")"
  if [[ -z "$warn_at" ]]; then
    # One hour before the run by default.
    (( wh = (hour + 23) % 24 )); wm=$minute
  else
    wh="${${warn_at%%:*}#0}"; wm="${${warn_at##*:}#0}"; : "${wh:=0}"; : "${wm:=0}"
    if ! [[ "$wh" =~ '^[0-9]+$' && "$wm" =~ '^[0-9]+$' ]] || (( wh > 23 || wm > 59 )); then
      print -r -- "preflight.warn_at must be HH:MM local time, got '$warn_at'" >&2
      exit 1
    fi
  fi
  chmod +x "$HARNESS_DIR/bin/preflight.sh" 2>/dev/null
  cat >"$PF_PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$PF_LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>$HARNESS_DIR/bin/preflight.sh</string>
		<string>--warn</string>
		<string>--config</string>
		<string>$CONFIG</string>
	</array>
	<key>WorkingDirectory</key>
	<string>$HARNESS_DIR</string>
	<key>StartCalendarInterval</key>
	<dict>
		<key>Hour</key>
		<integer>$wh</integer>
		<key>Minute</key>
		<integer>$wm</integer>
	</dict>
	<key>EnvironmentVariables</key>
	<dict>
		<key>PATH</key>
		<string>$PATH</string>
	</dict>
	<key>RunAtLoad</key>
	<true/>
	<key>StandardOutPath</key>
	<string>$HARNESS_DIR/.state/logs/launchd-preflight.out.log</string>
	<key>StandardErrorPath</key>
	<string>$HARNESS_DIR/.state/logs/launchd-preflight.err.log</string>
	<key>ProcessType</key>
	<string>Background</string>
</dict>
</plist>
PLIST_EOF
  plutil -lint "$PF_PLIST" >/dev/null || { print -r -- "generated plist is invalid: $PF_PLIST" >&2; exit 1; }
  launchctl bootstrap "gui/$(id -u)" "$PF_PLIST" || { print -r -- "launchctl bootstrap of $PF_LABEL failed" >&2; exit 1; }
  printf 'installed %s — credential check at login and daily at %02d:%02d\n' "$PF_LABEL" "$wh" "$wm"
else
  rm -f "$PF_PLIST"
fi
print -r -- "first run: the next occurrence (RunAtLoad is false, so nothing runs now)"
print -r -- ""
print -r -- "  status:    launchctl print gui/\$(id -u)/$LABEL | grep -E 'state|runs'"
print -r -- "  rehearse:  zsh $RUNNER --dry"
print -r -- "  logs:      $HARNESS_DIR/.state/logs/"
print -r -- "  stop:      zsh $HARNESS_DIR/bin/uninstall.sh"
