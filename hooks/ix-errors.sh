#!/usr/bin/env bash
# ix-errors.sh — Error capture, deduplication, and GitHub reporting
#
# Sourced by ix hooks to enable automatic error capture and issue filing.
# The only public function is ix_capture_async — all others are internal.
#
# Usage (from any hook):
#   _HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "${_HOOK_DIR}/ix-errors.sh" 2>/dev/null || true
#   ix_capture_async "ix" "ix-map" "map failed" "$exit_code" "ix map $file" "$stderr"
#
# Config (env-overridable):
#   IX_ERROR_MODE        off | ask | auto-important | auto-all  (default: auto-important)
#   IX_ERROR_REPO        GitHub repo for issue filing            (default: ix-infrastructure/IX-Memory)
#   IX_ERROR_RATE_WINDOW Min seconds between reports per error   (default: 3600)
#   IX_ERROR_MAX_SESSION Max new issues created per session      (default: 10)

IX_ERROR_MODE="${IX_ERROR_MODE:-auto-important}"
IX_ERROR_REPO="${IX_ERROR_REPO:-ix-infrastructure/IX-Memory}"
IX_ERROR_RATE_WINDOW="${IX_ERROR_RATE_WINDOW:-3600}"
IX_ERROR_MAX_SESSION="${IX_ERROR_MAX_SESSION:-10}"
IX_ERROR_STORE="${HOME}/.local/share/ix/plugin/errors"
_IX_ERR_RATE_FILE="${IX_ERROR_STORE}/rate-limit.json"
_IX_ERR_SESSION_FILE="${TMPDIR:-/tmp}/ix-error-session-count"

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

# ── Stable fingerprint (md5 of normalized type|component|message) ─────────────
_ixe_fp() {
  local norm
  norm=$(printf '%s|%s|%s' "$1" "$2" "$3" \
    | tr '[:upper:]' '[:lower:]' \
    | sed 's/[0-9]\+/N/g' \
    | sed 's|/[^/ ]*||g' \
    | cut -c1-120)
  printf '%s' "$norm" | md5sum | cut -d' ' -f1
}

# ── Short human-readable label ─────────────────────────────────────────────────
_ixe_label() {
  local slug
  slug=$(printf '%s' "$3" | tr '[:upper:]' '[:lower:]' \
    | tr -cs 'a-z0-9' '-' | sed 's/-\+/-/g;s/^-//;s/-$//' | cut -c1-40)
  printf '%s|%s|%s' "$1" "$2" "$slug"
}

_ixe_store_mkdir() { mkdir -p "${IX_ERROR_STORE}/unsent" 2>/dev/null; }

# ── Append error to local JSONL log ───────────────────────────────────────────
# args: type comp msg cmd ec stderr fp fpl
_ixe_store_local() {
  _ixe_store_mkdir
  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")
  jq -cn \
    --arg ts "$ts"    --arg fp "$7"     --arg fpl "$8" \
    --arg type "$1"   --arg comp "$2"   --arg msg "$3" \
    --arg cmd "$4"    --arg ec "$5"     --arg stderr "$6" \
    '{ts:$ts,fp:$fp,fpl:$fpl,type:$type,component:$comp,message:$msg,command:$cmd,exit_code:$ec,stderr:$stderr}' \
    2>/dev/null >> "${IX_ERROR_STORE}/errors.jsonl" 2>/dev/null
}

# ── Rate limit check: 0=allowed, 1=blocked ────────────────────────────────────
_ixe_rate_ok() {
  local sc
  sc=$(cat "$_IX_ERR_SESSION_FILE" 2>/dev/null || echo 0)
  [ "${sc:-0}" -ge "${IX_ERROR_MAX_SESSION}" ] && return 1
  if [ -f "$_IX_ERR_RATE_FILE" ]; then
    local last now
    last=$(jq -r --arg fp "$1" '.[$fp].last_ts // 0' "$_IX_ERR_RATE_FILE" 2>/dev/null || echo 0)
    now=$(date +%s 2>/dev/null || echo 0)
    [ "$(( now - last ))" -lt "${IX_ERROR_RATE_WINDOW}" ] && return 1
  fi
  return 0
}

_ixe_rate_update() {
  # args: fp issue_number
  _ixe_store_mkdir
  local now cur
  now=$(date +%s 2>/dev/null || echo 0)
  cur=$(cat "$_IX_ERR_RATE_FILE" 2>/dev/null || echo "{}")
  printf '%s' "$cur" | jq -c \
    --arg fp "$1" --argjson now "$now" --arg iss "${2:-}" \
    '.[$fp] = {last_ts:$now, issue:($iss|tonumber? // null), count:((.[$fp].count//0)+1)}' \
    2>/dev/null > "${_IX_ERR_RATE_FILE}.tmp" \
    && mv "${_IX_ERR_RATE_FILE}.tmp" "$_IX_ERR_RATE_FILE" 2>/dev/null
  local sc
  sc=$(cat "$_IX_ERR_SESSION_FILE" 2>/dev/null || echo 0)
  printf '%d' $(( sc + 1 )) > "$_IX_ERR_SESSION_FILE" 2>/dev/null
}

_ixe_save_unsent() {
  # args: fp title body labels
  _ixe_store_mkdir
  local ts
  ts=$(date +%s 2>/dev/null || echo 0)
  jq -cn --arg fp "$1" --arg title "$2" --arg body "$3" --arg labels "$4" \
    --argjson ts "$ts" '{fp:$fp,title:$title,body:$body,labels:$labels,ts:$ts}' \
    2>/dev/null > "${IX_ERROR_STORE}/unsent/${ts}-${1:0:8}.json" 2>/dev/null
}

