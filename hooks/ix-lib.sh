#!/usr/bin/env bash
# Copyright 2026 Ix Infrastructure Inc.

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
#   IX_STATE_DIR            — per-user (0700) dir holding every hook cache
#   ix_payload_project_dir  — project dir from the hook payload (cwd)
#   ix_git_root             — canonical git root of a dir (fails for $HOME)
#   ix_request_auto_map     — the guarded, debounced, detached root `ix map`
#   ix_health_check         — validate ix availability, emit one-time notice if missing
#   ix_check_pro            — check ix pro is available; returns 0/1 after ix_health_check
#   ix_normalize_path_for_ix — convert absolute hook paths into ix-usable relative scopes
#   ix_log_command          — log a fully expanded ix CLI command
#   ix_log_injection        — log exact injected hook content with escaped newlines
#   parse_json              — strip ix header noise, extract first JSON value
#   ix_confidence_gate      — evaluate confidence; sets CONF_GATE (drop|warn|ok) and CONF_WARN
#   ix_emit_context         — emit hookSpecificOutput.additionalContext for an event
#   ix_hook_decide          — emit PreToolUse block/augment/allow output (legacy or structured block)
#   ix_hook_fallback        — degrade block/augment decisions to augment/allow when empty
#   ix_query_intent         — classify Grep patterns as symbol-like or literal
#   ix_run_bounded          — run a command under a wall-clock bound where possible
#   ix_looks_like_secret    — returns 0 if pattern looks like a secret/token; 1 otherwise
#   ix_run_text_locate      — run ix text + ix locate in parallel
#   ix_summarize_text       — summarise text results → TEXT_PART
#   ix_summarize_locate     — summarise locate results → LOC_PART

# ── Portable millisecond timestamp ───────────────────────────────────────────
# Usage: ix_now_ms
# Writes a millisecond unix timestamp to stdout. Never fails: every call
# validates the backend's output and falls through to seconds*1000 if the
# chosen backend misbehaves, so `$(( $(ix_now_ms) - _t0 ))` is always safe
# even under `set -euo pipefail`.
#
# Why this exists: `date +%s%3N` uses the GNU `%3N` extension. On macOS BSD
# `date`, `%N` is not recognized and the literal `3N` is appended to the
# seconds field (e.g. `17767202223N`), which breaks bash arithmetic.
#
# Design constraints:
#   - Hooks call this twice per invocation (entry + exit) via command
#     substitution, which runs in a subshell. Shell-local cache state set
#     inside `ix_now_ms` does not propagate back to the parent process.
#   - Exporting the backend as an env var would let subshells skip the probe,
#     but it also lets an attacker or a stray dotfile poison the choice (e.g.
#     `_IX_NOW_MS_BACKEND=gnu_date` on macOS reintroduces the `...3N` bug).
#   - Probing at source time penalises hooks that exit early when `ix` is
#     missing and never call `ix_now_ms` at all.
#
# Solution: cache the probe result in a file under `$TMPDIR` (same pattern
# as `IX_HEALTH_CACHE`). Cache survives across hook invocations so the probe
# runs at most once per user session, and reading it is cheap enough to do
# from every subshell. Callers never read the backend from the environment.
#
# Backend preference (descending by speed / precision):
#   1. `$EPOCHREALTIME`     — bash 5+ built-in, no subprocess, µs precision.
#   2. GNU `date +%s%3N`    — Linux default; validated to reject BSD's `...N`.
#   3. `gdate +%s%3N`       — macOS with `coreutils` installed.
#   4. `perl -MTime::HiRes` — ships with macOS base; ms precision.
#   5. `date +%s` × 1000    — final fallback; seconds-only precision.
# Cache the probe result in a per-user private directory rather than a
# world-visible name like `${TMPDIR}/ix-now-ms-backend`. A shared path is
# subject to TOCTOU races where another local process can swap the file
# between stat and open. Using a directory that only the current user can
# write to removes that attack surface entirely — once the dir is owned by
# us, no other local user can create, replace, or link files inside it.
# If the directory cannot be created or is not owned by us (e.g. a co-tenant
# pre-created it on a shared /tmp), `IX_NOW_MS_CACHE` is cleared and the
# cache is disabled; `ix_now_ms` then probes on each hook invocation.
_IX_CACHE_DIR="${TMPDIR:-/tmp}/ix-plugin-cache-${UID:-$(id -u 2>/dev/null || echo 0)}"
# Only spawn mkdir/chmod on the cold path; the warm path is an `-d` test.
if [ ! -d "$_IX_CACHE_DIR" ]; then
  mkdir -p "$_IX_CACHE_DIR" 2>/dev/null && chmod 700 "$_IX_CACHE_DIR" 2>/dev/null
