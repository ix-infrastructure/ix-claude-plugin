#!/usr/bin/env bash
# tests/test_hooks.sh — Integration test harness for ix Claude plugin hooks.
#
# Usage: bash tests/test_hooks.sh
# Requires: bash, jq
# Exit code: 0 if all tests pass, 1 if any fail.

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS_DIR="$(cd "${TESTS_DIR}/../hooks" && pwd)"
FX_IN="${TESTS_DIR}/fixtures/hook_inputs"
FX_IX="${TESTS_DIR}/fixtures/ix_outputs"

PASS_COUNT=0
FAIL_COUNT=0
TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "${TEST_TMPDIR}"' EXIT

# ── Output helpers ─────────────────────────────────────────────────────────────

pass() { printf 'PASS  %s\n' "$1"; PASS_COUNT=$(( PASS_COUNT + 1 )); }
fail() { printf 'FAIL  %s — %s\n' "$1" "$2"; FAIL_COUNT=$(( FAIL_COUNT + 1 )); }
section() { printf '\n── %s ─────────────────────────────────────────────────\n' "$1"; }

# ── Hook runner ───────────────────────────────────────────────────────────────
# run_hook <hook.sh> <fixture_path> [KEY=VAL ...]
# Sets globals _OUT (stdout) and _RC (exit code).
# Extra KEY=VAL pairs are passed to env before the hook, after defaults.
run_hook() {
  local _hook="${HOOKS_DIR}/$1" _input="$2"; shift 2
  local _run_tmp; _run_tmp=$(mktemp -d -p "${TEST_TMPDIR}")
  _RC=0
  # IX_LEDGER_MODE=off: skip async ledger writes (not relevant to hook output)
  # IX_INGEST_INJECT=off: silence ingest injection
  # IX_ERROR_MODE=off: suppress error-log writes during tests
  # TMPDIR per-run: prevents read-cache TTL bleed between test cases
  _OUT=$(env \
    TMPDIR="${_run_tmp}" \
    IX_HEALTH_CACHE="${_run_tmp}/ix-healthy" \
    IX_MAP_DEBOUNCE_FILE="${_run_tmp}/ix-map-last" \
    IX_MAP_LOCK_PATH="${_run_tmp}/ix-map.lock" \
    IX_LEDGER_MODE="off" \
    IX_INGEST_INJECT="off" \
    IX_ERROR_MODE="off" \
    "$@" \
    PATH="${TESTS_DIR}:${PATH}" \
    bash "${_hook}" < "${_input}" 2>/dev/null) || _RC=$?
}

# ── Assert helpers ────────────────────────────────────────────────────────────

# Assert exit 0 and no stdout.
assert_empty() {
  local _name="$1"
  if [ "${_RC}" -ne 0 ]; then
    fail "${_name}" "expected exit 0, got ${_RC}"; return
  fi
  if [ -n "${_OUT}" ]; then
    fail "${_name}" "expected no output, got: ${_OUT:0:100}"; return
  fi
  pass "${_name}"
}

# Assert exit 0, valid JSON with additionalContext containing a given prefix.
# Also enforces the 10 000-char injection cap.
assert_additional_context() {
  local _name="$1" _prefix="${2:-[ix}"
  if [ "${_RC}" -ne 0 ]; then
    fail "${_name}" "expected exit 0, got ${_RC}"; return
  fi
  if [ -z "${_OUT}" ]; then
    fail "${_name}" "expected JSON output, got nothing"; return
  fi
  if ! echo "${_OUT}" | jq -e . >/dev/null 2>&1; then
    fail "${_name}" "invalid JSON: ${_OUT:0:100}"; return
  fi
  local _ctx
  _ctx=$(echo "${_OUT}" | jq -r '.additionalContext // empty' 2>/dev/null || true)
  if [ -z "${_ctx}" ]; then
    fail "${_name}" "missing additionalContext — output: ${_OUT:0:100}"; return
  fi
  if [[ "${_ctx}" != *"${_prefix}"* ]]; then
    fail "${_name}" "additionalContext missing '${_prefix}' — got: ${_ctx:0:100}"; return
  fi
  if [ "${#_OUT}" -gt 10000 ]; then
    fail "${_name}" "output exceeds 10000-char injection cap: ${#_OUT} chars"; return
  fi
  pass "${_name}"
}

