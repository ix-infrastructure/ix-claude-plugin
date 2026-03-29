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

# ── Helper: strip ix header noise, extract JSON ───────────────────────────────
parse_json() {
  echo "$1" | awk '/^\[|^\{/{found=1} found{print}' | jq -c . 2>/dev/null || echo ""
}

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

# ── Run ix text + ix locate in parallel ───────────────────────────────────────
_text_tmp=$(mktemp)
_loc_tmp=$(mktemp)
_text_err=$(mktemp)
_loc_err=$(mktemp)
trap 'rm -f "$_text_tmp" "$_loc_tmp" "$_text_err" "$_loc_err"' EXIT

ix text "$PATTERN" --limit 15 --format json > "$_text_tmp" 2>"$_text_err" &
_TEXT_PID=$!

_is_plain=1
echo "$PATTERN" | grep -qE '[\\^$\[\](){}|*+?]' && _is_plain=0
_LOC_PID=""
if [ "$_is_plain" -eq 1 ]; then
  ix locate "$PATTERN" --limit 5 --format json > "$_loc_tmp" 2>"$_loc_err" &
  _LOC_PID=$!
fi

wait $_TEXT_PID || ix_capture_async "ix" "ix-text" "text search failed" "$?" \
  "ix text '${PATTERN}'" "$(head -3 "$_text_err")"
[ -n "$_LOC_PID" ] && {
  wait $_LOC_PID || ix_capture_async "ix" "ix-locate" "locate failed" "$?" \
    "ix locate '${PATTERN}'" "$(head -3 "$_loc_err")"
}

TEXT_RAW=$(cat "$_text_tmp")
LOC_RAW=$(cat "$_loc_tmp" 2>/dev/null || echo "")

[ -z "$TEXT_RAW" ] && [ -z "$LOC_RAW" ] && exit 0

# ── Summarise text results ─────────────────────────────────────────────────────
TEXT_JSON=$(parse_json "$TEXT_RAW")
TEXT_PART=""
if [ -n "$TEXT_JSON" ]; then
  TEXT_COUNT=$(echo "$TEXT_JSON" | jq 'length' 2>/dev/null || echo 0)
  if [ "${TEXT_COUNT:-0}" -gt 0 ]; then
    FILES=$(echo "$TEXT_JSON" | jq -r '[.[].path] | unique | .[:4] | map(split("/")[-1]) | join(", ")' 2>/dev/null || echo "")
    MORE=$(( TEXT_COUNT > 4 ? TEXT_COUNT - 4 : 0 ))
    TEXT_PART="${TEXT_COUNT} text hits"
    [ -n "$FILES" ] && TEXT_PART="${TEXT_PART} in ${FILES}"
    [ "$MORE" -gt 0 ] && TEXT_PART="${TEXT_PART} (+${MORE} more)"
  fi
fi

# ── Summarise symbol results ───────────────────────────────────────────────────
LOC_JSON=$(parse_json "$LOC_RAW")
LOC_PART=""
if [ -n "$LOC_JSON" ]; then
  IS_RESOLVED=$(echo "$LOC_JSON" | jq -r '.resolvedTarget.name // empty' 2>/dev/null || echo "")
  if [ -n "$IS_RESOLVED" ]; then
    KIND=$(echo "$LOC_JSON" | jq -r '.resolvedTarget.kind // ""' 2>/dev/null || echo "")
    FILE=$(echo "$LOC_JSON" | jq -r '(.resolvedTarget.path // "") | split("/")[-1]' 2>/dev/null || echo "")
    LOC_PART="symbol: ${IS_RESOLVED} (${KIND}${FILE:+, $FILE})"
  else
    CANDS=$(echo "$LOC_JSON" | jq -r '.candidates[:3] | map(.name + " (" + .kind + ")") | join(", ")' 2>/dev/null || echo "")
    [ -n "$CANDS" ] && LOC_PART="candidates: ${CANDS}"
  fi
fi

[ -z "$TEXT_PART" ] && [ -z "$LOC_PART" ] && exit 0

CONTEXT="[ix] bash grep intercepted for '${PATTERN}'"
[ -n "$LOC_PART" ]  && CONTEXT="${CONTEXT} — ${LOC_PART}"
[ -n "$TEXT_PART" ] && CONTEXT="${CONTEXT} | ${TEXT_PART}"
CONTEXT="${CONTEXT} | Prefer: ix text '${PATTERN}' or ix locate '${PATTERN}' over shell grep"

jq -n --arg ctx "$CONTEXT" '{"additionalContext": $ctx}'
exit 0
