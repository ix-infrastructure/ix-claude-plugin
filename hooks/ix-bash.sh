#!/usr/bin/env bash
# ix-bash.sh — PreToolUse hook for Bash
#
# Fires before Claude runs a Bash command. Detects grep/rg search patterns and
# front-runs them with ix text + ix locate for graph-aware results.
#
# Output is a CONCISE one-line summary — not raw JSON dumps.
#
# Exit 0 + JSON stdout → injects additionalContext, Bash still runs
# Exit 0 + no stdout  → no-op, Bash runs normally

set -euo pipefail

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
[ -z "$COMMAND" ] && exit 0

# Only intercept grep/rg invocations
echo "$COMMAND" | grep -qE '^\s*(grep|rg)\s' || exit 0

# ── Shared library ────────────────────────────────────────────────────────────
_HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_HOOK_DIR}/lib/index.sh"

ix_health_check
_t0=$(date +%s%3N 2>/dev/null || echo 0)

# ── Extract search pattern from command ────────────────────────────────────────
PATTERN=""
PATTERN=$(echo "$COMMAND" | sed -E 's/.*\s"([^"]+)".*/\1/' 2>/dev/null) || PATTERN=""
if [ -z "$PATTERN" ] || [ "$PATTERN" = "$COMMAND" ]; then
  PATTERN=$(echo "$COMMAND" | sed -E "s/.*\s'([^']+)'.*/\1/" 2>/dev/null) || PATTERN=""
fi
if [ -z "$PATTERN" ] || [ "$PATTERN" = "$COMMAND" ]; then
  PATTERN=$(echo "$COMMAND" | sed -E 's/^\s*(grep|rg)\s+(-[a-zA-Z0-9]+\s+|--[a-zA-Z-]+=\S+\s+)*([^-][^ ]*).*/\3/' 2>/dev/null) || PATTERN=""
fi

[ -z "$PATTERN" ] && exit 0
[ ${#PATTERN} -lt 3 ] && exit 0
if [ "${IX_SKIP_SECRET_PATTERNS:-1}" = "1" ] && ix_looks_like_secret "$PATTERN"; then
  exit 0
fi

# ── Run ix text + ix locate in parallel ───────────────────────────────────────
ix_run_text_locate "$PATTERN"

[ -z "$_TEXT_RAW" ] && [ -z "$_LOC_RAW" ] && exit 0

# ── Summarise results ─────────────────────────────────────────────────────────
ix_summarize_text "$_TEXT_RAW"
ix_summarize_locate "$_LOC_RAW"

[ -z "$TEXT_PART" ] && [ -z "$LOC_PART" ] && exit 0

CONTEXT="[ix] bash grep intercepted for '${PATTERN}'"
[ -n "$LOC_PART" ]  && CONTEXT="${CONTEXT} — ${LOC_PART}"
[ -n "$TEXT_PART" ] && CONTEXT="${CONTEXT} | ${TEXT_PART}"
CONTEXT="${CONTEXT} | Prefer: ix text '${PATTERN}' or ix locate '${PATTERN}' over shell grep"

_elapsed_ms=$(( $(date +%s%3N 2>/dev/null || echo 0) - _t0 ))
ix_ledger_append "PreToolUse" "Bash" "${#CONTEXT}" "text,locate" "1" "" "$_elapsed_ms"

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