assert_block_decision() {
  local _name="$1" _needle="${2:-}"
  if [ "${_RC}" -ne 0 ]; then
    fail "${_name}" "expected exit 0, got ${_RC}"; return
  fi
  if [ -z "${_OUT}" ]; then
    fail "${_name}" "expected JSON output, got nothing"; return
  fi
  if ! echo "${_OUT}" | jq -e '.decision == "block" and (.reason | type == "string")' >/dev/null 2>&1; then
    fail "${_name}" "expected block decision JSON — output: ${_OUT:0:140}"; return
  fi
  local _reason
  _reason=$(echo "${_OUT}" | jq -r '.reason // empty' 2>/dev/null || true)
  if [ -n "${_needle}" ] && [[ "${_reason}" != *"${_needle}"* ]]; then
    fail "${_name}" "reason missing '${_needle}' — got: ${_reason:0:180}"; return
  fi
  pass "${_name}"
}

# Assert exit 0, valid JSON with hookSpecificOutput.additionalContext
# and permissionDecision=allow.
assert_structured() {
  local _name="$1"
  if [ "${_RC}" -ne 0 ]; then
    fail "${_name}" "expected exit 0, got ${_RC}"; return
  fi
  if [ -z "${_OUT}" ]; then
    fail "${_name}" "expected JSON output, got nothing"; return
  fi
  if ! echo "${_OUT}" | jq -e '.hookSpecificOutput' >/dev/null 2>&1; then
    fail "${_name}" "missing hookSpecificOutput — output: ${_OUT:0:100}"; return
  fi
  local _ctx _decision
  _ctx=$(echo "${_OUT}" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null || true)
  _decision=$(echo "${_OUT}" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null || true)
  if [ -z "${_ctx}" ]; then
    fail "${_name}" "missing hookSpecificOutput.additionalContext"; return
  fi
  if [ "${_decision}" != "allow" ]; then
    fail "${_name}" "expected permissionDecision=allow, got: ${_decision}"; return
  fi
  pass "${_name}"
}

# Assert exit 0, valid JSON with systemMessage containing a given substring.
assert_system_message() {
  local _name="$1" _needle="$2"
  if [ "${_RC}" -ne 0 ]; then
    fail "${_name}" "expected exit 0, got ${_RC}"; return
  fi
  if [ -z "${_OUT}" ]; then
    fail "${_name}" "expected JSON output, got nothing"; return
  fi
  if ! echo "${_OUT}" | jq -e '.systemMessage' >/dev/null 2>&1; then
    fail "${_name}" "missing systemMessage — output: ${_OUT:0:100}"; return
  fi
  local _msg
  _msg=$(echo "${_OUT}" | jq -r '.systemMessage // empty' 2>/dev/null || true)
  if [[ "${_msg}" != *"${_needle}"* ]]; then
    fail "${_name}" "systemMessage missing '${_needle}' — got: ${_msg:0:140}"; return
  fi
  pass "${_name}"
}

assert_no_hook_specific_output() {
  local _name="$1"
  if [ "${_RC}" -ne 0 ]; then
    fail "${_name}" "expected exit 0, got ${_RC}"; return
  fi
  if [ -z "${_OUT}" ]; then
    fail "${_name}" "expected JSON output, got nothing"; return
  fi
  if echo "${_OUT}" | jq -e '.hookSpecificOutput' >/dev/null 2>&1; then
    fail "${_name}" "unexpected hookSpecificOutput present — output: ${_OUT:0:120}"; return
  fi
  pass "${_name}"
}

