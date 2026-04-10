#!/usr/bin/env bash
# ix-lib.sh — Shared utilities for ix Claude plugin hooks
#
# Source this file after sourcing ix-errors.sh:
#   _HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "${_HOOK_DIR}/ix-errors.sh" 2>/dev/null || true
#   source "${_HOOK_DIR}/ix-lib.sh"
#
# Exports:
#   IX_HEALTH_CACHE         — path to the health-check TTL file
#   IX_PRO_CACHE            — path to the pro-check cache file
#   ix_health_check         — check ix is running (exits caller on failure)
#   ix_check_pro            — check ix pro is available (exits caller if not); call after ix_health_check
#   parse_json              — strip ix header noise, extract first JSON value
#   ix_run_text_locate      — run ix text + ix locate in parallel
#   ix_summarize_text       — summarise text results → TEXT_PART
#   ix_summarize_locate     — summarise locate results → LOC_PART

IX_HEALTH_CACHE="${TMPDIR:-/tmp}/ix-healthy"
IX_PRO_CACHE="${TMPDIR:-/tmp}/ix-pro"

# ── Health check (no ix status — commands fail fast on their own) ─────────────
# Keeps a 300s TTL cache so ix_check_pro can schedule re-checks without
# calling ix status (which takes 6s+ and would reliably timeout 10s hooks).
ix_health_check() {
  local _now _cached
  _now=$(date +%s)
  if [ -f "$IX_HEALTH_CACHE" ]; then
    _cached=$(cat "$IX_HEALTH_CACHE" 2>/dev/null || echo 0)
    (( (_now - _cached) < 300 )) && return 0
  fi
  echo "$_now" > "$IX_HEALTH_CACHE"
}

# ── Pro check (TTL tied to health check) ─────────────────────────────────────
# Exits the calling script with 0 if ix pro is not available.
# Re-checks pro only when health was just refreshed (avoids redundant ix calls).
# Call after ix_health_check.
ix_check_pro() {
  local _health_ts _pro_ts _pro_val
  _health_ts=$(cat "$IX_HEALTH_CACHE" 2>/dev/null || echo "0")
  _pro_ts=$(cat "${IX_PRO_CACHE}.ts" 2>/dev/null || echo "")
  if [ "$_pro_ts" != "$_health_ts" ]; then
    ix briefing --help >/dev/null 2>&1 && echo "1" > "$IX_PRO_CACHE" || echo "0" > "$IX_PRO_CACHE"
    echo "$_health_ts" > "${IX_PRO_CACHE}.ts"
  fi
  _pro_val=$(cat "$IX_PRO_CACHE" 2>/dev/null || echo "0")
  [ "$_pro_val" = "1" ] || exit 0
}

# ── Helper: strip ix header noise, extract first JSON array/object ────────────
parse_json() {
  echo "$1" | awk '/^\[|^\{/{found=1} found{print}' | jq -c . 2>/dev/null || echo ""
}

# ── Run ix text + ix locate in parallel ──────────────────────────────────────
# Usage: ix_run_text_locate PATTERN [PATH_ARG] [LANG_ARG]
# Sets globals: _TEXT_RAW _LOC_RAW
# Requires: ix_capture_async (from ix-errors.sh, no-op if absent)
ix_run_text_locate() {
  local _pattern="$1" _path_arg="${2:-}" _lang_arg="${3:-}"
  local _text_tmp _loc_tmp _text_err _loc_err _TEXT_PID _LOC_PID _is_plain
  local _TEXT_ARGS=("$_pattern" "--limit" "15" "--format" "json")
  [ -n "$_path_arg" ] && _TEXT_ARGS+=("--path" "$_path_arg")
  [ -n "$_lang_arg" ] && _TEXT_ARGS+=("--language" "$_lang_arg")

  _text_tmp=$(mktemp); _loc_tmp=$(mktemp)
  _text_err=$(mktemp); _loc_err=$(mktemp)

  ix text "${_TEXT_ARGS[@]}" > "$_text_tmp" 2>"$_text_err" &
  _TEXT_PID=$!

  _is_plain=1
  # Two grep passes to avoid the ERE ']' bracket-close bug and '{}'  quantifier error
  if printf '%s\n' "$_pattern" | grep -qE '[*+?^$.|\\]' || \
     printf '%s\n' "$_pattern" | grep -qE '[][(){}]'; then
    _is_plain=0
  fi
  _LOC_PID=""
  if [ "$_is_plain" -eq 1 ]; then
    ix locate "$_pattern" --format json > "$_loc_tmp" 2>"$_loc_err" &
    _LOC_PID=$!
  fi

  wait "$_TEXT_PID" || ix_capture_async "ix" "ix-text" "text search failed" "$?" \
    "ix text '${_pattern}'" "$(head -3 "$_text_err")"
  [ -n "$_LOC_PID" ] && {
    wait "$_LOC_PID" || ix_capture_async "ix" "ix-locate" "locate failed" "$?" \
      "ix locate '${_pattern}'" "$(head -3 "$_loc_err")"
  }

  _TEXT_RAW=$(cat "$_text_tmp")
  _LOC_RAW=$(cat "$_loc_tmp" 2>/dev/null || echo "")

  rm -f "$_text_tmp" "$_loc_tmp" "$_text_err" "$_loc_err"
}

# ── Summarise ix text results ─────────────────────────────────────────────────
# Usage: ix_summarize_text RAW_OUTPUT
# Sets global: TEXT_PART (empty string if no results)
ix_summarize_text() {
  local _raw="$1" _json _count _files _more
  TEXT_PART=""
  _json=$(parse_json "$_raw")
  [ -z "$_json" ] && return 0
  _count=$(echo "$_json" | jq 'length' 2>/dev/null || echo 0)
  if [ "${_count:-0}" -gt 0 ]; then
    _files=$(echo "$_json" | jq -r '[.[].path] | unique | .[:4] | map(split("/")[-1]) | join(", ")' 2>/dev/null || echo "")
    _more=$(( _count > 4 ? _count - 4 : 0 ))
    TEXT_PART="${_count} text hits"
    [ -n "$_files" ] && TEXT_PART="${TEXT_PART} in ${_files}"
    [ "$_more" -gt 0 ] && TEXT_PART="${TEXT_PART} (+${_more} more)"
  fi
  return 0
}

# ── Summarise ix locate results ───────────────────────────────────────────────
# Usage: ix_summarize_locate RAW_OUTPUT
# Sets global: LOC_PART (empty string if no results)
ix_summarize_locate() {
  local _raw="$1" _json _resolved _kind _file _cands
  LOC_PART=""
  _json=$(parse_json "$_raw")
  [ -z "$_json" ] && return 0
  _resolved=$(echo "$_json" | jq -r '.resolvedTarget.name // empty' 2>/dev/null || echo "")
  if [ -n "$_resolved" ]; then
    _kind=$(echo "$_json" | jq -r '.resolvedTarget.kind // ""' 2>/dev/null || echo "")
    _file=$(echo "$_json" | jq -r '(.resolvedTarget.path // "") | split("/")[-1]' 2>/dev/null || echo "")
    LOC_PART="symbol: ${_resolved} (${_kind}${_file:+, $_file})"
  else
    _cands=$(echo "$_json" | jq -r '.candidates[:3] | map(.name + " (" + .kind + ")") | join(", ")' 2>/dev/null || echo "")
    [ -n "$_cands" ] && LOC_PART="candidates: ${_cands}"
  fi
  return 0
}
