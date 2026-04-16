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
# ── Shared library ────────────────────────────────────────────────────────────
_HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_HOOK_DIR}/lib/index.sh"

IX_BRIEFING_CACHE="${TMPDIR:-/tmp}/ix-briefing-cache"
_now=$(date +%s)

# If briefing cache is fresh, stay silent (already injected this window)
if [ -f "$IX_BRIEFING_CACHE" ]; then
  _cached_time=$(head -1 "$IX_BRIEFING_CACHE" 2>/dev/null || echo 0)
  if (( (_now - _cached_time) < BRIEFING_TTL )); then
    exit 0
  fi
fi

# ── Health + pro check ────────────────────────────────────────────────────────
ix_health_check
_t0=$(date +%s%3N 2>/dev/null || echo 0)
ix_check_pro

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

_elapsed_ms=$(( $(date +%s%3N 2>/dev/null || echo 0) - _t0 ))

# ── Model-suffix attribution instruction (C5) ─────────────────────────────────
_channel="${IX_ANNOTATE_CHANNEL:-systemMessage}"
_mode="${IX_ANNOTATE_MODE:-off}"
_SUFFIX_CACHE="${TMPDIR:-/tmp}/ix-model-suffix-instructed"
_suffix_instruction=""
if [ "$_mode" != "off" ] && { [ "$_channel" = "modelSuffix" ] || [ "$_channel" = "both" ]; }; then
  if [ ! -f "$_SUFFIX_CACHE" ]; then
    touch "$_SUFFIX_CACHE"
    _suffix_instruction="[ix meta] Attribution: if you received any lines starting with [ix] since the last user message, end your response with ⟦ix+:<codes>⟧ where codes are: B=briefing, G=grep/glob, R=read, E=edit. Example: ⟦ix+:G R⟧"
  fi
fi

_context="[ix] Session briefing:\n${BRIEFING}"
[ -n "$_suffix_instruction" ] && _context="${_context}\n${_suffix_instruction}"

ix_ledger_append "UserPromptSubmit" "Briefing" "${#_context}" "briefing" "1" "" "$_elapsed_ms"

jq -n --arg ctx "$_context" '{"additionalContext": $ctx}'
exit 0