run_ix_hook_decide() {
  local _mode="$1" _content="$2"; shift 2
  _RC=0
  _OUT=$(env "$@" bash -lc '
    source "'"${HOOKS_DIR}"'/lib/index.sh"
    ix_hook_decide "$1" "$2"
  ' _ "${_mode}" "${_content}" 2>/dev/null) || _RC=$?
}

run_ix_hook_fallback() {
  local _mode="$1" _content="$2" _augment="$3"; shift 3
  _RC=0
  _OUT=$(env "$@" bash -lc '
    source "'"${HOOKS_DIR}"'/lib/index.sh"
    ix_hook_fallback "$1" "$2" "$3"
  ' _ "${_mode}" "${_content}" "${_augment}" 2>/dev/null) || _RC=$?
}

run_ix_query_intent() {
  local _pattern="$1"; shift
  _RC=0
  _OUT=$(env "$@" bash -lc '
    source "'"${HOOKS_DIR}"'/lib/index.sh"
    ix_query_intent "$1"
    printf "%s\n" "$QUERY_INTENT"
  ' _ "${_pattern}" 2>/dev/null) || _RC=$?
}

# ── Minimal "no-tool" fixture (causes hooks to exit early with no output) ─────
_EMPTY_FIXTURE=$(mktemp -p "${TEST_TMPDIR}" --suffix=.json)
printf '{"tool_name": "", "tool_input": {}, "cwd": "/repo"}' > "${_EMPTY_FIXTURE}"

# ── Secret-pattern Grep fixture ───────────────────────────────────────────────
_SECRET_FIXTURE=$(mktemp -p "${TEST_TMPDIR}" --suffix=.json)
printf '{"tool_name":"Grep","tool_input":{"pattern":"sk-abc123456789abcdef012345678901234567890","path":"src/"},"cwd":"/repo"}' \
  > "${_SECRET_FIXTURE}"

# ── Secret bash-grep fixture ──────────────────────────────────────────────────
_SECRET_BASH_FIXTURE=$(mktemp -p "${TEST_TMPDIR}" --suffix=.json)
printf '{"tool_name":"Bash","tool_input":{"command":"grep sk-abc123456789abcdef012345678901234567890 src/"},"cwd":"/repo"}' \
  > "${_SECRET_BASH_FIXTURE}"

# ── Bash grep fixture ─────────────────────────────────────────────────────────
_BASH_GREP_FIXTURE=$(mktemp -p "${TEST_TMPDIR}" --suffix=.json)
printf '{"tool_name":"Bash","tool_input":{"command":"grep -r '\''AuthService'\'' src/"},"cwd":"/repo"}' \
  > "${_BASH_GREP_FIXTURE}"

# ── Bash non-grep fixture ─────────────────────────────────────────────────────
_BASH_LS_FIXTURE=$(mktemp -p "${TEST_TMPDIR}" --suffix=.json)
printf '{"tool_name":"Bash","tool_input":{"command":"ls -la src/"},"cwd":"/repo"}' \
  > "${_BASH_LS_FIXTURE}"

# ── Grep literal/symbol fixtures for E2 ──────────────────────────────────────
_GREP_TODO_FIXTURE=$(mktemp -p "${TEST_TMPDIR}" --suffix=.json)
printf '{"tool_name":"Grep","tool_input":{"pattern":"TODO","path":"src/"},"cwd":"/repo"}' \
  > "${_GREP_TODO_FIXTURE}"

_GREP_PHRASE_FIXTURE=$(mktemp -p "${TEST_TMPDIR}" --suffix=.json)
printf '{"tool_name":"Grep","tool_input":{"pattern":"timeout exceeded","path":"src/"},"cwd":"/repo"}' \
  > "${_GREP_PHRASE_FIXTURE}"

_GREP_DOTTED_SYMBOL_FIXTURE=$(mktemp -p "${TEST_TMPDIR}" --suffix=.json)
printf '{"tool_name":"Grep","tool_input":{"pattern":"auth_middleware.login","path":"src/"},"cwd":"/repo"}' \
  > "${_GREP_DOTTED_SYMBOL_FIXTURE}"

# ── User-prompt fixture for ix-briefing.sh ───────────────────────────────────
_USER_PROMPT_FIXTURE=$(mktemp -p "${TEST_TMPDIR}" --suffix=.json)
printf '{"session_id":"test-session-001","prompt":"explain the auth flow"}' > "${_USER_PROMPT_FIXTURE}"

# ── Markdown-file edit fixture (should be skipped by ix-pre-edit.sh) ─────────
_EDIT_MD_FIXTURE=$(mktemp -p "${TEST_TMPDIR}" --suffix=.json)
printf '{"tool_name":"Edit","tool_input":{"file_path":"/repo/README.md","old_string":"foo","new_string":"bar"},"cwd":"/repo"}' \
  > "${_EDIT_MD_FIXTURE}"

# ═════════════════════════════════════════════════════════════════════════════
# ix-briefing.sh — prompt briefing and model-authored attribution instruction
# ═════════════════════════════════════════════════════════════════════════════
section "ix-briefing.sh"

run_hook ix-briefing.sh "${_USER_PROMPT_FIXTURE}" IX_ANNOTATE_MODE=brief IX_ANNOTATE_CHANNEL=modelSuffix
if [ "${_RC}" -ne 0 ]; then
  fail "briefing/model-authored annotation instruction" "expected exit 0, got ${_RC}"
elif [ -z "${_OUT}" ]; then
  fail "briefing/model-authored annotation instruction" "expected JSON output, got nothing"
elif ! echo "${_OUT}" | jq -e '.additionalContext' >/dev/null 2>&1; then
  fail "briefing/model-authored annotation instruction" "missing additionalContext — output: ${_OUT:0:120}"
else
  _ctx=$(echo "${_OUT}" | jq -r '.additionalContext // empty' 2>/dev/null || true)
  if [[ "${_ctx}" != *"[ix] Session briefing:"* ]]; then
    fail "briefing/model-authored annotation instruction" "missing session briefing in additionalContext"
  elif [[ "${_ctx}" != *'Use one terse sentence by default; use two short sentences only if one sentence would be awkward.'* ]]; then
    fail "briefing/model-authored annotation instruction" "missing model-authored Ix instruction"
  else
    pass "briefing/model-authored annotation instruction"
  fi
fi

# ═════════════════════════════════════════════════════════════════════════════
# ix-intercept.sh — Grep and Glob
# ═════════════════════════════════════════════════════════════════════════════
section "ix-intercept.sh"

run_ix_hook_decide block "test reason"
if [ "${_RC}" -ne 0 ]; then
  fail "lib/ix_hook_decide legacy block" "expected exit 0, got ${_RC}"
elif [ -z "${_OUT}" ]; then
  fail "lib/ix_hook_decide legacy block" "expected JSON output, got nothing"
elif ! echo "${_OUT}" | jq -e '.decision == "block" and .reason == "test reason"' >/dev/null 2>&1; then
  fail "lib/ix_hook_decide legacy block" "unexpected output: ${_OUT:0:120}"
else
  pass "lib/ix_hook_decide legacy block"
fi

run_ix_hook_decide block "test reason" IX_HOOK_OUTPUT_STYLE=structured
if [ "${_RC}" -ne 0 ]; then
  fail "lib/ix_hook_decide structured block" "expected exit 0, got ${_RC}"
elif [ -z "${_OUT}" ]; then
  fail "lib/ix_hook_decide structured block" "expected JSON output, got nothing"
elif ! echo "${_OUT}" | jq -e '.hookSpecificOutput.hookEventName == "PreToolUse" and .hookSpecificOutput.permissionDecision == "block" and .hookSpecificOutput.reason == "test reason"' >/dev/null 2>&1; then
  fail "lib/ix_hook_decide structured block" "unexpected output: ${_OUT:0:140}"
else
  pass "lib/ix_hook_decide structured block"
fi

run_ix_hook_fallback block "" "[ix fallback] augment context"
assert_additional_context "lib/ix_hook_fallback block degrades to augment" "[ix fallback]"

run_ix_hook_fallback augment "" ""
assert_empty "lib/ix_hook_fallback augment degrades to allow"

run_ix_query_intent "TODO"
if [ "${_RC}" -ne 0 ]; then
  fail "lib/ix_query_intent TODO literal" "expected exit 0, got ${_RC}"
elif [ "${_OUT}" != "literal" ]; then
  fail "lib/ix_query_intent TODO literal" "expected literal, got: ${_OUT}"
else
  pass "lib/ix_query_intent TODO literal"
fi

run_ix_query_intent "timeout exceeded"
if [ "${_RC}" -ne 0 ]; then
  fail "lib/ix_query_intent phrase literal" "expected exit 0, got ${_RC}"
elif [ "${_OUT}" != "literal" ]; then
  fail "lib/ix_query_intent phrase literal" "expected literal, got: ${_OUT}"
else
  pass "lib/ix_query_intent phrase literal"
fi

run_ix_query_intent "AuthService"
if [ "${_RC}" -ne 0 ]; then
  fail "lib/ix_query_intent symbol" "expected exit 0, got ${_RC}"
elif [ "${_OUT}" != "symbol" ]; then
  fail "lib/ix_query_intent symbol" "expected symbol, got: ${_OUT}"
else
  pass "lib/ix_query_intent symbol"
fi

run_ix_query_intent "auth_middleware.login"
if [ "${_RC}" -ne 0 ]; then
  fail "lib/ix_query_intent dotted symbol" "expected exit 0, got ${_RC}"
elif [ "${_OUT}" != "symbol" ]; then
  fail "lib/ix_query_intent dotted symbol" "expected symbol, got: ${_OUT}"
else
  pass "lib/ix_query_intent dotted symbol"
fi

run_ix_query_intent '\w+\.ts$'
if [ "${_RC}" -ne 0 ]; then
  fail "lib/ix_query_intent regex literal" "expected exit 0, got ${_RC}"
elif [ "${_OUT}" != "literal" ]; then
  fail "lib/ix_query_intent regex literal" "expected literal, got: ${_OUT}"
else
  pass "lib/ix_query_intent regex literal"
fi

# Plain symbol → high-confidence exact match → block
run_hook ix-intercept.sh "${FX_IN}/grep_plain.json"
assert_block_decision "intercept/grep plain symbol blocks" "Next: ix read AuthService | ix explain AuthService"

# TODO marker → literal search, hook stays silent
run_hook ix-intercept.sh "${_GREP_TODO_FIXTURE}"
assert_empty "intercept/grep TODO literal"

# Phrase search → literal search, hook stays silent
run_hook ix-intercept.sh "${_GREP_PHRASE_FIXTURE}"
assert_empty "intercept/grep phrase literal"

# Dotted symbol → still treated as symbol lookup and blocks on exact match
run_hook ix-intercept.sh "${_GREP_DOTTED_SYMBOL_FIXTURE}"
assert_block_decision "intercept/grep dotted symbol blocks" "Found: AuthService (class) at src/auth.ts"

# Regex pattern → literal search, hook stays silent
run_hook ix-intercept.sh "${FX_IN}/grep_regex.json"
assert_empty "intercept/grep regex literal"

# Medium-confidence candidates → native Grep runs with additionalContext
run_hook ix-intercept.sh "${FX_IN}/grep_plain.json" \
  IX_MOCK_LOCATE_FILE="${FX_IX}/locate_candidates.json"
assert_additional_context "intercept/medium confidence candidates augment" "[ix text + ix locate]"

# Glob → inventory → block when result set is manageable
run_hook ix-intercept.sh "${FX_IN}/glob_path.json"
assert_block_decision "intercept/glob pattern blocks" "Next: ix overview AuthService"

# Glob with absolute repo path → normalize before inventory so ix can resolve it
run_hook ix-intercept.sh "${FX_IN}/glob_path_absolute.json" \
  IX_MOCK_EXPECT_INVENTORY_PATH="myrepo"
assert_block_decision "intercept/glob absolute path normalized" "Next: ix overview AuthService"

# Empty / no-tool input → exit 0, no output
run_hook ix-intercept.sh "${_EMPTY_FIXTURE}"
assert_empty "intercept/no-tool input"

# Secret pattern → silently skipped (IX_SKIP_SECRET_PATTERNS default 1)
run_hook ix-intercept.sh "${_SECRET_FIXTURE}"
assert_empty "intercept/secret pattern suppressed"

# ix failure → graceful degradation → no output
run_hook ix-intercept.sh "${FX_IN}/grep_plain.json" IX_MOCK_FAIL=1
assert_empty "intercept/ix failure degrades gracefully"

# Low-confidence locate → allow native Grep with no injection
run_hook ix-intercept.sh "${FX_IN}/grep_plain.json" \
  IX_MOCK_LOCATE_FILE="${FX_IX}/locate_low_confidence.json"
assert_empty "intercept/low confidence locate allows native Grep"

# Escape hatch disables blocking even for exact high-confidence matches
run_hook ix-intercept.sh "${FX_IN}/grep_plain.json" IX_BLOCK_ON_HIGH_CONFIDENCE=0
assert_additional_context "intercept/block escape hatch augments" "[ix text + ix locate]"

# Structured output format for block mode
run_hook ix-intercept.sh "${FX_IN}/grep_plain.json" IX_HOOK_OUTPUT_STYLE=structured
if [ "${_RC}" -ne 0 ]; then
  fail "intercept/structured block output mode" "expected exit 0, got ${_RC}"
elif [ -z "${_OUT}" ]; then
  fail "intercept/structured block output mode" "expected JSON output, got nothing"
elif ! echo "${_OUT}" | jq -e '.hookSpecificOutput.hookEventName == "PreToolUse" and .hookSpecificOutput.permissionDecision == "block" and (.hookSpecificOutput.reason | contains("Next: ix read AuthService"))' >/dev/null 2>&1; then
  fail "intercept/structured block output mode" "unexpected output: ${_OUT:0:180}"
else
  pass "intercept/structured block output mode"
fi

# ═════════════════════════════════════════════════════════════════════════════
# ix-read.sh
# ═════════════════════════════════════════════════════════════════════════════
section "ix-read.sh"

# Normal source file with high-risk overview → additionalContext
run_hook ix-read.sh "${FX_IN}/read_normal.json"
assert_additional_context "read/normal source file"

# Binary file → skipped by extension filter → no output
run_hook ix-read.sh "${FX_IN}/read_binary.json"
assert_empty "read/binary file skipped"

# Test file → SKIP_IMPACT=1 (impact not run), but overview still injects
run_hook ix-read.sh "${FX_IN}/read_test_file.json"
assert_additional_context "read/test file (impact skipped, overview injected)"

# Empty overview + low impact → both parts empty → no output
run_hook ix-read.sh "${FX_IN}/read_normal.json" \
  IX_MOCK_OVERVIEW_FILE="${FX_IX}/overview_empty.json" \
  IX_MOCK_IMPACT_FILE="${FX_IX}/impact_low.json"
assert_empty "read/empty overview + low impact → no output"

# ix returns error → graceful degradation → no output
run_hook ix-read.sh "${FX_IN}/read_normal.json" IX_MOCK_FAIL=1
assert_empty "read/ix failure degrades gracefully"

# Structured output format
run_hook ix-read.sh "${FX_IN}/read_normal.json" IX_HOOK_OUTPUT_STYLE=structured
assert_structured "read/structured output mode"

# ═════════════════════════════════════════════════════════════════════════════
# ix-pre-edit.sh — Edit and Write
# ═════════════════════════════════════════════════════════════════════════════
section "ix-pre-edit.sh"

# High-risk edit → warning injected
run_hook ix-pre-edit.sh "${FX_IN}/edit_high_risk.json"
assert_additional_context "pre-edit/high-risk edit warns"

# Low-risk edit → riskLevel=low → no output
run_hook ix-pre-edit.sh "${FX_IN}/edit_low_risk.json" \
  IX_MOCK_IMPACT_FILE="${FX_IX}/impact_low.json"
assert_empty "pre-edit/low-risk edit silent"

# Markdown file → skipped by extension filter → no output
run_hook ix-pre-edit.sh "${_EDIT_MD_FIXTURE}"
assert_empty "pre-edit/markdown file skipped"

# Write new file (no .md) → impact runs; high-risk fixture → warning injected
run_hook ix-pre-edit.sh "${FX_IN}/write_new_file.json"
assert_additional_context "pre-edit/write new file warns (high risk)"

# ix returns error → graceful degradation → no output
run_hook ix-pre-edit.sh "${FX_IN}/edit_high_risk.json" IX_MOCK_FAIL=1
assert_empty "pre-edit/ix failure degrades gracefully"

# Structured output format
run_hook ix-pre-edit.sh "${FX_IN}/edit_high_risk.json" IX_HOOK_OUTPUT_STYLE=structured
assert_structured "pre-edit/structured output mode"

# ═════════════════════════════════════════════════════════════════════════════
# ix-bash.sh — Bash grep intercept
# ═════════════════════════════════════════════════════════════════════════════
section "ix-bash.sh"

# bash grep command → text + locate → additionalContext
run_hook ix-bash.sh "${_BASH_GREP_FIXTURE}"
assert_additional_context "bash/grep intercepted"

# Non-grep command (ls) → not intercepted → no output
run_hook ix-bash.sh "${_BASH_LS_FIXTURE}"
assert_empty "bash/non-grep command skipped"

# No-tool input → exit 0, no output
run_hook ix-bash.sh "${_EMPTY_FIXTURE}"
assert_empty "bash/no-tool input"

# Secret pattern in grep → silently skipped
run_hook ix-bash.sh "${_SECRET_BASH_FIXTURE}"
assert_empty "bash/secret pattern suppressed"

# ix returns error → graceful degradation → no output
run_hook ix-bash.sh "${_BASH_GREP_FIXTURE}" IX_MOCK_FAIL=1
assert_empty "bash/ix failure degrades gracefully"

# Structured output format
run_hook ix-bash.sh "${_BASH_GREP_FIXTURE}" IX_HOOK_OUTPUT_STYLE=structured
assert_structured "bash/structured output mode"

# ═════════════════════════════════════════════════════════════════════════════
# ix-annotate.sh — Stop hook attribution
# ═════════════════════════════════════════════════════════════════════════════
section "ix-annotate.sh"

_annotate_tmp=$(mktemp -d -p "${TEST_TMPDIR}")
_annotate_home="${_annotate_tmp}/home"
mkdir -p "${_annotate_home}"
_STOP_FIXTURE=$(mktemp -p "${TEST_TMPDIR}" --suffix=.json)
printf '{"session_id":"test-session-001"}' > "${_STOP_FIXTURE}"

_seed_rc=0
env \
  HOME="${_annotate_home}" \
  TMPDIR="${_annotate_tmp}" \
  IX_HEALTH_CACHE="${_annotate_tmp}/ix-healthy" \
  IX_MAP_LOCK_PATH="${_annotate_tmp}/ix-map.lock" \
  IX_LEDGER_MODE="on" \
  IX_INGEST_INJECT="off" \
  IX_ERROR_MODE="off" \
  PATH="${TESTS_DIR}:${PATH}" \
  bash "${HOOKS_DIR}/ix-intercept.sh" < "${FX_IN}/grep_plain.json" >/dev/null 2>/dev/null || _seed_rc=$?

if [ "${_seed_rc}" -ne 0 ]; then
  fail "annotate/seed ledger" "expected intercept hook to succeed, got ${_seed_rc}"
else
  _RC=0
  _OUT=$(env \
    HOME="${_annotate_home}" \
    TMPDIR="${_annotate_tmp}" \
    IX_ANNOTATE_MODE="brief" \
    IX_ANNOTATE_CHANNEL="systemMessage" \
    IX_LEDGER_MODE="on" \
    IX_ERROR_MODE="off" \
    PATH="${TESTS_DIR}:${PATH}" \
    bash "${HOOKS_DIR}/ix-annotate.sh" < "${_STOP_FIXTURE}" 2>/dev/null) || _RC=$?
  assert_system_message "annotate/stop hook emits ix summary" "Ix helped by surfacing a relevant symbol before search."
  assert_no_hook_specific_output "annotate/stop hook uses top-level output contract"

  _RC=0
  _OUT=$(env \
    HOME="${_annotate_home}" \
    TMPDIR="${_annotate_tmp}" \
    IX_ANNOTATE_MODE="brief" \
    IX_ANNOTATE_CHANNEL="modelSuffix" \
    IX_LEDGER_MODE="on" \
    IX_ERROR_MODE="off" \
    PATH="${TESTS_DIR}:${PATH}" \
    bash "${HOOKS_DIR}/ix-annotate.sh" < "${_STOP_FIXTURE}" 2>/dev/null) || _RC=$?
  assert_empty "annotate/modelSuffix mode stays silent"
fi

_annotate_missing_ledger_tmp=$(mktemp -d -p "${TEST_TMPDIR}")
_annotate_missing_ledger_home="${_annotate_missing_ledger_tmp}/home"
mkdir -p "${_annotate_missing_ledger_home}"
_annotate_missing_ledger_lib="${_annotate_missing_ledger_tmp}/index.sh"
cat > "${_annotate_missing_ledger_lib}" <<EOF
#!/usr/bin/env bash
source "${HOOKS_DIR}/ix-errors.sh" 2>/dev/null || true
source "${HOOKS_DIR}/ix-lib.sh"
EOF

_RC=0
_OUT=$(env \
  HOME="${_annotate_missing_ledger_home}" \
  TMPDIR="${_annotate_missing_ledger_tmp}" \
  IX_ANNOTATE_MODE="brief" \
  IX_ANNOTATE_CHANNEL="systemMessage" \
  IX_LEDGER_MODE="on" \
  IX_ERROR_MODE="off" \
  IX_HOOK_LIB_INDEX="${_annotate_missing_ledger_lib}" \
  PATH="${TESTS_DIR}:${PATH}" \
  bash "${HOOKS_DIR}/ix-annotate.sh" < "${_STOP_FIXTURE}" 2>/dev/null) || _RC=$?
assert_system_message "annotate/missing ledger helper emits fallback" "ledger helpers are missing"

_annotate_edit_tmp=$(mktemp -d -p "${TEST_TMPDIR}")
_annotate_edit_home="${_annotate_edit_tmp}/home"
mkdir -p "${_annotate_edit_home}"

_seed_edit_rc=0
_OUT=$(env \
  HOME="${_annotate_edit_home}" \
  TMPDIR="${_annotate_edit_tmp}" \
  IX_HEALTH_CACHE="${_annotate_edit_tmp}/ix-healthy" \
  IX_MAP_LOCK_PATH="${_annotate_edit_tmp}/ix-map.lock" \
  IX_LEDGER_MODE="on" \
  IX_ERROR_MODE="off" \
  PATH="${TESTS_DIR}:${PATH}" \
  bash "${HOOKS_DIR}/ix-pre-edit.sh" < "${FX_IN}/edit_high_risk.json" >/dev/null 2>/dev/null) || _seed_edit_rc=$?

if [ "${_seed_edit_rc}" -ne 0 ]; then
  fail "annotate/seed edit ledger" "expected pre-edit hook to succeed, got ${_seed_edit_rc}"
else
  _RC=0
  _OUT=$(env \
    HOME="${_annotate_edit_home}" \
    TMPDIR="${_annotate_edit_tmp}" \
    IX_ANNOTATE_MODE="brief" \
    IX_ANNOTATE_CHANNEL="systemMessage" \
    IX_LEDGER_MODE="on" \
    IX_ERROR_MODE="off" \
    PATH="${TESTS_DIR}:${PATH}" \
    bash "${HOOKS_DIR}/ix-annotate.sh" < "${_STOP_FIXTURE}" 2>/dev/null) || _RC=$?
  assert_system_message "annotate/post-decision nudge after edits" "prompting you to note what changed, why, and any follow-ups after 1 edit(s)."
fi

# ═════════════════════════════════════════════════════════════════════════════
# ix not in PATH — one-time systemMessage notification
# ═════════════════════════════════════════════════════════════════════════════
section "ix unavailable notification"

_no_ix_tmp=$(mktemp -d -p "${TEST_TMPDIR}")
_RC=0
_OUT=$(env \
  TMPDIR="${_no_ix_tmp}" \
  IX_HEALTH_CACHE="${_no_ix_tmp}/ix-healthy" \
  IX_LEDGER_MODE="off" \
  IX_ERROR_MODE="off" \
  PATH="/usr/bin:/bin" \
  bash "${HOOKS_DIR}/ix-intercept.sh" < "${FX_IN}/grep_plain.json" 2>/dev/null) || _RC=$?

_notify_name="unavailable/first hook fire emits systemMessage"
if [ "${_RC}" -ne 0 ]; then
  fail "${_notify_name}" "expected exit 0, got ${_RC}"
elif [ -z "${_OUT}" ]; then
  fail "${_notify_name}" "expected systemMessage JSON, got nothing"
elif ! echo "${_OUT}" | jq -e '.systemMessage' >/dev/null 2>&1; then
  fail "${_notify_name}" "expected .systemMessage key — output: ${_OUT:0:100}"
else
  pass "${_notify_name}"
fi

# Second fire with same sentinel file → should be silent
_RC2=0
_OUT2=$(env \
  TMPDIR="${_no_ix_tmp}" \
  IX_HEALTH_CACHE="${_no_ix_tmp}/ix-healthy" \
  IX_LEDGER_MODE="off" \
  IX_ERROR_MODE="off" \
  PATH="/usr/bin:/bin" \
  bash "${HOOKS_DIR}/ix-intercept.sh" < "${FX_IN}/grep_plain.json" 2>/dev/null) || _RC2=$?

_silence_name="unavailable/subsequent hook fires are silent"
if [ "${_RC2}" -ne 0 ]; then
  fail "${_silence_name}" "expected exit 0, got ${_RC2}"
elif [ -n "${_OUT2}" ]; then
  fail "${_silence_name}" "expected no output on 2nd fire, got: ${_OUT2:0:100}"
else
  pass "${_silence_name}"
fi

# ═════════════════════════════════════════════════════════════════════════════
# Summary
# ═════════════════════════════════════════════════════════════════════════════
printf '\n══════════════════════════════════════════════════════\n'
printf 'Results: %d passed, %d failed\n' "${PASS_COUNT}" "${FAIL_COUNT}"
printf '══════════════════════════════════════════════════════\n'

[ "${FAIL_COUNT}" -eq 0 ]
