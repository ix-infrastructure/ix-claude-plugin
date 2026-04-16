#!/usr/bin/env bash
# ix-annotate.sh — Stop hook (synchronous)
#
# Fires after Claude finishes each response. Reads the per-turn ledger written
# by all relevant hooks and emits a short attribution summary of what ix did.
#
# Runs synchronously so the systemMessage appears before the session ends.
# Fast — no ix commands, just reads the local JSONL ledger file.
#
# Set IX_ANNOTATE_MODE=off to silence.

set -euo pipefail

[ "${IX_ANNOTATE_MODE:-brief}" != "off" ] || exit 0

INPUT=$(cat)

_HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_HOOK_DIR}/lib/index.sh" 2>/dev/null || true

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

  # Briefing (Pro session context)
  if printf '%s\n' "$_records" | jq -e 'any(.[]; .tool == "Briefing")' >/dev/null 2>&1; then
    _parts+=("loaded session context")
  fi

  # Search intercepts (Grep / Glob / Bash)
  local _search_count
  _search_count=$(printf '%s\n' "$_records" | jq '[.[] | select(.hook_event == "PreToolUse" and (.tool == "Grep" or .tool == "Glob" or .tool == "Bash"))] | length' 2>/dev/null || echo 0)
  if [ "${_search_count:-0}" -gt 0 ]; then
    if printf '%s\n' "$_records" | jq -e 'any(.[]; .hook_event == "PreToolUse" and (.tool == "Grep" or .tool == "Glob" or .tool == "Bash") and ((.ix_cmds // []) | index("locate")))' >/dev/null 2>&1; then
      _parts+=("resolved a symbol before your search")
    elif [ "$_search_count" -gt 1 ]; then
      _parts+=("prefetched graph context for ${_search_count} searches")
    else
      _parts+=("prefetched graph context for your search")
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
      critical|high) _parts+=("flagged a high-risk file before read") ;;
      medium)        _parts+=("noted a medium-risk file before read") ;;
      *)             _parts+=("checked file context before read") ;;
    esac
  fi

  # Edit / Write hook
  local _edit_risk
  _edit_risk=$(printf '%s\n' "$_records" | jq -r '
    def sev($r): if $r=="critical" then 4 elif $r=="high" then 3 elif $r=="medium" then 2 elif $r=="low" then 1 else 0 end;
    [.[] | select(.hook_event=="PreToolUse" and (.tool=="Edit" or .tool=="Write" or .tool=="MultiEdit")) | (.risk//""|ascii_downcase) | select(length>0)]
    | map({r:.,s:sev(.)}) | sort_by(.s) | last? | .r // ""
  ' 2>/dev/null || echo "")
  if printf '%s\n' "$_records" | jq -e 'any(.[]; .hook_event == "PreToolUse" and (.tool == "Edit" or .tool == "Write" or .tool == "MultiEdit"))' >/dev/null 2>&1; then
    case "$_edit_risk" in
      critical) _parts+=("warned about a critical-risk edit") ;;
      high)     _parts+=("warned about a high-risk edit") ;;
      medium)   _parts+=("noted a medium-risk edit") ;;
      *)        _parts+=("checked blast radius before edit") ;;
    esac
  fi

  [ "${#_parts[@]}" -gt 0 ] || return 0

  # Explain ix first, then describe what it did this turn.
  local _out="ix uses the code graph and session context to surface structure, risk, and relevant symbols before Claude searches, reads, or edits. This turn it " _i
  for (( _i=0; _i<${#_parts[@]}; _i++ )); do
    if [ "$_i" -eq 0 ]; then
      _out+="${_parts[$_i]}"
    elif [ "$_i" -eq $(( ${#_parts[@]} - 1 )) ] && [ "${#_parts[@]}" -gt 1 ]; then
      _out+=", and ${_parts[$_i]}"
    else
      _out+=", ${_parts[$_i]}"
    fi
  done
  _out+="."
  printf '%s' "$_out"
}

# ── Main ──────────────────────────────────────────────────────────────────────

_records=$(ix_ledger_last_turn "${INPUT:-}" 2>/dev/null || true)
_attr=$(_brief_from_records "${_records:-}")
[ -n "${_attr:-}" ] || exit 0

jq -n --arg msg "$_attr" '{"systemMessage": $msg}'
exit 0
