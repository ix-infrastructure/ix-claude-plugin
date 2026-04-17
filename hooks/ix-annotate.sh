#!/usr/bin/env bash
# ix-annotate.sh — Stop hook (synchronous)
#
# Fires after Claude finishes each response. Reads the per-turn ledger written
# by all relevant hooks and emits a short attribution summary of what ix did
# when system-message annotation is enabled.
#
# Runs synchronously so the systemMessage appears before the session ends.
# Fast — no ix commands, just reads the local JSONL ledger file.
# When IX_ANNOTATE_CHANNEL=modelSuffix, this hook stays silent and lets Claude
# write the final "Ix:" line based on earlier [ix] context.
#
# Set IX_ANNOTATE_MODE=off to silence.

set -euo pipefail

[ "${IX_ANNOTATE_MODE:-brief}" != "off" ] || exit 0
case "${IX_ANNOTATE_CHANNEL:-systemMessage}" in
  modelSuffix) exit 0 ;;
esac

_json_escape() {
  printf '%s' "${1:-}" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

_emit_system_message() {
  local _msg="${1:-}"
  [ -n "$_msg" ] || return 0
  printf '{"systemMessage":"%s"}\n' "$(_json_escape "$_msg")"
}

INPUT=$(cat)

[ -n "${INPUT:-}" ] || exit 0
[ -n "$(command -v jq 2>/dev/null)" ] || {
  _emit_system_message "Ix annotate is enabled but unavailable; jq is required for attribution."
  exit 0
}

_HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_HOOK_LIB_INDEX="${IX_HOOK_LIB_INDEX:-${_HOOK_DIR}/lib/index.sh}"

if ! source "${_HOOK_LIB_INDEX}" 2>/dev/null; then
  _emit_system_message "Ix annotate is enabled but unavailable; shared hook helpers failed to load."
  exit 0
fi

if ! declare -F ix_ledger_last_turn >/dev/null 2>&1; then
  _emit_system_message "Ix annotate is enabled but unavailable; ledger helpers are missing."
  exit 0
fi

# ── Helpers ───────────────────────────────────────────────────────────────────

_has_records() {
  local _records="${1:-}"
  [ -n "$_records" ] || return 1
  [ "$(printf '%s\n' "$_records" | jq -r 'length' 2>/dev/null || echo 0)" -gt 0 ]
}

_brief_from_records() {
  local _records="${1:-}"
  _has_records "$_records" || return 0

  local _parts=()
  local _edit_count=0
  local _edit_followup=""

  # Briefing (Pro session context)
  if printf '%s\n' "$_records" | jq -e 'any(.[]; .tool == "Briefing")' >/dev/null 2>&1; then
    _parts+=("loading session context")
  fi

  # Search intercepts (Grep / Glob / Bash)
  local _search_count
  _search_count=$(printf '%s\n' "$_records" | jq '[.[] | select(.hook_event == "PreToolUse" and (.tool == "Grep" or .tool == "Glob" or .tool == "Bash"))] | length' 2>/dev/null || echo 0)
  if [ "${_search_count:-0}" -gt 0 ]; then
    if printf '%s\n' "$_records" | jq -e 'any(.[]; .hook_event == "PreToolUse" and (.tool == "Grep" or .tool == "Glob" or .tool == "Bash") and ((.ix_cmds // []) | index("locate")))' >/dev/null 2>&1; then
      _parts+=("surfacing a relevant symbol before search")
    elif [ "$_search_count" -gt 1 ]; then
      _parts+=("prefetching graph context for ${_search_count} searches")
    else
      _parts+=("prefetching graph context for your search")
    fi
  fi

  # Read hook
  local _read_risk
  _read_risk=$(printf '%s\n' "$_records" | jq -r '
    def sev($r): if $r=="critical" then 4 elif $r=="high" then 3 elif $r=="medium" then 2 elif $r=="low" then 1 else 0 end;
    [.[] | select(.hook_event=="PreToolUse" and .tool=="Read") | (.risk//""|ascii_downcase) | select(length>0)]
    | map({r:.,s:sev(.)}) | sort_by(.s) | last? | .r // ""
  ' 2>/dev/null || echo "")
  if printf '%s\n' "$_records" | jq -e 'any(.[]; .hook_event == "PreToolUse" and .tool == "Read")' >/dev/null 2>&1; then
    case "$_read_risk" in
      critical|high) _parts+=("flagging a high-risk file before read") ;;
      medium)        _parts+=("noting a medium-risk file before read") ;;
      *)             _parts+=("checking file context before read") ;;
    esac
  fi

  # Edit / Write hook
  local _edit_risk
  _edit_risk=$(printf '%s\n' "$_records" | jq -r '
    def sev($r): if $r=="critical" then 4 elif $r=="high" then 3 elif $r=="medium" then 2 elif $r=="low" then 1 else 0 end;
    [.[] | select(.hook_event=="PreToolUse" and (.tool=="Edit" or .tool=="Write" or .tool=="MultiEdit")) | (.risk//""|ascii_downcase) | select(length>0)]
    | map({r:.,s:sev(.)}) | sort_by(.s) | last? | .r // ""
  ' 2>/dev/null || echo "")
  _edit_count=$(printf '%s\n' "$_records" | jq '[.[] | select(.hook_event == "PreToolUse" and (.tool == "Edit" or .tool == "Write" or .tool == "MultiEdit"))] | length' 2>/dev/null || echo 0)
  if [ "${_edit_count:-0}" -gt 0 ]; then
    case "$_edit_risk" in
      critical) _parts+=("warning about a critical-risk edit") ;;
      high)     _parts+=("warning about a high-risk edit") ;;
      medium)   _parts+=("noting a medium-risk edit") ;;
      *)        _parts+=("checking blast radius before edit") ;;
    esac
    _edit_followup=" and prompting you to note what changed, why, and any follow-ups after ${_edit_count} edit(s)"
  fi

  [ "${#_parts[@]}" -gt 0 ] || return 0

  local _out="Ix helped by " _i
  for (( _i=0; _i<${#_parts[@]}; _i++ )); do
    if [ "$_i" -eq 0 ]; then
      _out+="${_parts[$_i]}"
    elif [ "$_i" -eq $(( ${#_parts[@]} - 1 )) ] && [ "${#_parts[@]}" -gt 1 ]; then
      _out+=", and ${_parts[$_i]}"
    else
      _out+=", ${_parts[$_i]}"
    fi
  done
  [ -n "$_edit_followup" ] && _out+="${_edit_followup}"
  _out+="."
  printf '%s' "$_out"
}

# ── Main ──────────────────────────────────────────────────────────────────────

_records=$(ix_ledger_last_turn "${INPUT:-}" 2>/dev/null || true)
_attr=$(_brief_from_records "${_records:-}")
[ -n "${_attr:-}" ] || exit 0

_emit_system_message "$_attr"
exit 0
