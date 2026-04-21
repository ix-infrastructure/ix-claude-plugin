#!/usr/bin/env bash
# DISABLED — removed from hooks.json per Phase E spec; not active at runtime.
# The additive Read hook added 3 ix commands of overhead without preventing
# the file read. Behavioral steering is handled by CLAUDE.md + briefing hook.
# To re-enable: add Read matcher back to hooks.json.
# Optional future use: fire only for files >300 lines with high graph coverage.
#
# ix-read.sh — PreToolUse hook for Read
#
# Fires before Claude reads a file. Runs ix inventory + ix overview + ix impact
# in parallel and injects a CONCISE one-line summary as additionalContext.
#
# Format: "[ix] file.ts — N entities: A (class), B (fn), C (fn) | 12 dependents — HIGH RISK"
# Not raw JSON dumps. Designed to be acted on, not skipped over.
#
# Exit 0 + JSON stdout → injects additionalContext, Read still runs
# Exit 0 + no stdout  → no-op, Read runs normally

set -euo pipefail

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
[ -z "$FILE_PATH" ] && exit 0
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')

# Skip binary/generated/vendor files
case "$FILE_PATH" in
  *.png|*.jpg|*.jpeg|*.gif|*.ico|*.pdf|*.zip|*.tar|*.gz|*.bin|*.exe) exit 0 ;;
  */node_modules/*|*/.git/*|*/dist/*|*/build/*|*/generated/*|*/__pycache__/*) exit 0 ;;
  */package-lock.json|*/yarn.lock|*/pnpm-lock.yaml|*/go.sum|*/Cargo.lock) exit 0 ;;
esac

