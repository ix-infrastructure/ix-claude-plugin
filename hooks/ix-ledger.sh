#!/usr/bin/env bash
# ix-ledger.sh — Per-turn attribution ledger
#
# Sourced by ix hooks via lib/index.sh. Provides two public functions:
#
#   ix_ledger_append  — called by each hook after building its context string
#   ix_ledger_last_turn — called by Stop hook to read current turn's records
#
# Records are written to:
#   ~/.local/share/ix/plugin/ledger/ledger.jsonl
#
# Config (env-overridable):
#   IX_LEDGER_MODE   off | on  (default: on)

IX_LEDGER_STORE="${HOME}/.local/share/ix/plugin/ledger"
IX_LEDGER_FILE="${IX_LEDGER_STORE}/ledger.jsonl"

_ix_ledger_mkdir() { mkdir -p "${IX_LEDGER_STORE}" 2>/dev/null; }

# ── Turn identity ────────────────────────────────────────────────────────────
# Claude hook payloads include session_id; use that as the per-turn ledger key
# when present. PPID is only a last-resort fallback for environments that do
# not provide session metadata.
ix_ledger_turn_id() {
  local _input="${1:-${INPUT:-}}" _session_id=""

  if [ -n "$_input" ]; then
    _session_id=$(printf '%s\n' "$_input" | jq -r '.session_id // empty' 2>/dev/null || true)
  fi

  if [ -n "${_session_id:-}" ]; then
    printf '%s\n' "$_session_id"
  else
    printf '%s\n' "${PPID:-0}"
  fi
}

# ── Public: append one record to the ledger ───────────────────────────────────
# Usage: ix_ledger_append <hook_event> <tool> <ctx_chars> <ix_cmds> <conf> <risk> <ms> [note]
#   hook_event : PreToolUse | PostToolUse | UserPromptSubmit | Stop
#   tool       : Grep | Glob | Read | Edit | Write | Bash | Briefing | …
#   ctx_chars  : length of injected context string (integer)
#   ix_cmds    : comma-separated list of ix commands run (e.g. "text,locate")
#   conf       : confidence value (float string, e.g. "0.85"), or "" / "1"
#   risk       : risk level from ix impact (high | medium | low | critical | "")
#   ms         : elapsed milliseconds (integer), or "0" if unavailable
#   note       : short natural-language note describing how ix helped this turn
ix_ledger_append() {
  [ "${IX_LEDGER_MODE:-on}" = "off" ] && return 0

  local _event="${1:-}"  _tool="${2:-}"  _chars="${3:-0}" \
        _cmds="${4:-}"   _conf="${5:-1}" _risk="${6:-}"   _ms="${7:-0}" \
        _note="${8:-}"
  local _turn_id
  [ -z "$_event" ] && return 0
  _turn_id=$(ix_ledger_turn_id)

  _ix_ledger_mkdir
  local _ts
  _ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")
  jq -cn \
    --arg  ts       "$_ts"          \
    --arg  turn_id  "$_turn_id"     \
    --arg  event    "$_event"       \
    --arg  tool     "$_tool"        \
    --argjson chars "${_chars:-0}"  \
    --arg  cmds     "$_cmds"        \
    --arg  conf     "$_conf"        \
    --arg  risk     "$_risk"        \
    --arg  note     "$_note"        \
    --argjson ms    "${_ms:-0}"     \
    '{ts:$ts, turn_id:$turn_id, hook_event:$event, tool:$tool,
      ctx_chars:$chars, ix_cmds:($cmds|split(",")|map(select(length>0))),
      conf:$conf, risk:$risk, note:$note, ms:$ms}' \
    >> "$IX_LEDGER_FILE" 2>/dev/null || true
}

# ── Public: return JSON array of current turn's ledger records ────────────────
# Usage: RECORDS=$(ix_ledger_last_turn)
# Returns empty string if ledger file missing or no records for this turn.
ix_ledger_last_turn() {
  [ ! -f "$IX_LEDGER_FILE" ] && return 0

  local _tid
  _tid=$(ix_ledger_turn_id "${1:-}")

  # Read last 200 lines, filter to this session's records.
  local _session_records
  _session_records=$(tail -200 "$IX_LEDGER_FILE" 2>/dev/null \
    | jq -sc --arg tid "$_tid" '[.[] | select(.turn_id == $tid)]' 2>/dev/null \
    || echo "[]")

  # Scope to the current turn: the last Briefing record marks the start of
  # this turn (UserPromptSubmit always fires before any PreToolUse).
  # ISO 8601 strings are lexicographically ordered so >= comparison works.
  local _turn_start
  _turn_start=$(printf '%s\n' "$_session_records" \
    | jq -r '[.[] | select(.tool == "Briefing")] | last | .ts // ""' 2>/dev/null || echo "")

  if [ -n "$_turn_start" ]; then
    printf '%s\n' "$_session_records" \
      | jq -c --arg start "$_turn_start" '[.[] | select(.ts >= $start)]' 2>/dev/null \
      || echo ""
  else
    printf '%s\n' "$_session_records"
  fi
}