fi
if [ -d "$_IX_CACHE_DIR" ] && [ -O "$_IX_CACHE_DIR" ] && [ ! -L "$_IX_CACHE_DIR" ]; then
  IX_NOW_MS_CACHE="${_IX_CACHE_DIR}/now-ms-backend"
else
  IX_NOW_MS_CACHE=""
fi

# ── Per-user state directory ─────────────────────────────────────────────────
# Every cache the hooks keep (health, Pro flag, briefing, auto-map debounce)
# lives here, never at a fixed name in a shared /tmp: those names were
# predictable, shared by every user on the machine, and shared by every project
# a user had open. The uid-scoped dir above is preferred; when it is unusable
# (a co-tenant pre-created or symlinked it), fall back to the XDG state dir,
# and failing that to a private dir for this one invocation (no caching).
if [ -n "$IX_NOW_MS_CACHE" ]; then
  IX_STATE_DIR="$_IX_CACHE_DIR"
else
  IX_STATE_DIR=""
  if [ -n "${XDG_STATE_HOME:-}" ] || [ -n "${HOME:-}" ]; then
    _ix_xdg_dir="${XDG_STATE_HOME:-${HOME}/.local/state}/ix-claude-plugin"
    { mkdir -p "$_ix_xdg_dir" && chmod 700 "$_ix_xdg_dir"; } 2>/dev/null || true
    if [ -d "$_ix_xdg_dir" ] && [ -O "$_ix_xdg_dir" ] && [ ! -L "$_ix_xdg_dir" ]; then
      IX_STATE_DIR="$_ix_xdg_dir"
    fi
  fi
  [ -n "$IX_STATE_DIR" ] || IX_STATE_DIR=$(mktemp -d 2>/dev/null || mktemp -d -t ixstateXXXXXX)
fi
IX_HEALTH_CACHE="${IX_STATE_DIR}/healthy"
IX_PRO_CACHE="${IX_STATE_DIR}/pro"

# ── Project root ─────────────────────────────────────────────────────────────
# Usage: ix_payload_project_dir "$HOOK_INPUT"
# The project the host is working in: the hook payload's `cwd`, else
# $CLAUDE_PROJECT_DIR. Never the plugin dir and never the hook's own $PWD guess.
ix_payload_project_dir() {
  local _dir
  _dir=$(printf '%s' "${1:-}" | jq -r '.cwd // empty' 2>/dev/null || true)
  [ -n "$_dir" ] || _dir="${CLAUDE_PROJECT_DIR:-}"
  [ -n "$_dir" ] || return 1
  printf '%s\n' "$_dir"
}

# Usage: ix_git_root DIR
# Prints the canonical git top-level of DIR. Returns 1 when DIR is not inside a
# git work tree, or when the top-level is $HOME (a dotfiles repo is not a
# project, and mapping it would walk the whole home directory).
ix_git_root() {
  local _dir="${1:-}" _root _home
  { [ -n "$_dir" ] && [ -d "$_dir" ]; } || return 1
  _root=$(git -C "$_dir" rev-parse --show-toplevel 2>/dev/null) || return 1
  [ -n "$_root" ] || return 1
  _root=$(cd -P "$_root" 2>/dev/null && pwd) || return 1
  if [ -n "${HOME:-}" ]; then
    _home=$(cd -P "$HOME" 2>/dev/null && pwd) || _home="$HOME"
    [ "$_root" != "$_home" ] || return 1
  fi
  printf '%s\n' "$_root"
}

