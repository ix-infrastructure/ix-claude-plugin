#!/usr/bin/env bash
# Copyright 2026 Ix Infrastructure Inc.

# tests/bench_hooks.sh — Median wall time of each hook on a representative payload.
#
# Pipes one payload per case into the hook N times and prints the median, min
# and max in milliseconds. It measures what the agent waits for: bash start,
# the hook's own work and every ix call it makes.
#
# Usage: bash tests/bench_hooks.sh [-n N] [--real] [--on] [--hooks DIR]
#   -n N        runs per case (default 9)
#   --real      use the `ix` first on PATH instead of tests/mock-ix.sh
#   --on        turn on the hooks that are off by default
#               (IX_GREP_INTERCEPT, IX_EDIT_DEPENDENTS, IX_PRE_EDIT_GATE)
#   --hooks DIR time the hooks in DIR (e.g. an older checkout, for before/after)
#
# Other IX_* switches pass through from the environment. Payloads point at a
# throwaway git repo, never mapped, so the Stop and ingest hooks' automatic map
# skips it. Plugin caches go to a throwaway TMPDIR (kept warm across runs, as
# in a session); the ledger and error log are off.

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS_DIR="$(cd "${TESTS_DIR}/../hooks" && pwd)"
RUNS=9
REAL=0
ON=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    -n) RUNS="${2:-}"; shift 2 ;;
    --real) REAL=1; shift ;;
    --on) ON=1; shift ;;
    --hooks) HOOKS_DIR="$(cd "${2:-}" && pwd)" || exit 2; shift 2 ;;
    -h|--help) sed -n '4,20p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ "$RUNS" =~ ^[1-9][0-9]*$ ]] || { echo "-n needs a positive integer" >&2; exit 2; }
[ -n "${EPOCHREALTIME:-}" ] || { echo "needs bash 5 (EPOCHREALTIME)" >&2; exit 2; }

BENCH_TMP=$(mktemp -d)
trap 'rm -rf "${BENCH_TMP}"' EXIT
PROJECT="${BENCH_TMP}/project"
mkdir -p "${PROJECT}/src" "${BENCH_TMP}/tmp"
printf 'export function computeTotal(a, b) {\n  return a + b;\n}\n' > "${PROJECT}/src/math.js"
git -C "$PROJECT" init -q
git -C "$PROJECT" add -A
git -C "$PROJECT" -c user.email=bench@example.invalid -c user.name=bench commit -qm init

BENCH_PATH="$PATH"
[ "$REAL" -eq 1 ] || BENCH_PATH="${TESTS_DIR}:${PATH}"
BENCH_ENV=(TMPDIR="${BENCH_TMP}/tmp" IX_LEDGER_MODE=off IX_ERROR_MODE=off PATH="${BENCH_PATH}")
[ "$ON" -eq 1 ] && BENCH_ENV+=(IX_GREP_INTERCEPT=on IX_EDIT_DEPENDENTS=on IX_PRE_EDIT_GATE=on)

payload() {  # payload <event> <tool> <tool_input-json>
  jq -cn --arg ev "$1" --arg tool "$2" --argjson ti "$3" --arg cwd "$PROJECT" '
    {session_id: "bench", cwd: $cwd, hook_event_name: $ev}
    + (if $tool == "" then {prompt: "where is computeTotal defined?"}
       else {tool_name: $tool, tool_input: $ti} end)'
}

# bench_case <hook.sh> <label> <payload-json>
bench_case() {
  local _hook="$1" _label="$2" _input="${BENCH_TMP}/payload.json" _i _t0 _t1
  local -a _ms=()
  [ -f "${HOOKS_DIR}/${_hook}" ] || { printf '%-18s %-30s %s\n' "$_hook" "$_label" "missing"; return; }
  # Each case gets its own session, so state one case leaves (the dependents
  # follow-up owed after a report) does not change the next one.
  printf '%s' "$3" | jq -c --arg sid "bench ${_hook} ${_label}" '.session_id = $sid' > "$_input"
  for (( _i = 0; _i < RUNS; _i++ )); do
    _t0="${EPOCHREALTIME//[.,]/}"
    (cd "$PROJECT" && env "${BENCH_ENV[@]}" bash "${HOOKS_DIR}/${_hook}" < "$_input" >/dev/null 2>&1)
    _t1="${EPOCHREALTIME//[.,]/}"
    _ms+=( $(( (_t1 - _t0) / 1000 )) )
  done
  local -a _sorted
  mapfile -t _sorted < <(printf '%s\n' "${_ms[@]}" | sort -n)
  printf '%-18s %-30s %6s %6s %6s\n' "$_hook" "$_label" \
    "${_sorted[$(( RUNS / 2 ))]}" "${_sorted[0]}" "${_sorted[$(( RUNS - 1 ))]}"
}

echo "hooks: ${HOOKS_DIR}"
echo "ix:    $([ "$REAL" -eq 1 ] && command -v ix || echo "mock (tests/mock-ix.sh)")"
echo "runs:  ${RUNS} per case$([ "$ON" -eq 1 ] && echo ", off-by-default hooks turned on")"
echo
printf '%-18s %-30s %6s %6s %6s\n' "hook" "payload" "median" "min" "max"

bench_case ix-bash.sh       "Bash: rg computeTotal src"    "$(payload PreToolUse Bash '{"command":"rg computeTotal src"}')"
bench_case ix-bash.sh       "Bash: ls -la"                 "$(payload PreToolUse Bash '{"command":"ls -la"}')"
bench_case ix-intercept.sh  "Grep: computeTotal"           "$(payload PreToolUse Grep '{"pattern":"computeTotal"}')"
bench_case ix-intercept.sh  "Glob: **/*.js in src"         "$(payload PreToolUse Glob '{"pattern":"**/*.js","path":"src"}')"
bench_case ix-pre-edit.sh   "Edit: src/math.js"            "$(payload PreToolUse Edit '{"file_path":"src/math.js","old_string":"a + b","new_string":"b + a"}')"
bench_case ix-dependents.sh "Edit: src/math.js"            "$(payload PostToolUse Edit '{"file_path":"src/math.js","old_string":"a + b","new_string":"b + a"}')"
bench_case ix-dependents.sh "Bash: git diff (reads)"       "$(payload PostToolUse Bash '{"command":"git diff"}')"
bench_case ix-dependents.sh "Bash: sed -i (may write)"     "$(payload PostToolUse Bash '{"command":"sed -i s/a/a/ src/math.js"}')"
bench_case ix-ingest.sh     "Edit: src/math.js"            "$(payload PostToolUse Edit '{"file_path":"src/math.js"}')"
bench_case ix-briefing.sh   "prompt"                       "$(payload UserPromptSubmit "" null)"
bench_case ix-annotate.sh   "Stop"                         "$(payload Stop "" null)"
bench_case ix-map.sh        "Stop"                         "$(payload Stop "" null)"
