#!/usr/bin/env bash
# ix-errors.sh — Error capture and local logging
#
# Sourced by ix hooks to capture errors to a local log.
# No data is sent externally.
#
# Usage (from any hook):
#   _HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "${_HOOK_DIR}/ix-errors.sh" 2>/dev/null || true
#   ix_capture_async "ix" "ix-map" "map failed" "$exit_code" "ix map $file" "$stderr"
#
# Config (env-overridable):
#   IX_ERROR_MODE        off | local  (default: local)

IX_ERROR_MODE="${IX_ERROR_MODE:-local}"
IX_ERROR_STORE="${HOME}/.local/share/ix/plugin/errors"

# ── Redact common secret patterns ─────────────────────────────────────────────
_ixe_redact() {
  printf '%s' "$1" | sed \
    -e 's/[Bb]earer [A-Za-z0-9._~+\/=-]\{20,\}/Bearer [REDACTED]/g' \
    -e 's/ghp_[A-Za-z0-9]\{36,\}/[REDACTED]/g' \
    -e 's/sk-[A-Za-z0-9-]\{32,\}/[REDACTED]/g' \
    -e 's/[Aa][Pp][Ii][-_][Kk]ey=[^ &"'"'"']*/API_KEY=[REDACTED]/g' \
    -e 's/[Tt]oken=[^ &"'"'"']*/TOKEN=[REDACTED]/g' \
    -e "s|${HOME}|~|g"
}

# ── Trim to short single-line summary ─────────────────────────────────────────
_ixe_normalize() {
  printf '%s' "$1" | head -3 | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g;s/^ //;s/ $//' | cut -c1-150
}

# ── Stable fingerprint ────────────────────────────────────────────────────────
_ixe_fp() {
  local norm
  norm=$(printf '%s|%s|%s' "$1" "$2" "$3" \
    | tr '[:upper:]' '[:lower:]' \
    | sed 's/[0-9]\+/N/g' \
    | sed 's|/[^/ ]*||g' \
    | cut -c1-120)
  hash_string "$norm"
}

_ixe_store_mkdir() { mkdir -p "${IX_ERROR_STORE}" 2>/dev/null; }

# ── Append error to local JSONL log ───────────────────────────────────────────
_ixe_store_local() {
  _ixe_store_mkdir
  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")
  jq -cn \
    --arg ts "$ts"    --arg fp "$7" \
    --arg type "$1"   --arg comp "$2"   --arg msg "$3" \
    --arg cmd "$4"    --arg ec "$5"     --arg stderr "$6" \
    '{ts:$ts,fp:$fp,type:$type,component:$comp,message:$msg,command:$cmd,exit_code:$ec,stderr:$stderr}' \
    >> "${IX_ERROR_STORE}/errors.jsonl" 2>/dev/null
}

# ── Public: capture and log locally (fire-and-forget) ─────────────────────────
# Usage: ix_capture_async <type> <component> <message> <exit_code> [cmd_summary] [stderr]
#   type: plugin | ix | integration | unknown
ix_capture_async() {
  [ "${IX_ERROR_MODE:-local}" = "off" ] && return 0
  [ -z "${1:-}" ] && return 0

  local _type="$1" _comp="$2" _msg="${3:-unknown error}" \
        _ec="${4:-1}" _cmd="${5:-}" _stderr="${6:-}"

  (
    set +e
    local cmsg cstderr ccmd fp
    cmsg=$(_ixe_redact "$(_ixe_normalize "$_msg")")
    cstderr=$(_ixe_redact "$(printf '%s' "$_stderr" | head -5 | cut -c1-300)")
    ccmd=$(_ixe_redact "$_cmd")
    fp=$(_ixe_fp "$_type" "$_comp" "$cmsg")
    _ixe_store_local "$_type" "$_comp" "$cmsg" "$ccmd" "$_ec" "$cstderr" "$fp" ""
  ) >/dev/null 2>&1 &
  disown 2>/dev/null || true
}