# ── Guarded automatic map ────────────────────────────────────────────────────
# Usage: ix_request_auto_map PROJECT_DIR
# The only way a hook may run `ix map`. It maps the project ROOT — `ix map`
# rejects a file ("Map path is not a directory") — and only when all hold:
#   1. PROJECT_DIR is in a git work tree whose root is not $HOME.
#   2. No attempt for this root inside IX_MAP_DEBOUNCE_SECONDS (default 300).
#      The window is per root, kept in the per-user state dir, and claimed
#      before the backend is asked, so an unmapped project or a down backend is
#      asked at most once per window too.
#   3. `ix status --root <root>` says the graph is complete. An automatic map
#      never creates a workspace; any failure, timeout or non-JSON is a skip.
# The map itself is detached: it runs `ix map <root> --silent` from the root
# with IX_AUTO_MAP=1 (the CLI then skips it against a remote backend) and
# outlives the hook, so the hook's own timeout can no longer kill it midway.
# Ix holds a per-workspace map lock, so the plugin keeps no lock of its own.
# Always returns 0.
ix_request_auto_map() {
  local _dir="${1:-}" _root _stamp_dir _stamp _now _last _status
  if ! _root=$(ix_git_root "$_dir"); then
    ix_log "AUTOMAP skip: no git root (or root is \$HOME) for ${_dir:-<none>}"
    return 0
  fi

  _stamp_dir="${IX_STATE_DIR}/automap"
  [ -d "$_stamp_dir" ] || mkdir -p "$_stamp_dir" 2>/dev/null || true
  _stamp="${_stamp_dir}/$(hash_string "$_root").last"
  _now=$(date +%s)
  if [ -f "$_stamp" ]; then
    _last=$(head -c 32 "$_stamp" 2>/dev/null | tr -dc '0-9' || true)
    if [ -n "$_last" ] && (( _now - _last < ${IX_MAP_DEBOUNCE_SECONDS:-300} )); then
      ix_log "AUTOMAP skip: debounce ($(( _now - _last ))s ago) for $_root"
      return 0
    fi
  fi
  echo "$_now" > "$_stamp" 2>/dev/null || true

  ix_log_command ix status --format json --root "$_root"
  if command -v timeout >/dev/null 2>&1; then
    _status=$(cd "$_root" && timeout "${IX_AUTO_MAP_STATUS_TIMEOUT:-10}" \
      ix status --format json --root "$_root" 2>/dev/null) || _status=""
  else
    _status=$(cd "$_root" && ix status --format json --root "$_root" 2>/dev/null) || _status=""
  fi
  if ! printf '%s' "$(parse_json "$_status")" | jq -e '.graphCompleted == true' >/dev/null 2>&1; then
    ix_log "AUTOMAP skip: $_root is not mapped (or ix status failed)"
    return 0
  fi

  ix_log "AUTOMAP run: ix map $_root --silent (detached)"
  ix_log_command ix map "$_root" --silent
  (
    cd "$_root" || exit 0
    export IX_AUTO_MAP=1
    if command -v setsid >/dev/null 2>&1; then
      setsid ix map "$_root" --silent </dev/null >/dev/null 2>&1 &
    else
      nohup ix map "$_root" --silent </dev/null >/dev/null 2>&1 &
    fi
  ) || true
  return 0
}

