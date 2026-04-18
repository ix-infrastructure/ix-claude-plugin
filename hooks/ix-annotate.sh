#!/usr/bin/env bash
# ix-annotate.sh — synchronous attribution/nudge hook
#
# Reads the current session's ix ledger records and emits a concise summary on
# the configured channel. Model-suffix instruction handling lives in
# ix-briefing.sh, so this hook stays silent for modelSuffix-only mode.

set -euo pipefail

INPUT=$(cat)
[ -n "${INPUT:-}" ] || exit 0

_HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_HOOK_LIB_INDEX="${IX_HOOK_LIB_INDEX:-${_HOOK_DIR}/lib/index.sh}"
source "${_HOOK_LIB_INDEX}" 2>/dev/null || exit 0

IX_HOOK_NAME="ix-annotate"
_mode="${IX_ANNOTATE_MODE:-brief}"
_channel="${IX_ANNOTATE_CHANNEL:-modelSuffix}"

[ "$_mode" != "off" ] || exit 0
ix_health_check || { ix_log "SKIP ix not available"; exit 0; }
ix_log "ENTRY mode=${_mode} channel=${_channel}"

case "$_channel" in
  modelSuffix)
    ix_log "SKIP modelSuffix handled by briefing hook"
    exit 0
    ;;
  systemMessage|additionalContext|both)
    ;;
  *)
    ix_log "SKIP unsupported channel=$_channel"
    exit 0
    ;;
esac

if ! declare -F ix_ledger_last_turn >/dev/null 2>&1; then
  _fallback="Ix attribution unavailable: ledger helpers are missing."
  ix_log "DECISION fallback missing ledger helper"
  case "$_channel" in
    systemMessage)
      jq -n --arg msg "$_fallback" '{"systemMessage": $msg}'
      ;;
    additionalContext)
      jq -n --arg ctx "$_fallback" '{"additionalContext": $ctx}'
      ;;
    both)
      jq -n --arg msg "$_fallback" '{"systemMessage": $msg, "additionalContext": $msg}'
      ;;
  esac
  exit 0
fi

_records=$(ix_ledger_last_turn "$INPUT")
[ -n "${_records:-}" ] || { ix_log "SKIP no ledger records"; exit 0; }
[ "$_records" != "[]" ] || { ix_log "SKIP empty ledger records"; exit 0; }

_grep_count=$(printf '%s\n' "$_records" | jq '[.[] | select(.tool == "Grep" or .tool == "Glob" or .tool == "Bash")] | length' 2>/dev/null || echo 0)
_read_count=$(printf '%s\n' "$_records" | jq '[.[] | select(.tool == "Read")] | length' 2>/dev/null || echo 0)
_edit_count=$(printf '%s\n' "$_records" | jq '[.[] | select(.tool == "Edit" or .tool == "Write" or .tool == "MultiEdit")] | length' 2>/dev/null || echo 0)
_briefing_count=$(printf '%s\n' "$_records" | jq '[.[] | select(.tool == "Briefing")] | length' 2>/dev/null || echo 0)

_summary=""
if [ "${_grep_count:-0}" -gt 0 ]; then
  _summary="Ix helped by surfacing a relevant symbol before search."
elif [ "${_read_count:-0}" -gt 0 ]; then
  _summary="Ix helped by highlighting relevant file structure before reading."
elif [ "${_edit_count:-0}" -gt 0 ]; then
  _summary="Ix helped by flagging edit impact before changes were applied."
elif [ "${_briefing_count:-0}" -gt 0 ]; then
  _summary="Ix helped by refreshing the session context before work began."
fi

[ -n "$_summary" ] || { ix_log "SKIP no attributable ix activity"; exit 0; }

if [ "${_edit_count:-0}" -gt 0 ]; then
  _summary="${_summary} Ix also helped by prompting you to note what changed, why, and any follow-ups after ${_edit_count} edit(s)."
fi

ix_log "DECISION emit summary chars=${#_summary}"
case "$_channel" in
  systemMessage)
    jq -n --arg msg "$_summary" '{"systemMessage": $msg}'
    ;;
  additionalContext)
    jq -n --arg ctx "$_summary" '{"additionalContext": $ctx}'
    ;;
  both)
    jq -n --arg msg "$_summary" '{"systemMessage": $msg, "additionalContext": $msg}'
    ;;
esac
exit 0
