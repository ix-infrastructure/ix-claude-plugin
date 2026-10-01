#!/usr/bin/env bash
# Copyright 2026 Ix Infrastructure Inc.

# ix-annotate.sh — Stop hook attribution summary
#
# Fires on Stop, reads the current turn's ix ledger records, and emits a concise
# factual summary on the configured channel. Model-suffix instruction handling
# lives in ix-briefing.sh, so this hook stays silent for modelSuffix-only mode.
#
# The summary always goes out as systemMessage (shown to the user), whatever
# the channel. A Stop hook's only model channel is
# hookSpecificOutput.additionalContext, and Claude Code treats it as feedback
# that continues the conversation: the context lands after Claude's response
# and the model takes another turn to act on it (Claude Code 2.1.287;
# https://code.claude.com/docs/en/hooks#stop-decision-control). An attribution
# note is not worth a model turn on every stop, so the `additionalContext` and
# `both` channels fall back to systemMessage here. The top-level
# `additionalContext` this hook used to print was never read (unrecognized key).

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
  ix_log_injection "systemMessage" "$_fallback"
  jq -n --arg msg "$_fallback" '{"systemMessage": $msg}'
  exit 0
fi

_records=$(ix_ledger_last_turn "$INPUT")
[ -n "${_records:-}" ] || { ix_log "SKIP no ledger records"; exit 0; }
[ "$_records" != "[]" ] || { ix_log "SKIP empty ledger records"; exit 0; }

_grep_count=$(printf '%s\n' "$_records" | jq '[.[] | select((.ctx_chars // 0) > 0 and (.tool == "Grep" or .tool == "Glob" or .tool == "Bash"))] | length' 2>/dev/null || echo 0)
_read_count=$(printf '%s\n' "$_records" | jq '[.[] | select((.ctx_chars // 0) > 0 and .tool == "Read")] | length' 2>/dev/null || echo 0)
_edit_count=$(printf '%s\n' "$_records" | jq '[.[] | select((.ctx_chars // 0) > 0 and (.tool == "Edit" or .tool == "Write" or .tool == "MultiEdit"))] | length' 2>/dev/null || echo 0)
_briefing_count=$(printf '%s\n' "$_records" | jq '[.[] | select((.ctx_chars // 0) > 0 and .tool == "Briefing")] | length' 2>/dev/null || echo 0)

_note_parts=$(printf '%s\n' "$_records" | jq -r '
  [ .[]
    | select((.ctx_chars // 0) > 0)
    | .note
    | select(type == "string" and length > 0)
  ]
  | unique
  | .[:3]
  | .[]' 2>/dev/null || echo "")

_summary=$(printf '%s\n' "${_note_parts}" | awk '
  NF { parts[++n]=$0 }
  END {
    if (n > 0) {
      printf "Ix %s", parts[1]
      for (i=2; i<=n; i++) printf " It also %s", parts[i]
    }
  }')

if [ -z "$_summary" ]; then
  if [ "${_grep_count:-0}" -gt 0 ]; then
    _summary="Ix surfaced a relevant symbol before search."
  elif [ "${_read_count:-0}" -gt 0 ]; then
    _summary="Ix provided file context before read."
  elif [ "${_edit_count:-0}" -gt 0 ]; then
    _summary="Ix flagged edit blast radius before modification."
  elif [ "${_briefing_count:-0}" -gt 0 ]; then
    _summary="Ix injected session context."
  fi
fi

[ -n "$_summary" ] || { ix_log "SKIP no attributable ix activity"; exit 0; }

ix_log "DECISION emit summary chars=${#_summary}"
ix_log_injection "systemMessage" "$_summary"
jq -n --arg msg "$_summary" '{"systemMessage": $msg}'
exit 0
