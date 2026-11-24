#!/bin/zsh
# Proves the review gate is rendered into the orchestrator prompt only when the
# config asks for it, with every placeholder inside it filled, and that the
# skill it names is pre-approved (a headless run cannot answer a prompt).
#
# Usage: tests/render-review.sh
# It runs the suite against bin/render.sh (must pass), then against two copies
# that break it (each must fail): one never substitutes the phase, one
# substitutes it last, after the placeholders it carries were already filled.

set -uo pipefail
HERE="${0:A:h}"
REAL="$HERE/../bin/render.sh"

fails=0
check() { # <description> <expected> <actual>
  if [[ "$2" == "$3" ]]; then print -r -- "  ok   $1"
  else print -r -- "  FAIL $1 (expected $2, got $3)"; (( fails++ )); fi
}

render() { # <render script> <jq filter> -> run dir on stdout
  local sb; sb="$(mktemp -d)"
  jq "$2" "$HERE/../config/config.example.json" >"$sb/config.json"
  # The script resolves the template from its own location, so a mutant copy
  # needs the prompts next to it.
  zsh "$1" "$sb/config.json" "$sb" >/dev/null 2>&1
  print -r -- "$sb"
}

leftovers() { grep -o '{{[A-Z_]*}}' "$1/prompt.md" | sort -u | tr '\n' ' ' | sed 's/ $//'; }
skills() { jq -r '.permissions.allow | map(select(startswith("Skill("))) | join(",")' "$1/sandbox-settings.json"; }

suite() { # <render script>
  local script="$1" sb

  sb="$(render "$script" '.review.skill = null')"
  check "no review skill: no review phase" 0 "$(grep -c 'Phase 2b' "$sb/prompt.md")"
  check "no review skill: no placeholder left" "" "$(leftovers "$sb")"
  check "no review skill: no skill pre-approved" "" "$(skills "$sb")"
  rm -rf "$sb"

  sb="$(render "$script" '.review = {skill: "code-review", advisors: ["deploy-reviewer"], max_fix_rounds: 2}')"
  check "review on: phase rendered" 1 "$(grep -c '## Phase 2b' "$sb/prompt.md")"
  check "review on: no placeholder left" "" "$(leftovers "$sb")"
  check "review on: names the skill" 1 "$(grep -c 'Skill tool with `code-review`' "$sb/prompt.md")"
  check "review on: names the advisor" 1 "$(grep -c 'set to the name: `deploy-reviewer`' "$sb/prompt.md")"
  check "review on: fix rounds from config" 1 "$(grep -c 'At most \*\*2\*\* fix round' "$sb/prompt.md")"
  check "review on: diff against the base branch" 1 "$(grep -c 'diff origin/main\.\.\.HEAD' "$sb/prompt.md")"
  check "review on: skill pre-approved" "Skill(code-review)" "$(skills "$sb")"
  rm -rf "$sb"

  # Advisors defined outside the project are loaded from agents_dir; one with
  # no file is left out, not invented.
  local adir; adir="$(mktemp -d)"
  print -r -- $'---\nname: sre\ndescription: Judges deployability\ntools: Read, Grep\nmodel: opus\n---\n\nYou are an SRE.' >"$adir/sre.md"
  sb="$(render "$script" ".review = {skill: \"code-review\", advisors: [\"sre\", \"ghost\"], agents_dir: \"$adir\"}")"
  check "agents_dir: only defined advisors loaded" "sre" "$(jq -r 'keys | join(",")' "$sb/agents.json" 2>/dev/null)"
  check "agents_dir: tools parsed" "Read,Grep" "$(jq -r '.sre.tools | join(",")' "$sb/agents.json" 2>/dev/null)"
  check "agents_dir: prompt is the body" "You are an SRE." "$(jq -r '.sre.prompt | gsub("^\\n+"; "")' "$sb/agents.json" 2>/dev/null)"
  rm -rf "$sb" "$adir"

  sb="$(render "$script" '.review = {skill: "code-review", advisors: []}')"
  check "no advisors: says so" 1 "$(grep -c 'No advisory agents are configured' "$sb/prompt.md")"
  check "no advisors: default one fix round" 1 "$(grep -c 'At most \*\*1\*\* fix round' "$sb/prompt.md")"
  rm -rf "$sb"
}

print -r -- "bin/render.sh:"
suite "$REAL"
real_fails=$fails

run_mutant() { # <description> <sed expression>
  local dir; dir="$(mktemp -d)"
  mkdir -p "$dir/bin" && cp -R "$HERE/../prompts" "$dir/prompts"
  sed "$2" "$REAL" >"$dir/bin/render.sh"
  cmp -s "$REAL" "$dir/bin/render.sh" && { print -r -- "mutation did not apply: $1"; exit 2; }
  fails=0
  suite "$dir/bin/render.sh" >/dev/null
  print -r -- "mutant ($1): $fails failure(s)"
  rm -rf "$dir"
  (( fails > 0 ))
}

print -r -- "mutants — each expected to fail:"
mutants_ok=1
run_mutant "phase never substituted" "/^subst '{{REVIEW_PHASE}}'/d" || mutants_ok=0
run_mutant "frontmatter not stripped from the prompt" "s/f==1 \&\& \/\^---\$\/ {f=2; next} f==2/1/" || mutants_ok=0
run_mutant "phase substituted last" "/^subst '{{REVIEW_PHASE}}'/d; s/^print -r -- \"\$template\" >/subst '{{REVIEW_PHASE}}' \"\$review_phase\"; &/" || mutants_ok=0

print -r -- ""
if (( real_fails == 0 && mutants_ok )); then
  print -r -- "PASS: suite green on the real script, every mutant caught"
  exit 0
fi
print -r -- "FAIL: real=$real_fails failure(s), mutants caught=$mutants_ok"
exit 1
