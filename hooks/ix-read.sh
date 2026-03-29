#!/usr/bin/env bash
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

# Skip binary/generated/vendor files
case "$FILE_PATH" in
  *.png|*.jpg|*.jpeg|*.gif|*.ico|*.pdf|*.zip|*.tar|*.gz|*.bin|*.exe) exit 0 ;;
  */node_modules/*|*/.git/*|*/dist/*|*/build/*|*/generated/*|*/__pycache__/*) exit 0 ;;
  */package-lock.json|*/yarn.lock|*/pnpm-lock.yaml|*/go.sum|*/Cargo.lock) exit 0 ;;
esac

command -v ix >/dev/null 2>&1 || exit 0

# ── Error reporting ───────────────────────────────────────────────────────────
_HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_HOOK_DIR}/ix-errors.sh" 2>/dev/null || true

# ── Health check (30s TTL cache) ──────────────────────────────────────────────
IX_HEALTH_CACHE="${TMPDIR:-/tmp}/ix-healthy"
_now=$(date +%s)
_cache_ok=0
if [ -f "$IX_HEALTH_CACHE" ]; then
  _cached=$(cat "$IX_HEALTH_CACHE" 2>/dev/null || echo 0)
  (( (_now - _cached) < 30 )) && _cache_ok=1
fi
if [ "$_cache_ok" -eq 0 ]; then
  ix status >/dev/null 2>&1 || exit 0
  echo "$_now" > "$IX_HEALTH_CACHE"
fi

# ── Per-file TTL cache (5 min) — avoid repeating context for the same file ───
IX_READ_CACHE_DIR="${TMPDIR:-/tmp}/ix-read-cache"
mkdir -p "$IX_READ_CACHE_DIR" 2>/dev/null || true
_file_key=$(printf '%s' "$FILE_PATH" | md5sum | cut -d' ' -f1)
_read_cache="$IX_READ_CACHE_DIR/$_file_key"
if [ -f "$_read_cache" ]; then
  _cached_read=$(cat "$_read_cache" 2>/dev/null || echo 0)
  (( (_now - _cached_read) < 300 )) && exit 0
fi
echo "$_now" > "$_read_cache"

# ── Helper: strip ix header noise, extract JSON ───────────────────────────────
parse_json() {
  echo "$1" | awk '/^\[|^\{/{found=1} found{print}' | jq -c . 2>/dev/null || echo ""
}

# ── Run ix inventory + ix overview + ix impact in parallel ───────────────────
FILENAME=$(basename "$FILE_PATH")
BASENAME="${FILENAME%.*}"

_inv_tmp=$(mktemp)
_ov_tmp=$(mktemp)
_imp_tmp=$(mktemp)
_inv_err=$(mktemp)
_ov_err=$(mktemp)
_imp_err=$(mktemp)
trap 'rm -f "$_inv_tmp" "$_ov_tmp" "$_imp_tmp" "$_inv_err" "$_ov_err" "$_imp_err"' EXIT

ix inventory --kind file --path "$FILENAME" --format json > "$_inv_tmp" 2>"$_inv_err" &
_INV_PID=$!
ix overview "$FILENAME" --format json                     > "$_ov_tmp"  2>"$_ov_err"  &
_OV_PID=$!
ix impact   "$FILENAME" --format json                     > "$_imp_tmp" 2>"$_imp_err" &
_IMP_PID=$!

wait $_INV_PID || ix_capture_async "ix" "ix-inventory" "inventory failed" "$?" \
  "ix inventory $FILENAME" "$(head -3 "$_inv_err")"
wait $_OV_PID  || ix_capture_async "ix" "ix-overview"  "overview failed"  "$?" \
  "ix overview $FILENAME"  "$(head -3 "$_ov_err")"
wait $_IMP_PID || ix_capture_async "ix" "ix-impact"    "impact failed"    "$?" \
  "ix impact $FILENAME"    "$(head -3 "$_imp_err")"

INV_RAW=$(cat "$_inv_tmp")
OV_RAW=$(cat "$_ov_tmp")
IMP_RAW=$(cat "$_imp_tmp")

[ -z "$INV_RAW" ] && [ -z "$OV_RAW" ] && exit 0

# ── Summarise overview: key definitions + children ────────────────────────
OV_JSON=$(parse_json "$OV_RAW")
ENTITY_PART=""
if [ -n "$OV_JSON" ]; then
  KEY_ITEMS=$(echo "$OV_JSON" | jq -r '[.keyItems[:5][].name] | join(", ")' 2>/dev/null || echo "")
  CHILDREN=$(echo "$OV_JSON" | jq -r '[.childrenByKind // {} | to_entries[] | "\(.value) \(.key)"] | join(", ")' 2>/dev/null || echo "")
  if [ -n "$KEY_ITEMS" ]; then
    ENTITY_PART="key: ${KEY_ITEMS}"
    [ -n "$CHILDREN" ] && ENTITY_PART="${ENTITY_PART} (${CHILDREN})"
  fi
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

CONTEXT="[ix] ${FILENAME}"
[ -n "$ENTITY_PART" ] && CONTEXT="${CONTEXT} — ${ENTITY_PART}"
[ -n "$RISK_PART" ]   && CONTEXT="${CONTEXT} | ${RISK_PART}"
CONTEXT="${CONTEXT} | Use ix read <symbol> to get just a symbol's source instead of the full file"

jq -n --arg ctx "$CONTEXT" '{"additionalContext": $ctx}'
exit 0