_ix_select_now_ms_backend() {
  local _out
  if [ -n "${EPOCHREALTIME-}" ]; then
    printf '%s\n' "epochrealtime"; return 0
  fi
  if _out=$(date +%s%3N 2>/dev/null) && [[ "$_out" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "gnu_date"; return 0
  fi
  if command -v gdate >/dev/null 2>&1 \
     && _out=$(gdate +%s%3N 2>/dev/null) && [[ "$_out" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "gdate"; return 0
  fi
  if command -v perl >/dev/null 2>&1 \
     && _out=$(perl -MTime::HiRes=time -e 'printf "%.0f", time*1000' 2>/dev/null) \
     && [[ "$_out" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "perl"; return 0
  fi
  printf '%s\n' "seconds"
}

ix_now_ms() {
  local _backend _out
  # Only read the cache if it is a plain regular file and not a symlink. The
  # parent directory is user-owned (see `_IX_CACHE_DIR` setup), so these
  # checks close a vanishingly small TOCTOU window and also defend against a
  # pre-existing file left by an earlier run that somehow became a FIFO or
  # symlink. `head -c` caps the read so a pathological file cannot block or
  # exhaust memory.
  if [ -n "$IX_NOW_MS_CACHE" ] && [ -f "$IX_NOW_MS_CACHE" ] && [ ! -L "$IX_NOW_MS_CACHE" ]; then
    _backend=$(head -c 32 "$IX_NOW_MS_CACHE" 2>/dev/null | tr -d '[:space:]' || true)
  fi
  if [ -z "${_backend:-}" ]; then
    _backend=$(_ix_select_now_ms_backend)
    # Write via a sibling tempfile + rename so we never open the cache path
    # itself for writing. `printf > FIFO` would block waiting for a reader,
    # hanging every hook; `mv` atomically replaces the FIFO/symlink/regular
    # file with our tempfile instead. Content is deterministic (one of 5
    # known strings), so concurrent writers are idempotent.
    if [ -n "$IX_NOW_MS_CACHE" ]; then
      local _tmp_cache
      _tmp_cache=$(mktemp "${IX_NOW_MS_CACHE}.XXXXXX" 2>/dev/null) && {
        { printf '%s\n' "$_backend" > "$_tmp_cache"; } 2>/dev/null \
          && mv -f "$_tmp_cache" "$IX_NOW_MS_CACHE" 2>/dev/null \
          || rm -f "$_tmp_cache" 2>/dev/null
      } || true
    fi
  fi

  case "$_backend" in
    epochrealtime)
      if [ -n "${EPOCHREALTIME-}" ]; then
        local _er="${EPOCHREALTIME/./}"
        _out="${_er:0:13}"
      fi
      ;;
    gnu_date) _out=$(date +%s%3N 2>/dev/null || true) ;;
    gdate)    _out=$(gdate +%s%3N 2>/dev/null || true) ;;
    perl)     _out=$(perl -MTime::HiRes=time -e 'printf "%.0f", time*1000' 2>/dev/null || true) ;;
  esac

  if [[ "${_out:-}" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$_out"; return 0
  fi

  # Always-safe fallback: seconds × 1000. Catches a poisoned cache, a backend
  # that stopped working after cache was written, or a bad env override.
  _out=$(date +%s 2>/dev/null || echo 0)
  [[ "$_out" =~ ^[0-9]+$ ]] || _out=0
  printf '%s\n' "$(( _out * 1000 ))"
}

# ── Portable hash helper ──────────────────────────────────────────────────────
# Usage: hash_string "some string"
# Writes a lowercase hex digest to stdout. Tries md5sum (Linux), md5 -q (macOS),
# shasum -a 256, then Python 3 as a final fallback.
hash_string() {
  local _input="$1" _out
  if _out=$(printf '%s' "$_input" | md5sum 2>/dev/null) && [ -n "$_out" ]; then
    printf '%s\n' "${_out%% *}"
  elif _out=$(printf '%s' "$_input" | md5 -q 2>/dev/null) && [ -n "$_out" ]; then
    printf '%s\n' "$_out"
  elif _out=$(printf '%s' "$_input" | shasum -a 256 2>/dev/null) && [ -n "$_out" ]; then
    printf '%s\n' "${_out%% *}"
  else
    python3 -c "import hashlib,sys; print(hashlib.md5(sys.argv[1].encode()).hexdigest())" "$_input"
  fi
}

# ── Health check (no ix status — commands fail fast on their own) ─────────────
# Keeps a 300s TTL cache so ix_check_pro can schedule re-checks without
# calling ix status (which takes 6s+ and would reliably timeout 10s hooks).
ix_health_check() {
  local _now _cached _ix_notify_file
  if ! command -v ix >/dev/null 2>&1; then
    _ix_notify_file="${IX_STATE_DIR}/unavailable-notified"
    if [ ! -f "$_ix_notify_file" ]; then
      : > "$_ix_notify_file" 2>/dev/null || true
      jq -cn '{"systemMessage": "ix not found — hooks are inactive. Install ix from https://ix.infrastructure or run: npm i -g @ix/cli"}'
    fi
    exit 0
  fi
  _now=$(date +%s)
  if [ -f "$IX_HEALTH_CACHE" ]; then
    _cached=$(cat "$IX_HEALTH_CACHE" 2>/dev/null || echo 0)
    (( (_now - _cached) < 300 )) && return 0
  fi
  echo "$_now" > "$IX_HEALTH_CACHE"
}

# ── Bounded command runner ───────────────────────────────────────────────────
# Usage: ix_run_bounded <seconds> <command> [args...]
# Runs the command with a wall-clock bound where the platform can enforce one,
# and unchanged where it cannot. `timeout` is coreutils: present on Linux and on
# a macOS with coreutils installed, absent on a stock macOS (where it is
# `gtimeout`, if at all). Rather than hand-roll a watchdog in a hook running
# under `set -euo pipefail`, an unbounded run is the fallback — the callers that
# matter also cache their result before running, so an overrun costs one hook
# invocation rather than every one after it.
ix_run_bounded() {
  local _secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$_secs" "$@"
    return $?
  fi
  if command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$_secs" "$@"
    return $?
  fi
  "$@"
}

# ── Pro check (TTL tied to health check) ─────────────────────────────────────
# Returns 0 when ix briefing is available, 1 otherwise.
# Re-checks pro only when health was just refreshed (avoids redundant ix calls).
# Call after ix_health_check.
ix_check_pro() {
  local _health_ts _pro_ts _pro_val
  _health_ts=$(cat "$IX_HEALTH_CACHE" 2>/dev/null || echo "0")
  _pro_ts=$(cat "${IX_PRO_CACHE}.ts" 2>/dev/null || echo "")
  if [ "$_pro_ts" != "$_health_ts" ]; then
    # Probe with the real command, not `--help`.
    #
    # Pro commands are always *registered*: without @ix/pro the CLI installs a
    # stub for each one whose action prints "The 'briefing' command requires Ix
    # Pro." and exits 1. But commander handles --help before any action runs, so
    # `ix briefing --help` exits 0 on a stub exactly as it does on the real
    # command. Probing with it reported Pro as available on every OSS install,
    # and the briefing hook then ran a Pro command that could only fail.
    #
    # Running the command itself is the discriminator: stub exits 1, real exits
    # 0. This is also what skills/shared.md has always told the model to do —
    # the shell hook was the odd one out. Called after ix_health_check, so the
    # backend is already known reachable.
    #
    # The cache is claimed BEFORE the probe, and bounded while it runs. The
    # hook that calls this has a 10s budget and the probe can take most of it;
    # when the hook was killed mid-probe the timestamp was never written, so
    # the next prompt probed again, and the one after that — a stall on every
    # single prompt, for as long as the backend was slow. Writing "not Pro"
    # up front costs at most one TTL of a missed briefing and bounds the
    # damage to one prompt.
    echo "0" > "$IX_PRO_CACHE"
    echo "$_health_ts" > "${IX_PRO_CACHE}.ts"
    ix_log_command ix briefing --format json
    if ix_run_bounded "${IX_PRO_PROBE_TIMEOUT:-5}" ix briefing --format json >/dev/null 2>&1; then
      echo "1" > "$IX_PRO_CACHE"
    else
      ix_log "PRO probe failed or timed out — treating as OSS until $(( ${IX_PRO_PROBE_TIMEOUT:-5} ))s after the next health refresh"
    fi
  fi
  _pro_val=$(cat "$IX_PRO_CACHE" 2>/dev/null || echo "0")
  [ "$_pro_val" = "1" ]
}

# ── Path normalizer for ix path-scoped commands ──────────────────────────────
# Usage: ix_normalize_path_for_ix PATH [CWD]
# Converts absolute hook paths into a relative scope that ix can resolve.
# Strategy:
#   - Relative paths pass through unchanged.
#   - Absolute paths walk up from CWD (or $PWD) until the path has a matching
#     ancestor prefix with a non-empty suffix.
#   - Falls back to basename if no usable relative scope can be derived.
ix_normalize_path_for_ix() {
  local _path="${1:-}" _cwd="${2:-${PWD:-}}" _base _rel
  [ -z "$_path" ] && return 1

  if [[ "$_path" != /* ]]; then
    printf '%s\n' "$_path"
    return 0
  fi

  _base="${_cwd:-${PWD:-}}"
  while [ -n "$_base" ] && [ "$_base" != "/" ] && [ "$_base" != "." ]; do
    case "$_path" in
      "$_base"/*)
        _rel="${_path#"${_base}/"}"
        if [ -n "$_rel" ]; then
          printf '%s\n' "$_rel"
          return 0
        fi
        ;;
    esac
    _base=$(dirname "$_base")
  done

  basename "$_path"
}

# ── Debug log helpers ────────────────────────────────────────────────────────
# Usage: ix_log_command ix text foo --format json
# Logs a shell-escaped command line so hook runs are easy to replay manually.
ix_log_command() {
  [ -z "${IX_DEBUG_LOG:-}" ] && return 0
  local _rendered
  printf -v _rendered '%q ' "$@"
  _rendered="${_rendered% }"
  ix_log "CMD ${_rendered}"
}

# Usage: ix_log_injection additionalContext "$CONTEXT"
# Logs the exact injected content with newlines escaped as JSON string syntax.
ix_log_injection() {
  [ -z "${IX_DEBUG_LOG:-}" ] && return 0
  local _label="$1" _content="${2:-}" _escaped
  _escaped=$(printf '%s' "$_content" | jq -Rs . 2>/dev/null || printf '%s' "$_content")
  ix_log "INJECT ${_label}=${_escaped}"
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
  local _text_tmp _loc_tmp _text_err _loc_err _TEXT_PID _LOC_PID _is_plain _loc_status
  local _TEXT_ARGS=("$_pattern" "--limit" "15" "--format" "json")
  [ -n "$_path_arg" ] && _TEXT_ARGS+=("--path" "$_path_arg")
  [ -n "$_lang_arg" ] && _TEXT_ARGS+=("--language" "$_lang_arg")

  _text_tmp=$(mktemp); _loc_tmp=$(mktemp)
  _text_err=$(mktemp); _loc_err=$(mktemp)

  ix_log_command ix text "${_TEXT_ARGS[@]}"
  ix text "${_TEXT_ARGS[@]}" > "$_text_tmp" 2>"$_text_err" &
  _TEXT_PID=$!

  _is_plain=1
  # Length guard: patterns shorter than 2 chars are too ambiguous for locate
  [ "${#_pattern}" -lt 2 ] && _is_plain=0
  # Block locate only for patterns that look like actual regex metacharacters:
  #   quantifiers: * + ?
  #   character classes: [ ]
  #   groups: ( )
  #   escape sequences: \d \w \s etc. (\\ followed by a word char)
  #   quantifier braces with digit/comma: {N} or {N,M}
  # Allowed: . _ - / : (all valid in qualified symbol names like module.method or config.ts)
  if [ "$_is_plain" -eq 1 ] && \
     printf '%s\n' "$_pattern" | grep -qE '[*+?]|[][()]|\\\w|\{[0-9]'; then
    _is_plain=0
  fi
  _LOC_PID=""
  if [ "$_is_plain" -eq 1 ]; then
    ix_log_command ix locate "$_pattern" --format json
    ix locate "$_pattern" --format json > "$_loc_tmp" 2>"$_loc_err" &
    _LOC_PID=$!
  else
    ix_log "SKIP ix locate pattern treated as non-plain"
  fi

  wait "$_TEXT_PID" || ix_capture_async "ix" "ix-text" "text search failed" "$?" \
    "ix text '${_pattern}'" "$(head -3 "$_text_err")"
  [ -n "$_LOC_PID" ] && {
    # `_loc_status=0; wait || _loc_status=$?` rather than a bare `wait`: these
    # hooks run under `set -euo pipefail`, so an unguarded non-zero `wait` kills
    # the hook outright. The `||` also keeps $? intact, which `if ! wait` would
    # have replaced with the negation's own result.
    _loc_status=0
    wait "$_LOC_PID" || _loc_status=$?
    if [ "$_loc_status" -ne 0 ]; then
      # An unresolved target exits non-zero but still prints its JSON body
      # (Ix#539). That is an answer, not a failure -- filing it would record an
      # error for every symbol a user asks about that does not happen to exist,
      # and bury real locate failures in the ledger. Only an empty body is a
      # genuine failure.
      if [ -s "$_loc_tmp" ]; then
        ix_log "MISS ix locate exited ${_loc_status} with a body; treated as no-match"
      else
        ix_capture_async "ix" "ix-locate" "locate failed" "$_loc_status" \
          "ix locate '${_pattern}'" "$(head -3 "$_loc_err")"
      fi
    fi
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

# ── Confidence gate ───────────────────────────────────────────────────────────
# Usage: ix_confidence_gate <confidence_value>
# Sets globals: CONF_GATE ("drop" | "warn" | "ok") and CONF_WARN (string, empty if ok/drop)
# Callers check CONF_GATE:
#   "drop" → discard structural data or skip injection entirely
#   "warn" → include CONF_WARN in context output
#   "ok"   → proceed normally
ix_confidence_gate() {
  local _c="$1"
  CONF_GATE="ok"
  CONF_WARN=""
  if awk "BEGIN {c=${_c}+0; exit !(c < 0.3)}"; then
    CONF_GATE="drop"
  elif awk "BEGIN {c=${_c}+0; exit !(c < 0.6)}"; then
    CONF_GATE="warn"
    CONF_WARN="⚠ Graph confidence low (${_c}) — treat structural data as approximate"
  fi
}

# ── Hook output: model context ───────────────────────────────────────────────
# Usage: ix_emit_context <hookEventName> <text>
# Claude Code reads hook-supplied model context only from
# hookSpecificOutput.additionalContext, and only when hookSpecificOutput's
# hookEventName names the event that fired the hook (it rejects a mismatch). A
# top-level `additionalContext` is dropped with "Hook JSON output had
# unrecognized keys (ignored): additionalContext" (Claude Code 2.1.287 hook
# output schema; https://code.claude.com/docs/en/hooks#add-context-for-claude).
# No permissionDecision: this only adds context. A PreToolUse "allow" would also
# skip the user's permission prompt for the tool call it rides on.
ix_emit_context() {
  jq -cn --arg e "$1" --arg c "$2" \
    '{"hookSpecificOutput": {"hookEventName": $e, "additionalContext": $c}}'
}

# ── Hook output decision helper (PreToolUse) ─────────────────────────────────
# Usage: ix_hook_decide <mode> <content>
#   mode    — "block" | "augment" | "allow"
#   content — reason string (block) or context string (augment); ignored for allow
# Emits the Claude Code PreToolUse JSON and exits.
#   block   — the tool call is denied and `content` is what the model receives
#             in place of the tool result. Structured: permissionDecision
#             "deny" + permissionDecisionReason (the enum is allow|deny|ask|
#             defer; "block" fails validation). Legacy: top-level
#             decision "block" + reason, which Claude Code still honours for
#             PreToolUse as a deny with that reason.
#   augment — the tool runs; `content` reaches the model next to its result.
#   allow   — no output; the tool runs under the user's normal permissions.
ix_hook_decide() {
  local _mode="$1"
  local _content="${2:-}"
  case "$_mode" in
    block)
      if [ "${IX_HOOK_OUTPUT_STYLE:-legacy}" = "structured" ]; then
        jq -cn --arg r "$_content" '{
          "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": $r
          }
        }'
      else
        jq -cn --arg r "$_content" '{"decision": "block", "reason": $r}'
      fi
      ;;
    augment)
      ix_emit_context "PreToolUse" "$_content"
      ;;
    allow|*)
      exit 0
      ;;
  esac
  exit 0
}

# ── Hook output fallback helper ──────────────────────────────────────────────
# Usage: ix_hook_fallback <intended_mode> <content> [<augment_fallback_content>]
# Fallback chain: block → augment → allow, augment → allow.
ix_hook_fallback() {
  local _intended="$1"
  local _content="${2:-}"
  local _augment_fallback="${3:-}"

  case "$_intended" in
    block)
      if [ -n "$_content" ]; then
        ix_hook_decide "block" "$_content"
      elif [ -n "$_augment_fallback" ]; then
        ix_hook_decide "augment" "$_augment_fallback"
      else
        ix_hook_decide "allow" ""
      fi
      ;;
    augment)
      if [ -n "$_content" ]; then
        ix_hook_decide "augment" "$_content"
      else
        ix_hook_decide "allow" ""
      fi
      ;;
    *)
      ix_hook_decide "allow" ""
      ;;
  esac
}

# ── Grep query-intent classifier ─────────────────────────────────────────────
# Usage: ix_query_intent <pattern>
# Sets global: QUERY_INTENT ("symbol" | "literal")
# "symbol" → pattern looks like a code symbol/system query → pursue ix lookup
# "literal" → pattern looks like a string/log/doc search → allow native tool
ix_query_intent() {
  local _p="$1"
  QUERY_INTENT="symbol"

  # Pure regex indicators → literal. `|` is in there because an alternation
  # (`pytest|yaml|rich`) is a grep expression, not a symbol: the graph has no
  # entity by that name, so every one of them cost an ix round trip to learn
  # nothing.
  if printf '%s\n' "$_p" | grep -qE '[*+?|]|[][()]|\\\w|\{[0-9]|\^[^^]|\$$'; then
    QUERY_INTENT="literal"; return
  fi

  # Common string/log/doc search patterns → literal
  if printf '%s\n' "$_p" | grep -qiE '^(TODO|FIXME|HACK|NOTE|XXX|DEPRECATED|error:|warn:|info:|debug:|fatal:)'; then
    QUERY_INTENT="literal"; return
  fi

  # Multi-word patterns are usually prose/log searches, not symbol lookups.
  if printf '%s\n' "$_p" | grep -q '[[:space:]]'; then
    QUERY_INTENT="literal"; return
  fi

  # Very long patterns (>60 chars) are likely log lines or prose → literal
  [ "${#_p}" -gt 60 ] && { QUERY_INTENT="literal"; return; }

  # Quoted strings (starts and ends with quote) → literal
  if printf '%s\n' "$_p" | grep -qE "^['\"].*['\"]$"; then
    QUERY_INTENT="literal"; return
  fi

  # Otherwise treat as potential symbol — let confidence gating decide
}

# ── Secret / high-entropy pattern detector ───────────────────────────────────
# Usage: ix_looks_like_secret <pattern>
# Returns 0 (true) if the pattern looks like a secret or API token; 1 otherwise.
# Used to silently skip injection/logging when a search pattern is a credential.
ix_looks_like_secret() {
  local _p="$1"
  # Known secret prefixes (OpenAI, GitHub, GitLab, Bearer tokens, JWTs)
  printf '%s\n' "$_p" | grep -qE '^(sk-|ghp_|ghs_|glpat-|Bearer |eyJ)' && return 0
  # Long high-entropy token (>= 32 chars, mostly base64/hex alphabet)
  local _len="${#_p}"
  if [ "$_len" -ge 32 ]; then
    # Preserve coverage for opaque lowercase-alpha keys without re-flagging
    # snake_case or alternation-heavy code search patterns.
    printf '%s' "$_p" | grep -qE '^[a-z]{32,}$' && return 0
    local _has_signal=0
    printf '%s' "$_p" | grep -q '[0-9]' && _has_signal=1
    if printf '%s' "$_p" | grep -q '[A-Z]' && printf '%s' "$_p" | grep -q '[a-z]'; then
      _has_signal=1
    fi
    printf '%s' "$_p" | grep -q '[+/=]' && _has_signal=1
    [ "$_has_signal" -eq 0 ] && return 1
    local _alnum
    _alnum=$(printf '%s' "$_p" | tr -cd 'A-Za-z0-9+/=_-' | wc -c | tr -d ' ')
    awk "BEGIN { exit !($_alnum / $_len > 0.90) }" && return 0
  fi
  return 1
}

# ── Debug log helper ─────────────────────────────────────────────────────────
# Set IX_DEBUG_LOG=/tmp/ix-hooks.log (or any path) to enable.
# Each hook sets IX_HOOK_NAME before calling this.
ix_log() {
  [ -z "${IX_DEBUG_LOG:-}" ] && return 0
  local _ts
  _ts=$(date '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || echo "?")
  printf '[%s] [%s] %s\n' "$_ts" "${IX_HOOK_NAME:-hook}" "$*" >> "${IX_DEBUG_LOG}" 2>/dev/null || true
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
