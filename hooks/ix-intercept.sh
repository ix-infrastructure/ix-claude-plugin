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
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')

# ── Shared library ────────────────────────────────────────────────────────────
_HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_HOOK_DIR}/lib/index.sh"

ix_health_check
IX_HOOK_NAME="ix-intercept"
_t0=$(ix_now_ms)
ix_log "ENTRY tool=$TOOL"

# ── Grep: text/symbol search ──────────────────────────────────────────────────
if [ "$TOOL" = "Grep" ]; then
  PATTERN=$(echo "$INPUT" | jq -r '.tool_input.pattern // empty')
  [ -z "$PATTERN" ] && { ix_log "SKIP empty pattern"; exit 0; }
  [ ${#PATTERN} -lt 3 ] && { ix_log "SKIP pattern too short (${#PATTERN} chars)"; exit 0; }
  if [ "${IX_SKIP_SECRET_PATTERNS:-1}" = "1" ] && ix_looks_like_secret "$PATTERN"; then
    ix_log "SKIP looks like secret/token"
    exit 0
  fi
  ix_query_intent "$PATTERN"
  ix_log "GREP pattern='$PATTERN' intent=$QUERY_INTENT"
  if [ "$QUERY_INTENT" = "literal" ]; then
    ix_log "SKIP literal intent — native grep will run"
    exit 0
  fi

  PATH_ARG=$(echo "$INPUT" | jq -r '.tool_input.path // empty')
  LANG_ARG=$(echo "$INPUT" | jq -r '.tool_input.type // empty')

  ix_log "RUN ix text+locate pattern='$PATTERN' path='${PATH_ARG:-}' lang='${LANG_ARG:-}'"
  ix_run_text_locate "$PATTERN" "$PATH_ARG" "$LANG_ARG"

  [ -z "$_TEXT_RAW" ] && [ -z "$_LOC_RAW" ] && { ix_log "SKIP empty ix results"; exit 0; }

  ix_summarize_text "$_TEXT_RAW"
  ix_summarize_locate "$_LOC_RAW"
  ix_log "RESULTS text='${TEXT_PART:-<none>}' locate='${LOC_PART:-<none>}'"

  # Gate on graph confidence from locate result
  CONF_WARN=""
  HOOK_MODE="allow"
  _loc_type=""
  _loc_name=""
  _loc_path=""
  if [ -n "$_LOC_RAW" ]; then
    _LOC_JSON=$(parse_json "$_LOC_RAW")
    if [ -n "$_LOC_JSON" ]; then
      _confidence=$(echo "$_LOC_JSON" | jq -r '(.confidence // (.resolvedTarget.confidence // 1)) | tostring' 2>/dev/null || echo "1")
      ix_confidence_gate "${_confidence:-1}"
      if [ "$CONF_GATE" = "drop" ]; then
        LOC_PART=""
        TEXT_PART=""
        ix_log "CONFIDENCE gate=drop conf=${_confidence:-?} → suppressing ix injection"
      fi
      _loc_type=$(echo "$_LOC_JSON" | jq -r '.resolvedTarget.type // .resolvedTarget.kind // "unknown"' 2>/dev/null || echo "")
      _loc_name=$(echo "$_LOC_JSON" | jq -r '.resolvedTarget.name // ""' 2>/dev/null || echo "")
      _loc_path=$(echo "$_LOC_JSON" | jq -r '.resolvedTarget.path // ""' 2>/dev/null || echo "")
      if [ "${IX_BLOCK_ON_HIGH_CONFIDENCE:-1}" = "1" ] && [ "$QUERY_INTENT" = "symbol" ] && \
         [ "$CONF_GATE" = "ok" ] && [ -n "$_loc_name" ] && [ -n "$_loc_path" ]; then
        HOOK_MODE="block"
      fi
      ix_log "CONFIDENCE gate=$CONF_GATE conf=${_confidence:-?} → mode=$HOOK_MODE"
    fi
  fi

  CONTEXT="[ix text + ix locate] '${PATTERN}'"
  [ -n "$LOC_PART" ]  && CONTEXT="${CONTEXT} — ${LOC_PART}"
  [ -n "$TEXT_PART" ] && CONTEXT="${CONTEXT} | ${TEXT_PART}"
  CONTEXT="${CONTEXT} | Use ix explain/trace/impact for deeper analysis, ix read <symbol> for source"
  [ -n "$CONF_WARN" ] && CONTEXT="${CONF_WARN} | ${CONTEXT}"
  if [ "$HOOK_MODE" != "block" ] && { [ -n "$LOC_PART" ] || [ -n "$TEXT_PART" ]; }; then
    HOOK_MODE="augment"
  fi
  ix_log "DECISION mode=$HOOK_MODE"

# ── Glob: file pattern search ─────────────────────────────────────────────────
elif [ "$TOOL" = "Glob" ]; then
  PATTERN=$(echo "$INPUT" | jq -r '.tool_input.pattern // empty')
  [ -z "$PATTERN" ] && { ix_log "SKIP empty pattern"; exit 0; }

  PATH_ARG=$(echo "$INPUT" | jq -r '.tool_input.path // empty')
  ix_log "GLOB pattern='$PATTERN' path='${PATH_ARG:-<none>}'"
  [ -z "$PATH_ARG" ] && { ix_log "SKIP no path arg (Glob without path, native tool will run)"; exit 0; }

  # Intent classification — allow literal globs through without ix
  GLOB_INTENT="architecture"
  if printf '%s\n' "$PATTERN" | grep -qE '^\*\.[a-zA-Z0-9]+$'; then
    GLOB_INTENT="literal"
  fi
  if printf '%s\n' "$PATTERN" | grep -qE '^[^*]+/[^*]+$'; then
    GLOB_INTENT="literal"
  fi
  ix_log "GLOB intent=$GLOB_INTENT"
  [ "$GLOB_INTENT" = "literal" ] && { ix_log "SKIP literal glob pattern"; exit 0; }

  INV_PATH=$(ix_normalize_path_for_ix "$PATH_ARG" "$CWD" 2>/dev/null || true)
  [ -z "$INV_PATH" ] && INV_PATH="$PATH_ARG"
  INV_ARGS=("--kind" "file" "--format" "json" "--path" "$INV_PATH")

  ix_log "RUN ix inventory raw_path='$PATH_ARG' normalized_path='$INV_PATH' cwd='${CWD:-${PWD:-}}'"
  ix_log_command ix inventory "${INV_ARGS[@]}"
  _inv_err=$(mktemp)
  INV_RAW=$(ix inventory "${INV_ARGS[@]}" 2>"$_inv_err") || {
    _exit=$?
    ix_capture_async "ix" "ix-inventory" "inventory failed" "$_exit" \
      "ix inventory '$INV_PATH' (from '$PATH_ARG')" "$(head -3 "$_inv_err")"
    ix_log "FAILED ix inventory exit=$_exit"
    rm -f "$_inv_err"
    exit 0
  }
  rm -f "$_inv_err"
  [ -z "$INV_RAW" ] && { ix_log "SKIP empty inventory result"; exit 0; }

  INV_JSON=$(parse_json "$INV_RAW")
  [ -z "$INV_JSON" ] && { ix_log "SKIP inventory parse failed"; exit 0; }

  TOTAL=$(echo "$INV_JSON" | jq -r '(.summary.total // (.results | length) // 0)' 2>/dev/null || echo 0)
  SAMPLE=$(echo "$INV_JSON" | jq -r '[.results[:5][].name] | join(", ")' 2>/dev/null || echo "")

  [ "${TOTAL:-0}" -eq 0 ] && { ix_log "SKIP inventory returned 0 entities"; exit 0; }
  ix_log "INVENTORY total=$TOTAL sample='${SAMPLE:-}'"

  GLOB_HOOK_MODE="augment"
  if [ "${IX_BLOCK_ON_HIGH_CONFIDENCE:-1}" = "1" ] && [ "${TOTAL:-0}" -gt 0 ] && [ "${TOTAL:-0}" -le 20 ]; then
    GLOB_HOOK_MODE="block"
  fi
  ix_log "DECISION mode=$GLOB_HOOK_MODE"

  CONTEXT="[ix inventory] '${PATTERN}' in ${PATH_ARG}: ${TOTAL} entities"
  [ -n "$SAMPLE" ] && CONTEXT="${CONTEXT} — ${SAMPLE}$([ "${TOTAL}" -gt 5 ] && echo ' ...' || echo '')"

else
  ix_log "SKIP unknown tool=$TOOL"
  exit 0
fi

[ -z "${CONTEXT:-}" ] && exit 0

_elapsed_ms=$(( $(ix_now_ms) - _t0 ))
if [ "$TOOL" = "Grep" ]; then
  if [ "$HOOK_MODE" = "block" ]; then
    REASON="[ix text + ix locate] '${PATTERN}'"
    REASON="${REASON}"$'\n'"Found: ${_loc_name} (${_loc_type:-unknown}) at ${_loc_path}"
    [ -n "$TEXT_PART" ] && REASON="${REASON}"$'\n'"${TEXT_PART}"
    REASON="${REASON}"$'\n'"Next: ix read ${_loc_name} | ix explain ${_loc_name}"
    ix_ledger_append "PreToolUse" "Grep" "${#REASON}" "text,locate" "${_confidence:-1}" "" "$_elapsed_ms" \
      "surfaced a graph-backed match for ${_loc_name:-$PATTERN} and pointed to the right follow-up path."
    echo "ix locate '${PATTERN}' → ${_loc_name} at ${_loc_path} [BLOCKED]" >&2
    ix_hook_fallback "block" "$REASON" "$CONTEXT"
  elif [ "$HOOK_MODE" = "augment" ]; then
    ix_ledger_append "PreToolUse" "Grep" "${#CONTEXT}" "text,locate" "${_confidence:-1}" "" "$_elapsed_ms" \
      "surfaced graph-backed matches for ${PATTERN} and suggested deeper ix follow-ups."
    ix_log_injection "additionalContext" "$CONTEXT"
    echo "ix text + ix locate: '${PATTERN}' → ${LOC_PART:-no exact match} | ${TEXT_PART:-no text hits}" >&2
    ix_hook_fallback "augment" "$CONTEXT"
  else
    exit 0
  fi
else
  if [ "${GLOB_HOOK_MODE:-augment}" = "block" ]; then
    _first_sample=$(printf '%s' "$SAMPLE" | cut -d',' -f1 | tr -d ' ')
    REASON="[ix inventory] '${PATTERN}' in ${PATH_ARG}: ${TOTAL} entities — ${SAMPLE}"
    [ -n "$_first_sample" ] && REASON="${REASON} | Next: ix overview ${_first_sample}"
    ix_ledger_append "PreToolUse" "Glob" "${#REASON}" "inventory" "1" "" "$_elapsed_ms" \
      "surveyed ${PATTERN} with inventory and highlighted likely targets."
    echo "ix inventory: '${PATTERN}' in ${PATH_ARG} → ${TOTAL} entities [BLOCKED]" >&2
    ix_hook_fallback "block" "$REASON" "$CONTEXT"
  else
    ix_ledger_append "PreToolUse" "Glob" "${#CONTEXT}" "inventory" "1" "" "$_elapsed_ms" \
      "surveyed ${PATTERN} with inventory and highlighted likely targets."
    ix_log_injection "additionalContext" "$CONTEXT"
    echo "ix inventory: '${PATTERN}' in ${PATH_ARG} → ${TOTAL} entities" >&2
    ix_hook_fallback "augment" "$CONTEXT"
  fi
fi
exit 0
