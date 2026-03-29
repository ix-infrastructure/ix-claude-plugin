#!/usr/bin/env bash
# ix-intercept.sh — PreToolUse hook for Grep and Glob
#
# Fires before Grep/Glob executes. Runs ix text + ix locate/inventory in
# parallel and injects a CONCISE one-line summary as additionalContext so
# Claude has a graph-aware answer before the native tool runs.
#
# Output is a single line, not raw JSON dumps — designed to be acted on,
# not skipped over.
#
# Exit 0 + JSON stdout → injects additionalContext, native tool still runs
# Exit 0 + no stdout  → no-op, native tool runs normally

set -euo pipefail

INPUT=$(cat)
TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty')
[ -z "$TOOL" ] && exit 0

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

# ── Grep: text/symbol search ──────────────────────────────────────────────────
if [ "$TOOL" = "Grep" ]; then
  PATTERN=$(echo "$INPUT" | jq -r '.tool_input.pattern // empty')
  [ -z "$PATTERN" ] && exit 0
  [ ${#PATTERN} -lt 3 ] && exit 0

  PATH_ARG=$(echo "$INPUT" | jq -r '.tool_input.path // empty')
  LANG_ARG=$(echo "$INPUT" | jq -r '.tool_input.type // empty')

  TEXT_ARGS=("$PATTERN" "--limit" "15" "--format" "json")
  [ -n "$PATH_ARG" ] && TEXT_ARGS+=("--path" "$PATH_ARG")
  [ -n "$LANG_ARG" ] && TEXT_ARGS+=("--language" "$LANG_ARG")

  _text_tmp=$(mktemp)
  _loc_tmp=$(mktemp)
  _text_err=$(mktemp)
  _loc_err=$(mktemp)
  trap 'rm -f "$_text_tmp" "$_loc_tmp" "$_text_err" "$_loc_err"' EXIT

  ix text "${TEXT_ARGS[@]}" > "$_text_tmp" 2>"$_text_err" &
  _TEXT_PID=$!

  # Only run locate for plain identifier patterns — skip regex metacharacters
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

  # ── Summarise text results (one line) ─────────────────────────────────────
  TEXT_JSON=$(parse_json "$TEXT_RAW")
  TEXT_PART=""
  if [ -n "$TEXT_JSON" ]; then
    TEXT_COUNT=$(echo "$TEXT_JSON" | jq 'length' 2>/dev/null || echo 0)
    if [ "$TEXT_COUNT" -gt 0 ]; then
      FILES=$(echo "$TEXT_JSON" | jq -r '[.[].path] | unique | .[:4] | map(split("/")[-1]) | join(", ")' 2>/dev/null || echo "")
      MORE=$(( TEXT_COUNT > 4 ? TEXT_COUNT - 4 : 0 ))
      TEXT_PART="${TEXT_COUNT} text hits"
      [ -n "$FILES" ] && TEXT_PART="${TEXT_PART} in ${FILES}"
      [ "$MORE" -gt 0 ] && TEXT_PART="${TEXT_PART} (+${MORE} more)"
    fi
  fi

  # ── Summarise locate/symbol results (one line) ────────────────────────────
  LOC_JSON=$(parse_json "$LOC_RAW")
  LOC_PART=""
  if [ -n "$LOC_JSON" ]; then
    IS_RESOLVED=$(echo "$LOC_JSON" | jq -r '.resolvedTarget.name // empty' 2>/dev/null || echo "")
    if [ -n "$IS_RESOLVED" ]; then
      KIND=$(echo "$LOC_JSON" | jq -r '.resolvedTarget.kind // ""' 2>/dev/null || echo "")
      FILE=$(echo "$LOC_JSON" | jq -r '(.resolvedTarget.path // "") | split("/")[-1]' 2>/dev/null || echo "")
      LOC_PART="symbol: ${IS_RESOLVED} (${KIND}${FILE:+, $FILE})"
    else
      # Candidates from ambiguous resolve
      CANDS=$(echo "$LOC_JSON" | jq -r '.candidates[:3] | map(.name + " (" + .kind + ")") | join(", ")' 2>/dev/null || echo "")
      [ -n "$CANDS" ] && LOC_PART="candidates: ${CANDS}"
    fi
  fi

  [ -z "$TEXT_PART" ] && [ -z "$LOC_PART" ] && exit 0

  CONTEXT="[ix] '${PATTERN}'"
  [ -n "$LOC_PART" ]  && CONTEXT="${CONTEXT} — ${LOC_PART}"
  [ -n "$TEXT_PART" ] && CONTEXT="${CONTEXT} | ${TEXT_PART}"
  CONTEXT="${CONTEXT} | Use ix explain/trace/impact for deeper analysis, ix read <symbol> for source"

# ── Glob: file pattern search ─────────────────────────────────────────────────
elif [ "$TOOL" = "Glob" ]; then
  PATTERN=$(echo "$INPUT" | jq -r '.tool_input.pattern // empty')
  [ -z "$PATTERN" ] && exit 0

  PATH_ARG=$(echo "$INPUT" | jq -r '.tool_input.path // empty')
  [ -z "$PATH_ARG" ] && exit 0

  INV_ARGS=("--format" "json")
  INV_ARGS+=("--path" "$PATH_ARG")

  _inv_err=$(mktemp)
  INV_RAW=$(ix inventory "${INV_ARGS[@]}" 2>"$_inv_err") || {
    _exit=$?
    ix_capture_async "ix" "ix-inventory" "inventory failed" "$_exit" \
      "ix inventory '$PATH_ARG'" "$(head -3 "$_inv_err")"
    rm -f "$_inv_err"
    exit 0
  }
  rm -f "$_inv_err"
  [ -z "$INV_RAW" ] && exit 0

  INV_JSON=$(parse_json "$INV_RAW")
  [ -z "$INV_JSON" ] && exit 0

  TOTAL=$(echo "$INV_JSON" | jq -r '(.summary.total // (.results | length) // 0)' 2>/dev/null || echo 0)
  SAMPLE=$(echo "$INV_JSON" | jq -r '[.results[:5][].name] | join(", ")' 2>/dev/null || echo "")

  [ "${TOTAL:-0}" -eq 0 ] && exit 0

  CONTEXT="[ix] glob '${PATTERN}' in ${PATH_ARG}: ${TOTAL} entities"
  [ -n "$SAMPLE" ] && CONTEXT="${CONTEXT} — ${SAMPLE}$([ "${TOTAL}" -gt 5 ] && echo ' ...' || echo '')"

else
  exit 0
fi

[ -z "${CONTEXT:-}" ] && exit 0

jq -n --arg ctx "$CONTEXT" '{"additionalContext": $ctx}'
exit 0
