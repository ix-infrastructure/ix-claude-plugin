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
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')

# Skip non-code and config files — not worth warning on these
case "$FILE_PATH" in
  *.md|*.txt|*.lock|*.png|*.jpg|*.gif|*.ico|*.pdf|*.bin) exit 0 ;;
  *__pycache__*|*.pyc|*.class|*.o) exit 0 ;;
esac

# ── Shared library ────────────────────────────────────────────────────────────
_HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_HOOK_DIR}/lib/index.sh"

ix_health_check
IX_HOOK_NAME="ix-pre-edit"
_t0=$(ix_now_ms)
ix_log "ENTRY tool=$TOOL file=$FILE_PATH"

# ── Run impact on the file ────────────────────────────────────────────────────
FILENAME=$(basename "$FILE_PATH")

# Compute repo-relative path for ix calls (avoids wrong-file selection in repos
# with duplicate basenames).
if [[ "$FILE_PATH" == /* ]] && [ -n "$CWD" ]; then
  REL_PATH="${FILE_PATH#$CWD/}"
elif [[ "$FILE_PATH" != /* ]]; then
  REL_PATH="$FILE_PATH"
else
  REL_PATH="$FILENAME"
fi

ix_log "RUN ix impact $REL_PATH"
_imp_err=$(mktemp)
ix_log_command ix impact "$REL_PATH" --format json
RAW=$(ix impact "$REL_PATH" --format json 2>"$_imp_err") || {
  _exit=$?
  ix_capture_async "ix" "ix-impact" "ix impact failed for $REL_PATH" "$_exit" \
    "ix impact $REL_PATH" "$(head -3 "$_imp_err")"
  ix_log "FAILED ix impact exit=$_exit"
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

ix_log "IMPACT risk=$RISK_LEVEL deps=$EFFECTIVE_DEPS file=$REL_PATH"

# ── Only warn when impact is meaningful ──────────────────────────────────────
[ "$RISK_LEVEL" = "unknown" ] && { ix_log "SKIP risk=unknown (not in graph)"; exit 0; }
[ "$RISK_LEVEL" = "low" ] && {
  ix_ledger_append "PreToolUse" "Edit" "1" "impact" "1" "${RISK_LEVEL:-}" "0" \
    "checked impact for ${FILENAME} and confirmed it was low risk with no broad blast radius."
  ix_log "SKIP risk=low (no warning needed)"
  exit 0
}
# Require at least 3 effective dependents to avoid noise on leaf files
[ "${EFFECTIVE_DEPS:-0}" -lt 3 ] 2>/dev/null && { ix_log "SKIP deps=$EFFECTIVE_DEPS < 3 threshold"; exit 0; }

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

_elapsed_ms=$(( $(ix_now_ms) - _t0 ))
ix_log "DECISION warn risk=$RISK_LEVEL deps=$EFFECTIVE_DEPS (${_elapsed_ms}ms)"
ix_ledger_append "PreToolUse" "Edit" "${#WARNING}" "impact" "1" "${RISK_LEVEL:-}" "$_elapsed_ms" \
  "checked impact for ${FILENAME} and flagged ${RISK_LEVEL} risk across ${EFFECTIVE_DEPS} dependents."

if [ "${IX_HOOK_OUTPUT_STYLE:-legacy}" = "structured" ]; then
  jq -n --arg ctx "$WARNING" '{
    "hookSpecificOutput": {
      "hookEventName": "PreToolUse",
      "permissionDecision": "allow",
      "additionalContext": $ctx
    }
  }'
else
  jq -n --arg ctx "$WARNING" '{"additionalContext": $ctx}'
fi
exit 0