_ixe_ensure_label() {
  # Cache label creation to avoid repeated API calls
  local cache="${IX_ERROR_STORE}/.lbl-$(printf '%s' "$2" | tr -cs 'a-z0-9' '_')"
  [ -f "$cache" ] && return 0
  gh label create "$2" --repo "$1" --color "${3:-d93f0b}" --force 2>/dev/null
  touch "$cache" 2>/dev/null
}

# ── Create or comment on a GitHub issue ───────────────────────────────────────
# args: type comp msg cmd ec stderr fp fpl version
_ixe_github_report() {
  command -v gh >/dev/null 2>&1 || return 1
  _ixe_rate_ok "$7" || return 0

  _ixe_ensure_label "$IX_ERROR_REPO" "auto-reported" "0075ca"
  local labels="auto-reported"
  case "$1" in
    plugin)      _ixe_ensure_label "$IX_ERROR_REPO" "plugin-bug"      "d93f0b"
                 labels="${labels},plugin-bug" ;;
    ix)          _ixe_ensure_label "$IX_ERROR_REPO" "ix-bug"          "e4e669"
                 labels="${labels},ix-bug" ;;
    integration) _ixe_ensure_label "$IX_ERROR_REPO" "integration-bug" "cc317c"
                 labels="${labels},integration-bug" ;;
  esac

  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u)

  # Look up known existing issue number from local rate-limit store
  local existing=""
  [ -f "$_IX_ERR_RATE_FILE" ] && \
    existing=$(jq -r --arg fp "$7" '.[$fp].issue // empty' "$_IX_ERR_RATE_FILE" 2>/dev/null || echo "")

  local title="[IX Error][${1}] ${2}: ${3:0:60}"
  local stderr_block=""
  [ -n "$6" ] && stderr_block=$(printf '\n### Stderr\n\n```\n%s\n```' "$6")

  if [ -n "$existing" ] && [ "$existing" != "null" ]; then
    local comment
    comment=$(printf '**Recurrence** — %s\n\n- Exit: `%s`\n- Action: `%s`%s' \
      "$ts" "$5" "$4" "$stderr_block")
    gh issue comment "$existing" --repo "$IX_ERROR_REPO" --body "$comment" >/dev/null 2>&1
    _ixe_rate_update "$7" "$existing"
    return 0
  fi

  local body
  body=$(cat <<BODY
## Summary

Auto-reported by ix-claude-plugin.

## Context

- **Component:** \`${2}\`
- **Type:** ${1}
- **Action:** \`${4}\`

## Error

- **Message:** ${3}
- **Exit code:** \`${5}\`
${stderr_block}

## Metadata

- Plugin version: \`${9}\`
- Timestamp: ${ts}
- Retry: yes

---
> Sensitive data was redacted automatically.
> <!-- fp:${7} fpl:${8} -->
BODY
)

  local url issue_num
  url=$(gh issue create --repo "$IX_ERROR_REPO" --title "$title" \
    --body "$body" --label "$labels" 2>/dev/null) \
    || { _ixe_save_unsent "$7" "$title" "$body" "$labels"; return 0; }
  issue_num=$(printf '%s' "$url" | grep -oE '[0-9]+$' || echo "")
  _ixe_rate_update "$7" "$issue_num"
}

# ── Public: capture and report asynchronously (fire-and-forget) ───────────────
# Usage: ix_capture_async <type> <component> <message> <exit_code> [cmd_summary] [stderr]
#   type: plugin | ix | integration | unknown
ix_capture_async() {
  [ "${IX_ERROR_MODE:-auto-important}" = "off" ] && return 0
  [ -z "${1:-}" ] && return 0

  local _type="$1" _comp="$2" _msg="${3:-unknown error}" \
        _ec="${4:-1}" _cmd="${5:-}" _stderr="${6:-}"

  (
    set +e  # Never let errors abort the background reporter

    local cmsg cstderr ccmd fp fpl
    cmsg=$(_ixe_redact "$(_ixe_normalize "$_msg")")
    cstderr=$(_ixe_redact "$(printf '%s' "$_stderr" | head -5 | cut -c1-300)")
    ccmd=$(_ixe_redact "$_cmd")
    fp=$(_ixe_fp "$_type" "$_comp" "$cmsg")
    fpl=$(_ixe_label "$_type" "$_comp" "$cmsg")

    _ixe_store_local "$_type" "$_comp" "$cmsg" "$ccmd" "$_ec" "$cstderr" "$fp" "$fpl"

    # ask mode: store locally only, no GitHub
    [ "${IX_ERROR_MODE}" = "ask" ] && exit 0

    # Resolve plugin version from cache
    local ver="unknown"
    local vdir
    vdir=$(ls -d ~/.claude/plugins/cache/ix-claude-plugin/ix-memory/*/ 2>/dev/null \
           | sort -V | tail -1)
    [ -n "$vdir" ] && \
      ver=$(jq -r '.version // "unknown"' "${vdir}/.claude-plugin/plugin.json" 2>/dev/null \
            || echo "unknown")

    _ixe_github_report "$_type" "$_comp" "$cmsg" "$ccmd" "$_ec" "$cstderr" "$fp" "$fpl" "$ver"
  ) >/dev/null 2>&1 &
  disown 2>/dev/null || true
}