# Skip ix impact for test/config/small files — they have no meaningful dependents
SKIP_IMPACT=0
case "$FILE_PATH" in
  */test/*|*/tests/*|*/spec/*|*/__tests__/*|*/__mocks__/*) SKIP_IMPACT=1 ;;
  *.test.*|*.spec.*|*_test.*)                              SKIP_IMPACT=1 ;;
  *.config.*|*.yaml|*.yml|*.toml|*.ini|*.env|*.env.*)     SKIP_IMPACT=1 ;;
  *tsconfig*.json|*jsconfig*.json)                         SKIP_IMPACT=1 ;;
  */config/*|*/configs/*)                                  SKIP_IMPACT=1 ;;
esac
# Also skip for small files (< 50 lines) — impact not meaningful at that scale
if [ "$SKIP_IMPACT" -eq 0 ] && [ -f "$FILE_PATH" ]; then
  _line_count=$(wc -l < "$FILE_PATH" 2>/dev/null || echo 0)
  [ "${_line_count:-0}" -lt 50 ] && SKIP_IMPACT=1
fi

# ── Shared library ────────────────────────────────────────────────────────────
_HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_HOOK_DIR}/lib/index.sh"

_now=$(date +%s)
ix_health_check
_t0=$(ix_now_ms)

# ── Per-file TTL cache (5 min) — avoid repeating context for the same file ───
IX_READ_CACHE_DIR="${TMPDIR:-/tmp}/ix-read-cache"
mkdir -p "$IX_READ_CACHE_DIR" 2>/dev/null || true
_file_key=$(hash_string "$FILE_PATH")
_read_cache="$IX_READ_CACHE_DIR/$_file_key"
if [ -f "$_read_cache" ]; then
  _cached_read=$(cat "$_read_cache" 2>/dev/null || echo 0)
  (( (_now - _cached_read) < 300 )) && exit 0
fi
echo "$_now" > "$_read_cache"

# ── Run ix inventory + ix overview + ix impact in parallel ───────────────────
FILENAME=$(basename "$FILE_PATH")
BASENAME="${FILENAME%.*}"

# Compute repo-relative path for ix calls (avoids wrong-file selection in repos
# with duplicate basenames).
if [[ "$FILE_PATH" == /* ]] && [ -n "$CWD" ]; then
  REL_PATH="${FILE_PATH#$CWD/}"
elif [[ "$FILE_PATH" != /* ]]; then
  REL_PATH="$FILE_PATH"
else
  REL_PATH="$FILENAME"
fi

_inv_tmp=$(mktemp)
_ov_tmp=$(mktemp)
_imp_tmp=$(mktemp)
_inv_err=$(mktemp)
_ov_err=$(mktemp)
_imp_err=$(mktemp)
trap 'rm -f "$_inv_tmp" "$_ov_tmp" "$_imp_tmp" "$_inv_err" "$_ov_err" "$_imp_err"' EXIT

ix inventory --kind file --path "$REL_PATH" --format json > "$_inv_tmp" 2>"$_inv_err" &
_INV_PID=$!
ix overview "$REL_PATH" --format json                     > "$_ov_tmp"  2>"$_ov_err"  &
_OV_PID=$!
_IMP_PID=""
if [ "$SKIP_IMPACT" -eq 0 ]; then
  ix impact "$REL_PATH" --format json                     > "$_imp_tmp" 2>"$_imp_err" &
  _IMP_PID=$!
fi

wait $_INV_PID || ix_capture_async "ix" "ix-inventory" "inventory failed" "$?" \
  "ix inventory $REL_PATH" "$(head -3 "$_inv_err")"
wait $_OV_PID  || ix_capture_async "ix" "ix-overview"  "overview failed"  "$?" \
  "ix overview $REL_PATH"  "$(head -3 "$_ov_err")"
[ -n "$_IMP_PID" ] && { wait $_IMP_PID || ix_capture_async "ix" "ix-impact" "impact failed" "$?" \
  "ix impact $REL_PATH"    "$(head -3 "$_imp_err")"; }

INV_RAW=$(cat "$_inv_tmp")
OV_RAW=$(cat "$_ov_tmp")
IMP_RAW=$(cat "$_imp_tmp")

[ -z "$INV_RAW" ] && [ -z "$OV_RAW" ] && exit 0

# ── Summarise overview: key definitions + children ────────────────────────
OV_JSON=$(parse_json "$OV_RAW")
ENTITY_PART=""
CONF_WARN=""
KEY_ITEMS=""
if [ -n "$OV_JSON" ]; then
  # Gate on graph confidence before injecting structural data
  _confidence=$(echo "$OV_JSON" | jq -r '(.confidence // 1) | tostring' 2>/dev/null || echo "1")
  ix_confidence_gate "${_confidence:-1}"
  [ "$CONF_GATE" = "drop" ] && exit 0
  KEY_ITEMS=$(echo "$OV_JSON" | jq -r '[.keyItems[:5][].name] | join(", ")' 2>/dev/null || echo "")
  CHILDREN=$(echo "$OV_JSON" | jq -r '[.childrenByKind // {} | to_entries[] | "\(.value) \(.key)"] | join(", ")' 2>/dev/null || echo "")
  if [ -n "$KEY_ITEMS" ]; then
    ENTITY_PART="key: ${KEY_ITEMS}"
    [ -n "$CHILDREN" ] && ENTITY_PART="${ENTITY_PART} (${CHILDREN})"
  fi
fi

# ── Build read hint using first key item ─────────────────────────────────────
if [ -n "$KEY_ITEMS" ]; then
  _first_item=$(printf '%s' "$KEY_ITEMS" | cut -d',' -f1 | tr -d ' ')
  READ_HINT="Use \`ix read ${_first_item}\` to read a symbol instead of the full file"
else
  READ_HINT="Use \`ix read <symbol>\` to read a symbol instead of the full file"
fi

# ── Summarise impact: risk warning ────────────────────────────────────────────
IMP_JSON=$(parse_json "$IMP_RAW")
RISK_PART=""
if [ -n "$IMP_JSON" ]; then
  RISK_LEVEL=$(echo "$IMP_JSON"    | jq -r '.riskLevel // "unknown"' 2>/dev/null || echo "")
  DIRECT_DEPS=$(echo "$IMP_JSON"   | jq -r '.summary.directDependents // 0' 2>/dev/null || echo 0)
  MEMBER_CALLERS=$(echo "$IMP_JSON"| jq -r '.summary.memberLevelCallers // 0' 2>/dev/null || echo 0)
  EFF_DEPS=$(( DIRECT_DEPS > MEMBER_CALLERS ? DIRECT_DEPS : MEMBER_CALLERS ))
  if [ "${EFF_DEPS:-0}" -gt 2 ] && [ "$RISK_LEVEL" != "low" ] && [ "$RISK_LEVEL" != "unknown" ]; then
    case "$RISK_LEVEL" in
      critical) RISK_PART="⚠️  CRITICAL: ${EFF_DEPS} dependents" ;;
      high)     RISK_PART="⚠️  HIGH RISK: ${EFF_DEPS} dependents" ;;
      medium)   RISK_PART="${EFF_DEPS} dependents" ;;
    esac
  fi
fi

[ -z "$ENTITY_PART" ] && [ -z "$RISK_PART" ] && exit 0

_cmds="ix inventory + ix overview"
[ "$SKIP_IMPACT" -eq 0 ] && _cmds="${_cmds} + ix impact"
_stderr_line="${_cmds}: ${FILENAME}"
[ -n "$ENTITY_PART" ] && _stderr_line="${_stderr_line} → ${ENTITY_PART}"
[ -n "$RISK_PART" ]   && _stderr_line="${_stderr_line} | ${RISK_PART}"
echo "$_stderr_line" >&2

CONTEXT="[${_cmds}] ${FILENAME}"
[ -n "$ENTITY_PART" ] && CONTEXT="${CONTEXT} — ${ENTITY_PART}"
[ -n "$RISK_PART" ]   && CONTEXT="${CONTEXT} | ${RISK_PART}"
CONTEXT="${CONTEXT} | ${READ_HINT}"
[ -n "$CONF_WARN" ]   && CONTEXT="${CONF_WARN} | ${CONTEXT}"

_elapsed_ms=$(( $(ix_now_ms) - _t0 ))
ix_ledger_append "PreToolUse" "Read" "${#CONTEXT}" "inventory,overview,impact" "${_confidence:-1}" "${RISK_LEVEL:-}" "$_elapsed_ms"

if [ "${IX_HOOK_OUTPUT_STYLE:-legacy}" = "structured" ]; then
  jq -n --arg ctx "$CONTEXT" '{
    "hookSpecificOutput": {
      "hookEventName": "PreToolUse",
      "permissionDecision": "allow",
      "additionalContext": $ctx
    }
  }'
else
  jq -n --arg ctx "$CONTEXT" '{"additionalContext": $ctx}'
fi
exit 0
