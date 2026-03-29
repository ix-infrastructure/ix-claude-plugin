#!/usr/bin/env bash
# ix-pre-edit.sh — PreToolUse hook for Edit / Write / MultiEdit
#
# Fires before Claude edits or creates a file. Runs ix impact on the target
# file and injects a one-line blast-radius warning when the file has
# significant dependents. High-risk edits get a clear signal before damage
# is done.
#
# Exit 0 + JSON stdout → injects additionalContext, tool still runs
# Exit 0 + no stdout  → no-op, tool runs normally

set -euo pipefail

INPUT=$(cat)
TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty')
[ -z "$TOOL" ] && exit 0

# Get the file path being edited/written
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
[ -z "$FILE_PATH" ] && exit 0

# Skip non-code and config files — not worth warning on these
case "$FILE_PATH" in
  *.md|*.txt|*.lock|*.png|*.jpg|*.gif|*.ico|*.pdf|*.bin) exit 0 ;;
  *__pycache__*|*.pyc|*.class|*.o) exit 0 ;;
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

# ── Run impact on the filename ────────────────────────────────────────────────
FILENAME=$(basename "$FILE_PATH")

_imp_err=$(mktemp)
RAW=$(ix impact "$FILENAME" --format json 2>"$_imp_err") || {
  _exit=$?
  ix_capture_async "ix" "ix-impact" "ix impact failed for $FILENAME" "$_exit" \
    "ix impact $FILENAME" "$(head -3 "$_imp_err")"
  rm -f "$_imp_err"
  exit 0
}
rm -f "$_imp_err"
[ -z "$RAW" ] && exit 0

# Strip "Update available" header, extract the JSON object
IMPACT_JSON=$(echo "$RAW" | awk '/^\{/{found=1} found{print}' | jq -c . 2>/dev/null) || exit 0
[ -z "$IMPACT_JSON" ] && exit 0

# ── Parse key fields ──────────────────────────────────────────────────────────
RISK_LEVEL=$(echo "$IMPACT_JSON"    | jq -r '.riskLevel // "unknown"')
DIRECT_DEPS=$(echo "$IMPACT_JSON"   | jq -r '.summary.directDependents // 0')
MEMBER_CALLERS=$(echo "$IMPACT_JSON"| jq -r '.summary.memberLevelCallers // 0')
RISK_SUMMARY=$(echo "$IMPACT_JSON"  | jq -r '.riskSummary // ""')
TOP_MEMBERS=$(echo "$IMPACT_JSON"   | jq -r '[.topImpactedMembers[:3][].name] | join(", ")' 2>/dev/null || echo "")
NEXT_STEP=$(echo "$IMPACT_JSON"     | jq -r '.nextStep // ""')

# Use whichever count is higher — directDependents for symbols, memberLevelCallers for files
EFFECTIVE_DEPS=$(( DIRECT_DEPS > MEMBER_CALLERS ? DIRECT_DEPS : MEMBER_CALLERS ))

# ── Only warn when impact is meaningful ──────────────────────────────────────
[ "$RISK_LEVEL" = "unknown" ] && exit 0
[ "$RISK_LEVEL" = "low" ] && exit 0
# Require at least 3 effective dependents to avoid noise on leaf files
[ "${EFFECTIVE_DEPS:-0}" -lt 3 ] 2>/dev/null && exit 0

# ── Format one-line warning ───────────────────────────────────────────────────
case "$RISK_LEVEL" in
  critical) PREFIX="[ix] ⚠️  CRITICAL EDIT" ;;
  high)     PREFIX="[ix] ⚠️  HIGH-RISK EDIT" ;;
  medium)   PREFIX="[ix] NOTE" ;;
  *)        exit 0 ;;
esac

WARNING="${PREFIX} — ${FILENAME} has ${EFFECTIVE_DEPS} dependents. ${RISK_SUMMARY}"
[ -n "$TOP_MEMBERS" ] && WARNING="${WARNING} Hot spots: ${TOP_MEMBERS}."
[ -n "$NEXT_STEP" ]   && WARNING="${WARNING} → ${NEXT_STEP}"

jq -n --arg ctx "$WARNING" '{"additionalContext": $ctx}'
exit 0
