#!/usr/bin/env bash
# Copyright 2026 Ix Infrastructure Inc.

# ix-bash.sh — PreToolUse hook for Bash
#
# Fires before Claude runs a Bash command. Detects grep/rg search patterns and,
# when the pattern names one definition in the graph, says what the grep will
# not: where it is defined and who calls it (ix_definition_context). Otherwise
# it stays silent and the grep answers on its own.
#
# Output is a CONCISE one-line summary — not raw JSON dumps.
#
# Exit 0 + JSON stdout → hookSpecificOutput.additionalContext, Bash still runs
# Exit 0 + no stdout  → no-op, Bash runs normally

set -euo pipefail

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
[ -z "$COMMAND" ] && exit 0

# Intercept direct grep/rg invocations plus common wrapped forms such as:
#   cd src && rg AuthService
#   (cd src; grep AuthService)
#   find . | xargs grep AuthService
SEARCH_CMD=""
SEARCH_CMD=$(printf '%s\n' "$COMMAND" \
  | grep -oE '(^|[[:space:];|&()])(grep|rg)[[:space:]].*' \
  | tail -1 \
  | sed -E 's/^[[:space:];|&()]+//; s/[[:space:]]*\)+[[:space:]]*$//' 2>/dev/null) || SEARCH_CMD=""
[ -z "$SEARCH_CMD" ] && exit 0

# ── Shared library ────────────────────────────────────────────────────────────
_HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_HOOK_DIR}/lib/index.sh"

ix_health_check
IX_HOOK_NAME="ix-bash"
ix_log "ENTRY command='${COMMAND:0:80}'"
ix_log "SEARCH command='${SEARCH_CMD:0:80}'"

# ── Extract search pattern from command ────────────────────────────────────────
PATTERN=""
PATTERN=$(echo "$SEARCH_CMD" | sed -E 's/^[^"]*[[:space:]]"([^"]+)".*/\1/' 2>/dev/null) || PATTERN=""
if [ -z "$PATTERN" ] || [ "$PATTERN" = "$SEARCH_CMD" ]; then
  PATTERN=$(echo "$SEARCH_CMD" | sed -E "s/^[^']*[[:space:]]'([^']+)'.*/\\1/" 2>/dev/null) || PATTERN=""
fi
if [ -z "$PATTERN" ] || [ "$PATTERN" = "$SEARCH_CMD" ]; then
  PATTERN=$(echo "$SEARCH_CMD" | sed -E 's/^[[:space:]]*(grep|rg)[[:space:]]+(-[a-zA-Z0-9]+[[:space:]]+|--[a-zA-Z-]+=[^[:space:]]+[[:space:]]+)*([^-][^ ]*).*/\3/' 2>/dev/null) || PATTERN=""
fi

[ -z "$PATTERN" ] && { ix_log "SKIP could not extract pattern"; exit 0; }
[ ${#PATTERN} -lt 3 ] && { ix_log "SKIP pattern too short"; exit 0; }
if [ "${IX_SKIP_SECRET_PATTERNS:-1}" = "1" ] && ix_looks_like_secret "$PATTERN"; then
  ix_log "SKIP looks like secret/token"
  exit 0
fi
ix_log "PATTERN extracted='$PATTERN'"

# The same gate ix-intercept.sh applies to Grep, and for the same reason: a
# pattern with regex syntax in it, a phrase, or a log prefix names nothing in
# the graph, so `ix text` + `ix locate` can only come back empty. This hook was
# missing it, so every shell grep paid for two ix calls before the shell command
# it was supposed to be saving even started.
ix_query_intent "$PATTERN"
if [ "$QUERY_INTENT" = "literal" ]; then
  ix_log "SKIP literal intent — shell grep will run"
  exit 0
fi

# ── Resolve the pattern to a definition, and its callers ─────────────────────
# Only locate: the grep about to run lists every text hit itself, so `ix text`
# would only repeat them back.
ix_log "RUN ix locate pattern='$PATTERN'"
_t0=$(ix_now_ms)
_loc_err=$(mktemp)
ix_log_command ix locate "$PATTERN" --format json
_loc_status=0
_LOC_RAW=$(ix_run_bounded "${IX_LOCATE_TIMEOUT:-4}" ix locate "$PATTERN" --format json 2>"$_loc_err") || _loc_status=$?
if [ "$_loc_status" -ne 0 ]; then
  # An unresolved target exits non-zero but still prints its JSON body (Ix#539):
  # an answer, not a failure. Only an empty body is a failure worth filing.
  if [ -n "$_LOC_RAW" ]; then
    ix_log "MISS ix locate exited ${_loc_status} with a body; treated as no-match"
  else
    ix_capture_async "ix" "ix-locate" "locate failed" "$_loc_status" \
      "ix locate '${PATTERN}'" "$(head -3 "$_loc_err")"
  fi
fi
rm -f "$_loc_err"
[ -z "$_LOC_RAW" ] && { ix_log "SKIP empty ix locate"; exit 0; }

ix_definition_context "$_LOC_RAW"
[ -z "$DEF_PART" ] && { ix_log "SKIP no single confident definition — grep answers alone"; exit 0; }
CONTEXT="$DEF_PART"

_elapsed_ms=$(( $(ix_now_ms) - _t0 ))
ix_log "DECISION augment ${#CONTEXT} chars (${_elapsed_ms}ms)"
ix_log_injection "additionalContext" "$CONTEXT"
ix_ledger_append "PreToolUse" "Bash" "${#CONTEXT}" "locate,callers" "1" "" "$_elapsed_ms" \
  "answered shell grep for ${PATTERN} with its definition and callers."

# Context only, in both output styles: no permissionDecision. An "allow" here
# would also skip the user's permission prompt for this tool call.
ix_emit_context "PreToolUse" "$CONTEXT"
exit 0
