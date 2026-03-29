#!/usr/bin/env bash
# ix-briefing.sh — UserPromptSubmit hook
#
# Fires at the start of each user prompt. Injects a compact ix session briefing
# once per 10 minutes. Requires ix pro — no-op if pro is not installed.
#
# Exit 0 + JSON stdout → injects additionalContext into the prompt
# Exit 0 + no stdout  → no-op

set -euo pipefail

BRIEFING_TTL=600  # 10 minutes

# Bail silently if ix is not in PATH
command -v ix >/dev/null 2>&1 || exit 0

# ── Error reporting ───────────────────────────────────────────────────────────
_HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_HOOK_DIR}/ix-errors.sh" 2>/dev/null || true

IX_BRIEFING_CACHE="${TMPDIR:-/tmp}/ix-briefing-cache"
IX_HEALTH_CACHE="${TMPDIR:-/tmp}/ix-healthy"
IX_PRO_CACHE="${TMPDIR:-/tmp}/ix-pro"
_now=$(date +%s)

# If briefing cache is fresh, stay silent (already injected this window)
if [ -f "$IX_BRIEFING_CACHE" ]; then
  _cached_time=$(head -1 "$IX_BRIEFING_CACHE" 2>/dev/null || echo 0)
  if (( (_now - _cached_time) < BRIEFING_TTL )); then
    exit 0
  fi
fi

# ── Health + pro check (30s TTL cache) ───────────────────────────────────────
_cache_ok=0
if [ -f "$IX_HEALTH_CACHE" ]; then
  _cached=$(cat "$IX_HEALTH_CACHE" 2>/dev/null || echo 0)
  (( (_now - _cached) < 30 )) && _cache_ok=1
fi
if [ "$_cache_ok" -eq 0 ]; then
  ix status >/dev/null 2>&1 || exit 0
  echo "$_now" > "$IX_HEALTH_CACHE"
  ix briefing --help >/dev/null 2>&1 && echo "1" > "$IX_PRO_CACHE" || echo "0" > "$IX_PRO_CACHE"
fi

IX_PRO=$(cat "$IX_PRO_CACHE" 2>/dev/null || echo "0")
[ "$IX_PRO" = "1" ] || exit 0

_bfr_err=$(mktemp)
BRIEFING=$(ix briefing --format json 2>"$_bfr_err") || {
  _exit=$?
  ix_capture_async "ix" "ix-briefing" "ix briefing failed" "$_exit" \
    "ix briefing" "$(head -3 "$_bfr_err")"
  rm -f "$_bfr_err"
  exit 0
}
rm -f "$_bfr_err"
[ -z "$BRIEFING" ] && exit 0

{ echo "$_now"; echo "$BRIEFING"; } > "$IX_BRIEFING_CACHE"

jq -n --arg b "$BRIEFING" \
  '{"additionalContext": ("[ix] Session briefing:\n" + $b)}'
exit 0
