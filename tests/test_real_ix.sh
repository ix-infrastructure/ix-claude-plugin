#!/usr/bin/env bash
# Copyright 2026 Ix Infrastructure Inc.

# tests/test_real_ix.sh — Run the plugin's hooks against a REAL, released `ix`.
#
# tests/test_hooks.sh drives every hook through tests/mock-ix.sh. The mock is
# only as right as the last time someone compared it with the CLI, so a flag
# Ix renames or an output key it changes breaks the plugin without failing a
# single test. This suite uses whatever `ix` is first on PATH (CI installs a
# pinned release) and never starts a backend:
#
#   unmapped   — no workspace registered: graph reads print Ix's
#                `workspace_not_mapped` JSON record on stdout and exit 1
#   backend    — workspace registered, endpoint is a closed port: graph reads
#                print an error on stderr and exit 1 with an empty stdout
#
# `ix text` (ripgrep) and the Pro stub need no backend and answer for real.
#
# For each scenario it asserts that every hook registered in hooks/hooks.json
# exits 0 within its hooks.json timeout, prints nothing or one JSON object of
# the shape Claude Code accepts for that event, and turns ix's real records into
# the right outcome. Then it replays every ix command line the hooks ran (from
# IX_DEBUG_LOG) against the same CLI and fails on any argv-parse error, so a
# flag this ix does not have turns the suite red.
#
# Usage: bash tests/test_real_ix.sh
# Requires: bash, jq, git, timeout, a real `ix` on PATH (and ripgrep for it)
# Never set IX_ENDPOINT to a live backend: this suite pins it to a closed port.

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS_DIR="$(cd "${TESTS_DIR}/../hooks" && pwd)"

PASS_COUNT=0
FAIL_COUNT=0
pass() { printf 'PASS  %s\n' "$1"; PASS_COUNT=$(( PASS_COUNT + 1 )); }
fail() { printf 'FAIL  %s — %s\n' "$1" "$2"; FAIL_COUNT=$(( FAIL_COUNT + 1 )); }
section() { printf '\n── %s ─────────────────────────────────────────────\n' "$1"; }

for _bin in ix jq git timeout; do
  command -v "$_bin" >/dev/null 2>&1 || { echo "missing required tool: $_bin" >&2; exit 2; }
done
if [ "$(command -v ix)" = "${TESTS_DIR}/ix" ]; then
  echo "tests/ix (the mock) is first on PATH; this suite needs the real CLI" >&2
  exit 2
fi

ROOT_TMP=$(mktemp -d)
trap 'rm -rf "${ROOT_TMP}"' EXIT

# Isolation from the developer's machine: no real ~/.ix, no shared plugin
# caches, ledger or error log, no update check, and a backend that cannot exist.
export HOME="${ROOT_TMP}/home"
export TMPDIR="${ROOT_TMP}/tmp"
export IX_ENDPOINT="http://127.0.0.1:1"
export IX_NO_UPDATE_CHECK=1
unset IX_ANNOTATE_MODE IX_ANNOTATE_CHANNEL IX_HOOK_OUTPUT_STYLE IX_BLOCK_ON_HIGH_CONFIDENCE
mkdir -p "$HOME" "$TMPDIR"

IX_VERSION=$(ix --version 2>/dev/null | head -1)
echo "ix:      $(command -v ix)"
echo "version: ${IX_VERSION:-<none>}"
if [ -n "${IX_EXPECT_VERSION:-}" ]; then
  if [ "$IX_VERSION" = "$IX_EXPECT_VERSION" ]; then
    pass "ix --version is the pinned ${IX_EXPECT_VERSION}"
  else
    fail "ix --version is the pinned ${IX_EXPECT_VERSION}" "got '${IX_VERSION}'"
  fi
fi

