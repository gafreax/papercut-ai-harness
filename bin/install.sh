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
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
RUNNER="$HARNESS_DIR/bin/papercuts-daily.sh"

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

chmod +x "$RUNNER" "$HARNESS_DIR/bin/render.sh" 2>/dev/null
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
	<key>ProcessType</key>
	<string>Background</string>
</dict>
</plist>
PLIST_EOF

plutil -lint "$PLIST" >/dev/null || { print -r -- "generated plist is invalid: $PLIST" >&2; exit 1; }

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
launchctl bootstrap "gui/$(id -u)" "$PLIST" || { print -r -- "launchctl bootstrap failed" >&2; exit 1; }

print -r -- "installed $LABEL — daily at $schedule local time"
print -r -- "first run: the next occurrence (RunAtLoad is false, so nothing runs now)"
print -r -- ""
print -r -- "  status:    launchctl print gui/\$(id -u)/$LABEL | grep -E 'state|runs'"
print -r -- "  rehearse:  zsh $RUNNER --dry"
print -r -- "  logs:      $HARNESS_DIR/.state/logs/"
print -r -- "  stop:      zsh $HARNESS_DIR/bin/uninstall.sh"
