#!/usr/bin/env bash
# ix-map.sh — Stop hook
#
# Fires after Claude finishes each response. Runs ix map asynchronously to
# keep the architectural graph current so the next session starts fresh.
#
# Runs async (does not block Claude's response or session end).

set -euo pipefail

# ── Shared library ────────────────────────────────────────────────────────────
_HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_HOOK_DIR}/lib/index.sh" 2>/dev/null || true

ix_health_check

_ix_attr_has_records() {
  local _records="${1:-}"
  [ -n "$_records" ] || return 1
  [ "$(printf '%s\n' "$_records" | jq -r 'length' 2>/dev/null || echo 0)" -gt 0 ]
}

_ix_attr_risk_code() {
  case "${1:-}" in
    critical) printf 'C' ;;
    high)     printf 'H' ;;
    medium)   printf 'M' ;;
    low)      printf 'L' ;;
    *)        printf '' ;;
  esac
}

_ix_attr_brief_from_records() {
  local _records="${1:-}" _codes=() _payload="" _risk="" _risk_code="" _conf=""
  _ix_attr_has_records "$_records" || return 0

  if printf '%s\n' "$_records" | jq -e 'any(.[]; .tool == "Briefing")' >/dev/null 2>&1; then
    _codes+=("B")
  fi

  if printf '%s\n' "$_records" | jq -e 'any(.[]; .hook_event == "PreToolUse" and (.tool == "Grep" or .tool == "Glob" or .tool == "Bash"))' >/dev/null 2>&1; then
    _payload=""
    if printf '%s\n' "$_records" | jq -e 'any(.[]; .hook_event == "PreToolUse" and (.tool == "Grep" or .tool == "Glob" or .tool == "Bash") and ((.ix_cmds // []) | index("locate")))' >/dev/null 2>&1; then
      _payload="loc=1"
    fi
    _conf=$(printf '%s\n' "$_records" | jq -r '
      [ .[]
        | select(.hook_event == "PreToolUse" and (.tool == "Grep" or .tool == "Glob" or .tool == "Bash"))
        | (.conf | tonumber? // 1)
        | select(. < 0.6)
      ]
      | min?
      | if . == null then "" else ((. * 100 | floor) / 100 | tostring) end
    ' 2>/dev/null || echo "")
    if [ -n "$_conf" ]; then
      if [ -n "$_payload" ]; then
        _payload="${_payload},conf=${_conf}"
      else
        _payload="conf=${_conf}"
      fi
    fi
    if [ -n "$_payload" ]; then
      _codes+=("G(${_payload})")
    else
      _codes+=("G")
    fi
  fi

  _risk=$(printf '%s\n' "$_records" | jq -r '
    def sev($r):
      if $r == "critical" then 4
      elif $r == "high" then 3
      elif $r == "medium" then 2
      elif $r == "low" then 1
      else 0 end;
    [
      .[]
      | select(.hook_event == "PreToolUse" and .tool == "Read")
      | (.risk // "" | ascii_downcase) as $risk
      | select($risk != "")
      | {risk: $risk, sev: sev($risk)}
    ]
    | sort_by(.sev)
    | last?
    | .risk // ""
  ' 2>/dev/null || echo "")
  _risk_code=$(_ix_attr_risk_code "$_risk")
  if [ -n "$_risk_code" ] && [ "$_risk_code" != "L" ]; then
    _codes+=("R(risk=${_risk_code})")
  elif printf '%s\n' "$_records" | jq -e 'any(.[]; .hook_event == "PreToolUse" and .tool == "Read")' >/dev/null 2>&1; then
    _codes+=("R")
  fi

  _risk=$(printf '%s\n' "$_records" | jq -r '
    def sev($r):
      if $r == "critical" then 4
      elif $r == "high" then 3
      elif $r == "medium" then 2
      elif $r == "low" then 1
      else 0 end;
    [
      .[]
      | select(.hook_event == "PreToolUse" and (.tool == "Edit" or .tool == "Write" or .tool == "MultiEdit"))
      | (.risk // "" | ascii_downcase) as $risk
      | select($risk != "")
      | {risk: $risk, sev: sev($risk)}
    ]
    | sort_by(.sev)
    | last?
    | .risk // ""
  ' 2>/dev/null || echo "")
  _risk_code=$(_ix_attr_risk_code "$_risk")
  if [ -n "$_risk_code" ] && [ "$_risk_code" != "L" ]; then
    _codes+=("E(risk=${_risk_code})")
  elif printf '%s\n' "$_records" | jq -e 'any(.[]; .hook_event == "PreToolUse" and (.tool == "Edit" or .tool == "Write" or .tool == "MultiEdit"))' >/dev/null 2>&1; then
    _codes+=("E")
  fi

  [ "${#_codes[@]}" -gt 0 ] || return 0

  local IFS=' '
  printf '⟦ix+:%s⟧' "${_codes[*]}"
}

_ix_attr_emit() {
  local _attr="${1:-}" _channel="${IX_ANNOTATE_CHANNEL:-systemMessage}"
  [ -n "$_attr" ] || return 0

  case "$_channel" in
    systemMessage)
      jq -n --arg msg "$_attr" '{"systemMessage": $msg}'
      ;;
    additionalContext)
      jq -n --arg ctx "$_attr" '{"additionalContext": $ctx}'
      ;;
    both)
      jq -n --arg msg "$_attr" --arg ctx "$_attr" '{"systemMessage": $msg, "additionalContext": $ctx}'
      ;;
    *)
      return 0
      ;;
  esac
}

# ── Debounce — skip if a map ran recently ────────────────────────────────────
IX_MAP_DEBOUNCE_SECONDS="${IX_MAP_DEBOUNCE_SECONDS:-300}"
IX_MAP_DEBOUNCE_FILE="${TMPDIR:-/tmp}/ix-map-last"
_now=$(date +%s)
_skip_map=0
if [ -f "$IX_MAP_DEBOUNCE_FILE" ]; then
  _last=$(cat "$IX_MAP_DEBOUNCE_FILE" 2>/dev/null || echo 0)
  (( (_now - _last) < IX_MAP_DEBOUNCE_SECONDS )) && _skip_map=1
fi

# ── flock — skip if another map is already running ───────────────────────────
IX_MAP_LOCK_PATH="${IX_MAP_LOCK_PATH:-${TMPDIR:-/tmp}/ix-map.lock}"
if [ "$_skip_map" -eq 0 ] && command -v flock >/dev/null 2>&1; then
  exec 9>"$IX_MAP_LOCK_PATH"
  if ! flock -n 9; then
    _skip_map=1
    ix_ledger_append "Stop" "map_skipped_lock" "0" "" "1" "" "0"
  fi
fi

# ── Run map (Claude Code's async runner handles timeout) ─────────────────────
if [ "$_skip_map" -eq 0 ]; then
  echo "$_now" > "$IX_MAP_DEBOUNCE_FILE"
  ix map >/dev/null 2>&1 || ix_capture_async "ix" "ix-map" "full map failed" "$?" "ix map" ""
fi

[ "${IX_ANNOTATE_MODE:-off}" = "brief" ] || exit 0

_records=$(ix_ledger_last_turn 2>/dev/null || true)
_attr=$(_ix_attr_brief_from_records "${_records:-}")
[ -n "${_attr:-}" ] || exit 0
_ix_attr_emit "$_attr"

exit 0
