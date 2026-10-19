#!/usr/bin/env bash
# Copyright 2026 Ix Infrastructure Inc.

# hooks/lib/timing.sh — One EXIT line per hook run in IX_DEBUG_LOG
#
# Usage (the first command of a hook, before `set -euo pipefail`, any early
# exit, or reading stdin):
#   [ -z "${IX_DEBUG_LOG:-}" ] || source "${BASH_SOURCE[0]%/*}/lib/timing.sh" ix-map 2>/dev/null
#
# The guard keeps a run without IX_DEBUG_LOG exactly as it was: this file is
# not even read. With it set, the hook appends one line when it exits, on every
# path (normal end, early `exit 0`, gate skip, `set -e` failure, SIGTERM):
#   [2026-10-15T18:54:03] [ix-map] EXIT ms=42 rc=0 tool=-
# `ms` is wall time since the line above ran; `tool` is the payload's
# tool_name, or `-` when there is none or stdin was never read.
#
# Why not ix_now_ms: it lives in ix-lib.sh, which the hooks source after their
# cheap skip checks, and those early exits are what this has to time. The
# clock is chosen once here and reused at exit, so the start costs no process
# on bash 5 ($EPOCHREALTIME) and one on bash 3.2 (macOS: perl, as BSD date
# has no %N), and so does the exit.
#
# The EXIT trap leaves stdout, stderr and the exit status alone. A hook that
# sets its own EXIT trap replaces this one, so it must call
# _ix_hook_timer_exit from it (none of the timed hooks does).

_IX_HOOK_TIMER_NAME="${1:-hook}"
_IX_HOOK_TIMER_CLOCK=""
_IX_HOOK_TIMER_MS=0

# Sets _IX_HOOK_TIMER_MS to a millisecond unix time; never fails. The first
# call picks the clock (and keeps its reading); later calls reuse it.
_ix_hook_timer_now() {
  local _out=""
  case "$_IX_HOOK_TIMER_CLOCK" in
    # The decimal separator follows the locale (`.` or `,`).
    epochrealtime) _out="${EPOCHREALTIME//[.,]/}"; _out="${_out:0:13}" ;;
    gnu_date) _out=$(date +%s%3N 2>/dev/null) || _out="" ;;
    perl)     _out=$(perl -MTime::HiRes=time -e 'printf "%.0f", time*1000' 2>/dev/null) || _out="" ;;
    seconds)  _out=$(date +%s 2>/dev/null) && _out="${_out}000" || _out="" ;;
    *)
      if [ -n "${EPOCHREALTIME-}" ]; then
        _IX_HOOK_TIMER_CLOCK=epochrealtime
        _out="${EPOCHREALTIME//[.,]/}"; _out="${_out:0:13}"
      elif _out=$(date +%s%3N 2>/dev/null) && [[ "$_out" =~ ^[0-9]+$ ]]; then
        _IX_HOOK_TIMER_CLOCK=gnu_date
      elif _out=$(perl -MTime::HiRes=time -e 'printf "%.0f", time*1000' 2>/dev/null) \
           && [[ "$_out" =~ ^[0-9]+$ ]]; then
        _IX_HOOK_TIMER_CLOCK=perl
      else
        _IX_HOOK_TIMER_CLOCK=seconds
        _out=$(date +%s 2>/dev/null) && _out="${_out}000" || _out=""
      fi ;;
  esac
  [[ "$_out" =~ ^[0-9]+$ ]] || _out=0
  _IX_HOOK_TIMER_MS="$_out"
}

_ix_hook_timer_exit() {
  local _rc=$?
  set +e +u
  local _t0="$_IX_HOOK_TIMER_MS" _ms _ts _tool="" _re='"tool_name"[[:space:]]*:[[:space:]]*"([^"\\]*)"'
  _ix_hook_timer_now
  _ms=$(( _IX_HOOK_TIMER_MS - _t0 ))
  { [ "$_t0" -gt 0 ] && [ "$_IX_HOOK_TIMER_MS" -gt 0 ] && [ "$_ms" -ge 0 ]; } 2>/dev/null || _ms=0
  [[ "${INPUT:-}" =~ $_re ]] && _tool="${BASH_REMATCH[1]}"
  # bash 4.2+ formats the time itself; bash 3.2 needs date.
  printf -v _ts '%(%Y-%m-%dT%H:%M:%S)T' -1 2>/dev/null || _ts=""
  [[ "$_ts" =~ ^[0-9] ]] || _ts=$(date '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || echo "?")
  [ -n "${IX_DEBUG_LOG:-}" ] && printf '[%s] [%s] EXIT ms=%s rc=%s tool=%s\n' \
    "$_ts" "$_IX_HOOK_TIMER_NAME" "$_ms" "$_rc" "${_tool:--}" >> "$IX_DEBUG_LOG" 2>/dev/null
  return "$_rc"
}

_ix_hook_timer_now
trap _ix_hook_timer_exit EXIT
