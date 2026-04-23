#!/usr/bin/env bash
# ix-briefing.sh — UserPromptSubmit hook
#
# Fires at the start of each user prompt. Injects a compact ix session briefing
# once per 10 minutes when ix Pro is available. When model-authored annotation
# is enabled, also injects a per-turn instruction telling Claude to end its
# response with a terse "Ix:" line inferred from the [ix] context it saw.
#
# Exit 0 + JSON stdout → injects additionalContext into the prompt
# Exit 0 + no stdout  → no-op

set -euo pipefail

BRIEFING_TTL=600  # 10 minutes
INPUT=$(cat)

# Bail silently if ix is not in PATH
# ── Shared library ────────────────────────────────────────────────────────────
_HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_HOOK_DIR}/lib/index.sh"

IX_BRIEFING_CACHE="${TMPDIR:-/tmp}/ix-briefing-cache"
_now=$(date +%s)
_channel="${IX_ANNOTATE_CHANNEL:-modelSuffix}"
_mode="${IX_ANNOTATE_MODE:-brief}"
_annotation_instruction=""

if [ "$_mode" != "off" ] && { [ "$_channel" = "modelSuffix" ] || [ "$_channel" = "both" ]; }; then
  _annotation_instruction='[ix meta] Attribution: if you received any lines starting with [ix] since the last user message, you must end your response with exactly this final structure and nothing after it:\nIx\n- <short bullet about how ix was used>\n- <optional second short bullet about what ix helped with>\nRules:\n- Use the heading exactly: Ix\n- Use 1 or 2 markdown bullets only\n- Do not write a prose paragraph\n- Do not put anything after the Ix section\n- Each bullet must be short, factual, and derived only from the [ix] lines you actually saw this turn\n- Do not mention search, read, edit, or session context unless it actually happened\n- Do not add an Ix section if you received no [ix] lines this turn\nExample:\nIx\n- surfaced symbol matches before search\n- flagged edit blast radius before modification'
fi

_briefing_fresh=0
if [ -f "$IX_BRIEFING_CACHE" ]; then
  _cached_time=$(head -1 "$IX_BRIEFING_CACHE" 2>/dev/null || echo 0)
  if (( (_now - _cached_time) < BRIEFING_TTL )); then
    _briefing_fresh=1
  fi
fi

if [ "$_briefing_fresh" -eq 1 ] && [ -z "$_annotation_instruction" ]; then
  exit 0
fi

# ── Health + pro check ────────────────────────────────────────────────────────
ix_health_check
IX_HOOK_NAME="ix-briefing"
_t0=""
ix_log "ENTRY mode=${_mode:-off} channel=${_channel:-?} fresh=${_briefing_fresh}"
BRIEFING=""
if [ "$_briefing_fresh" -eq 0 ] && ix_check_pro; then
  ix_log "RUN ix briefing (stale, Pro available)"
  ix_log_command ix briefing --format json
  _t0=$(ix_now_ms)
  _bfr_err=$(mktemp)
  BRIEFING=$(ix briefing --format json 2>"$_bfr_err") || {
    _exit=$?
    ix_capture_async "ix" "ix-briefing" "ix briefing failed" "$_exit" \
      "ix briefing" "$(head -3 "$_bfr_err")"
    rm -f "$_bfr_err"
    BRIEFING=""
  }
  rm -f "$_bfr_err"
  [ -n "$BRIEFING" ] && { echo "$_now"; echo "$BRIEFING"; } > "$IX_BRIEFING_CACHE"
  ix_log "BRIEFING result=${#BRIEFING} chars"
elif [ "$_briefing_fresh" -eq 1 ]; then
  ix_log "SKIP briefing TTL fresh"
else
  ix_log "SKIP briefing (no Pro or failed)"
fi

_elapsed_ms=0
[ -n "$_t0" ] && _elapsed_ms=$(( $(ix_now_ms) - _t0 ))

_context=""
if [ -n "$BRIEFING" ]; then
  _context="[ix] Session briefing:\n${BRIEFING}"
  ix_ledger_append "UserPromptSubmit" "Briefing" "${#_context}" "briefing" "1" "" "$_elapsed_ms" \
    "loaded project context up front from goals, plans, and recent decisions."
fi
[ -n "$_annotation_instruction" ] && {
  if [ -n "$_context" ]; then
    _context="${_context}\n${_annotation_instruction}"
  else
    _context="${_annotation_instruction}"
  fi
}

[ -n "$_context" ] || { ix_log "DECISION silent (no content to inject)"; exit 0; }
ix_log "DECISION injecting ${#_context} chars additionalContext"
ix_log_injection "additionalContext" "$_context"

jq -n --arg ctx "$_context" '{"additionalContext": $ctx}'
exit 0