# A small project the hooks can point at: a git repo (the auto-map guard needs
# one) with one symbol that `ix text` will find.
PROJECT="${ROOT_TMP}/project"
mkdir -p "${PROJECT}/src"
printf 'export function computeTotal(a, b) {\n  return a + b;\n}\n' > "${PROJECT}/src/math.js"
git -C "$PROJECT" init -q
git -C "$PROJECT" add -A
git -C "$PROJECT" -c user.email=ci@example.invalid -c user.name=ci commit -qm init

# hook_timeout <hook.sh> — the timeout hooks/hooks.json gives that command.
hook_timeout() {
  jq -r --arg h "$1" '[.hooks[][] .hooks[] | select(.command | endswith("/" + $h)) | .timeout] | first // 10' \
    "${HOOKS_DIR}/hooks.json"
}

# check_host_output <label> <event> — validates $OUT against what Claude Code
# accepts on a command hook's stdout: empty, or one JSON object whose keys are
# known and whose hookSpecificOutput names the firing event. Plugin policy on
# top: never permissionDecision "allow", never additionalContext on Stop.
check_host_output() {
  local _label="$1" _event="$2" _bad
  [ -n "$OUT" ] || return 0
  _bad=$(printf '%s' "$OUT" | jq -rs --arg ev "$_event" '
    if length != 1 or (.[0] | type) != "object" then "not exactly one JSON object"
    else .[0] as $o
      | ([$o | keys[] | select(IN("continue","suppressOutput","stopReason","decision",
            "reason","systemMessage","terminalSequence","hookSpecificOutput") | not)]
          | map("unknown top-level key " + .)) +
        (if $o.hookSpecificOutput == null then []
         elif $o.hookSpecificOutput.hookEventName != $ev
           then ["hookEventName \($o.hookSpecificOutput.hookEventName) != \($ev)"]
         else [] end) +
        (if $o.hookSpecificOutput.permissionDecision? == "allow"
           then ["permissionDecision allow"] else [] end) +
        (if $ev == "Stop" and ($o.hookSpecificOutput.additionalContext? != null)
           then ["additionalContext on Stop"] else [] end)
      | join("; ")
    end' 2>/dev/null) || _bad="stdout is not JSON"
  [ -z "$_bad" ] || { fail "$_label" "host protocol: ${_bad} (stdout: ${OUT:0:200})"; return 1; }
}

# run_hook <label> <hook.sh> <event> <payload-json>
# Sets OUT, ERR, CODE. Fails the case on a non-zero exit, a timeout or output
# Claude Code would reject; returns 1 then so the caller skips its own checks.
run_hook() {
  local _label="$1" _hook="$2" _event="$3" _payload="$4" _secs
  _secs=$(hook_timeout "$_hook")
  OUT=$(cd "$PROJECT" && printf '%s' "$_payload" \
    | timeout "$_secs" bash "${HOOKS_DIR}/${_hook}" 2>"${ROOT_TMP}/stderr")
  CODE=$?
  ERR=$(cat "${ROOT_TMP}/stderr")
  if [ "$CODE" -eq 124 ]; then
    fail "$_label" "exceeded its ${_secs}s hooks.json timeout"; return 1
  fi
  if [ "$CODE" -ne 0 ]; then
    fail "$_label" "exit ${CODE} (stderr: ${ERR:0:300})"; return 1
  fi
  check_host_output "$_label" "$_event" || return 1
  return 0
}

payload() {  # payload <event> <tool> <tool_input-json>
  jq -cn --arg ev "$1" --arg tool "$2" --argjson ti "$3" --arg cwd "$PROJECT" --arg sid "$SESSION" '
    {session_id: $sid, cwd: $cwd, hook_event_name: $ev}
    + (if $tool == "" then {prompt: "where is computeTotal defined?"}
       else {tool_name: $tool, tool_input: $ti} end)'
}

run_scenario() {
  local _name="$1"
  section "scenario: ${_name}"
  SESSION="ci-${_name}"
  export IX_HOME="${ROOT_TMP}/ixhome-${_name}"
  export IX_DEBUG_LOG="${ROOT_TMP}/hooks-${_name}.log"
  # Fresh plugin state per scenario, so caches from the first scenario (health,
  # Pro flag, auto-map debounce) cannot hide the second one's ix calls.
  export TMPDIR="${ROOT_TMP}/tmp-${_name}"
  mkdir -p "$IX_HOME" "$TMPDIR"
  : > "$IX_DEBUG_LOG"
  if [ "$_name" = "backend" ]; then
    cat > "${IX_HOME}/config.yaml" <<EOF
endpoint: ${IX_ENDPOINT}
format: text
workspaces:
  - workspace_id: "ci"
    workspace_name: ci
    root_path: ${PROJECT}
    default: true
EOF
  fi

  # What the graph read actually returns here, so a failure below can be read
  # against it.
  local _probe
  _probe=$(cd "$PROJECT" && timeout 20 ix locate computeTotal --format json 2>&1 | head -c 240)
  echo "  ix locate here → ${_probe//$'\n'/ }"

  # 1. UserPromptSubmit: the Pro probe runs the real `ix briefing`. On an OSS
  #    install that is a stub that exits 1, so no briefing may be injected.
  if run_hook "[${_name}] briefing: exit 0, valid output" ix-briefing.sh UserPromptSubmit \
       "$(payload UserPromptSubmit "" null)"; then
    if printf '%s' "$OUT" | grep -q 'Session briefing'; then
      fail "[${_name}] briefing: OSS ix is not treated as Pro" "injected a briefing: ${OUT:0:200}"
    else
      pass "[${_name}] briefing: exit 0, OSS ix not treated as Pro"
    fi
  fi

  # 1b. A task-sized first prompt asks `ix context --from-issue - --lean` for
  #     starting points. With no graph to answer from, none may be injected.
  if run_hook "[${_name}] briefing start points" ix-briefing.sh UserPromptSubmit \
       "$(jq -cn --arg sid "${SESSION}-start" --arg cwd "$PROJECT" \
          '{session_id: $sid, cwd: $cwd, hook_event_name: "UserPromptSubmit",
            prompt: "computeTotal in src/math.js adds its arguments the wrong way round; fix it"}')"; then
    if printf '%s' "$OUT" | grep -q 'Starting points'; then
      fail "[${_name}] briefing start points: none without a graph" "stdout: ${OUT:0:200}"
    elif ! grep -q '\] CMD ix context --from-issue - --lean' "$IX_DEBUG_LOG"; then
      fail "[${_name}] briefing start points: ix context was asked" "no CMD line in the debug log"
    else
      pass "[${_name}] briefing start points: asked ix, injected nothing without a graph"
    fi
  fi

  # 2. PreToolUse Grep: the hook answers only with a definition `ix locate`
  #    resolved. Here locate fails (error record or empty body), which must not
  #    be read as a definition: silence, and no block.
  if run_hook "[${_name}] Grep intercept" ix-intercept.sh PreToolUse \
       "$(payload PreToolUse Grep '{"pattern":"computeTotal"}')"; then
    if printf '%s' "$OUT" | jq -e '.decision? == "block"' >/dev/null 2>&1; then
      fail "[${_name}] Grep intercept: does not block" "stdout: ${OUT:0:200}"
    elif [ -n "$OUT" ]; then
      fail "[${_name}] Grep intercept: locate error is not a definition" "stdout: ${OUT:0:200}"
    else
      pass "[${_name}] Grep intercept: locate error is not a definition, silent, no block"
    fi
  fi

  # 2b. Grep with path and type: the hooks then add `ix text --path` and
  #     `--language`, flags the bare Grep above never passes, so step 8 only
  #     checks them against this CLI if a case sends them.
  if run_hook "[${_name}] Grep intercept with path/type" ix-intercept.sh PreToolUse \
       "$(payload PreToolUse Grep '{"pattern":"computeTotal","path":"src","type":"js"}')"; then
    if [ -z "$OUT" ]; then
      pass "[${_name}] Grep intercept with path/type: silent without a definition"
    else
      fail "[${_name}] Grep intercept with path/type: silent without a definition" "stdout: ${OUT:0:200}"
    fi
  fi

  # 3. PreToolUse Bash grep: same rule from a shell command.
  if run_hook "[${_name}] Bash intercept" ix-bash.sh PreToolUse \
       "$(payload PreToolUse Bash '{"command":"rg computeTotal src"}')"; then
    if [ -z "$OUT" ]; then
      pass "[${_name}] Bash intercept: silent without a definition"
    else
      fail "[${_name}] Bash intercept: silent without a definition" "stdout: ${OUT:0:200}"
    fi
  fi

  # 4. PreToolUse Glob: `ix inventory` fails; nothing may be injected.
  if run_hook "[${_name}] Glob intercept" ix-intercept.sh PreToolUse \
       "$(payload PreToolUse Glob '{"pattern":"**/*.js","path":"src"}')"; then
    if [ -z "$OUT" ]; then pass "[${_name}] Glob intercept: failed inventory → silent allow"
    else fail "[${_name}] Glob intercept: failed inventory → silent allow" "stdout: ${OUT:0:200}"; fi
  fi

  # 5. PreToolUse Edit: `ix impact` fails; no risk warning may be invented.
  if run_hook "[${_name}] pre-edit" ix-pre-edit.sh PreToolUse \
       "$(payload PreToolUse Edit "{\"file_path\":\"${PROJECT}/src/math.js\",\"old_string\":\"a + b\",\"new_string\":\"b + a\"}")"; then
    if [ -z "$OUT" ]; then pass "[${_name}] pre-edit: failed impact → no warning"
    else fail "[${_name}] pre-edit: failed impact → no warning" "stdout: ${OUT:0:200}"; fi
  fi

  # 6. PostToolUse Write: the auto-map guard asks real `ix status --format json
  #    --root`; it fails, so no map may be started.
  if run_hook "[${_name}] ingest" ix-ingest.sh PostToolUse \
       "$(payload PostToolUse Write "{\"file_path\":\"${PROJECT}/src/math.js\",\"content\":\"\"}")"; then
    if grep -q 'AUTOMAP run' "$IX_DEBUG_LOG"; then
      fail "[${_name}] ingest: no map without a completed graph" "$(grep AUTOMAP "$IX_DEBUG_LOG" | tail -1)"
    elif grep -q 'AUTOMAP skip: .* is not mapped (or ix status failed)' "$IX_DEBUG_LOG"; then
      pass "[${_name}] ingest: ix status failure → auto-map skipped"
    else
      fail "[${_name}] ingest: ix status consulted" "no AUTOMAP status decision in the debug log"
    fi
  fi

  # 6b. PostToolUse Bash: an edit made through a script is in the diff, and the
  #     real `ix hook claude-post-edit` sees it. With no graph it has nothing
  #     to say, and the hook must say nothing.
  printf 'export function computeTotal(a, b) {\n  return b + a;\n}\n' > "${PROJECT}/src/math.js"
  if run_hook "[${_name}] dependents" ix-dependents.sh PostToolUse \
       "$(payload PostToolUse Bash '{"command":"sed -i s/a + b/b + a/ src/math.js"}')"; then
    if [ -n "$OUT" ]; then
      fail "[${_name}] dependents: nothing to report without a graph" "stdout: ${OUT:0:200}"
    elif ! grep -q '\] CMD ix hook claude-post-edit' "$IX_DEBUG_LOG"; then
      fail "[${_name}] dependents: ix hook was asked" "no CMD line in the debug log"
    else
      pass "[${_name}] dependents: asked ix hook on a real diff, silent without a graph"
    fi
  fi
  git -C "$PROJECT" checkout -q -- src/math.js

  # 7. Stop: the async map hook and the attribution summary.
  run_hook "[${_name}] Stop map" ix-map.sh Stop "$(payload Stop "" null)" \
    && pass "[${_name}] Stop map: exit 0, no output problems"
  # The summary reports the hooks that told Claude something this turn. With
  # no graph none did -- the Grep and Bash intercepts answer only with a
  # definition now -- so there is nothing to summarise, and a summary would be
  # an invention.
  if run_hook "[${_name}] Stop annotate" ix-annotate.sh Stop "$(payload Stop "" null)"; then
    if printf '%s' "$OUT" | jq -e '.systemMessage? // empty | test("[a-z]")' >/dev/null 2>&1; then
      fail "[${_name}] Stop annotate: no summary when no hook helped" "stdout: '${OUT:0:200}'"
    else
      pass "[${_name}] Stop annotate: exit 0, no summary when no hook helped"
    fi
  fi

  # 8. Acceptance: every ix argv the hooks ran parses under this CLI. A renamed
  #    or removed flag fails here, whatever the backend state.
  local _line _seen="" _bad=0 _n=0 _err
  local -a _argv
  while IFS= read -r _line; do
    eval "_argv=(${_line})"
    [ "${_argv[0]}" = "ix" ] || continue
    _n=$(( _n + 1 ))
    _seen="${_seen} ${_argv[1]}"
    # stdin from /dev/null: `ix context --from-issue -` and `ix hook` read it,
    # and would otherwise swallow the rest of this loop's command list.
    _err=$(cd "$PROJECT" && timeout 20 "${_argv[@]}" 2>&1 >/dev/null </dev/null)
    if printf '%s' "$_err" | grep -qiE "unknown option|unknown command|too many arguments|missing required argument|argument '.*' is invalid"; then
      fail "[${_name}] argv accepted by ix ${IX_VERSION}: ${_line}" "$(printf '%s' "$_err" | head -1)"
      _bad=1
    fi
  done < <(sed -n 's/^.*\] CMD //p' "$IX_DEBUG_LOG" | sort -u)
  local _sub _missing=""
  for _sub in text locate inventory impact briefing status context hook; do
    case " ${_seen} " in *" ${_sub} "*) ;; *) _missing="${_missing} ${_sub}" ;; esac
  done
  # Optional flags the hooks add only for some inputs must have run too.
  local _flag
  for _flag in "text .*--path" "text .*--language" "inventory .*--path"; do
    grep -qE "\] CMD ix ${_flag}( |$)" "$IX_DEBUG_LOG" || _missing="${_missing} ix ${_flag/ .\*/ }"
  done
  if [ -n "$_missing" ]; then
    fail "[${_name}] hooks exercised every ix subcommand and optional flag they use" "never ran:${_missing}"
  elif [ "$_bad" -eq 0 ]; then
    pass "[${_name}] all ${_n} distinct ix command lines the hooks ran parse under ix ${IX_VERSION}"
  fi
}

run_scenario unmapped
run_scenario backend

# `ix map <root> --silent` only runs once a graph is complete, which needs a
# backend; check its flag against the CLI's own help instead.
section "commands that need a backend to run"
_map_argv=$(grep -ohE 'ix map "\$_root" [-a-z ]+' "${HOOKS_DIR}/ix-lib.sh" | sort -u | head -1)
_map_help=$(ix map --help 2>&1)
_map_ok=1
for _flag in $(printf '%s' "${_map_argv}" | grep -oE -- '--[a-z-]+'); do
  printf '%s' "$_map_help" | grep -qE -- "(^|[[:space:],])${_flag}([[:space:],=]|$)" || {
    fail "ix map accepts the plugin's ${_flag}" "not in 'ix map --help'"; _map_ok=0; }
done
if [ -z "$_map_argv" ]; then
  fail "ix map argv found in hooks/ix-lib.sh" "pattern not found; update this check"
elif [ "$_map_ok" -eq 1 ]; then
  pass "ix map accepts the plugin's flags (${_map_argv#ix map \"\$_root\" })"
fi

printf '\n%d passed, %d failed\n' "$PASS_COUNT" "$FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
