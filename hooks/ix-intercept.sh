#!/usr/bin/env bash
# Copyright 2026 Ix Infrastructure Inc.

# ix-intercept.sh — PreToolUse hook for Grep and Glob
#
# Fires before Grep/Glob executes. For a Grep that names one definition, injects
# where it is defined and who calls it (ix locate + ix callers) as
# additionalContext -- what the Grep's own results cannot say -- and otherwise
# stays silent. For a Glob, runs ix inventory.
#
# Output is a single line, not raw JSON dumps — designed to be acted on,
# not skipped over.
#
# Off by default, Grep and Glob alike: the Grep hint rarely names anything the
# Grep itself does not find, and both run ix (`ix locate` + `ix callers`, or
# `ix inventory`) before the tool does; `ix text` runs only when the hook
# blocks. IX_GREP_INTERCEPT=on turns it on
# (together with the shell-grep hint in ix-bash.sh). So does
# IX_BLOCK_ON_HIGH_CONFIDENCE=1: whoever asked for the block wants this hook.
#
# Exit 0 + JSON stdout, augment → hookSpecificOutput.additionalContext, native
#                                 tool still runs
# Exit 0 + JSON stdout, block   → the native tool call is denied; the reason is
#                                 the whole answer the model receives in its place
# Exit 0 + no stdout            → no-op, native tool runs normally

# One EXIT line with this run's wall time in IX_DEBUG_LOG; nothing when unset.
[ -z "${IX_DEBUG_LOG:-}" ] || source "${BASH_SOURCE[0]%/*}/lib/timing.sh" ix-intercept 2>/dev/null

set -euo pipefail

# Off: exit before reading stdin, jq or the library.
[ "${IX_GREP_INTERCEPT:-off}" = "on" ] || [ "${IX_BLOCK_ON_HIGH_CONFIDENCE:-0}" = "1" ] || exit 0

INPUT=$(cat)
TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty')
[ -z "$TOOL" ] && exit 0
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')

# ── Shared library ────────────────────────────────────────────────────────────
_HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_HOOK_DIR}/lib/index.sh"

ix_health_check
IX_HOOK_NAME="ix-intercept"
ix_log "ENTRY tool=$TOOL"

# ── Grep: text/symbol search ──────────────────────────────────────────────────
if [ "$TOOL" = "Grep" ]; then
  PATTERN=$(echo "$INPUT" | jq -r '.tool_input.pattern // empty')
  [ -z "$PATTERN" ] && { ix_log "SKIP empty pattern"; exit 0; }
  [ ${#PATTERN} -lt 3 ] && { ix_log "SKIP pattern too short (${#PATTERN} chars)"; exit 0; }
  if [ "${IX_SKIP_SECRET_PATTERNS:-1}" = "1" ] && ix_looks_like_secret "$PATTERN"; then
    ix_log "SKIP looks like secret/token"
    exit 0
  fi
  ix_query_intent "$PATTERN"
  ix_log "GREP pattern='$PATTERN' intent=$QUERY_INTENT"
  if [ "$QUERY_INTENT" = "literal" ]; then
    ix_log "SKIP literal intent — native grep will run"
    exit 0
  fi

  # Only locate, as in ix-bash.sh: the Grep about to run lists every text hit
  # itself, so `ix text` would only repeat them back. It runs below only when
  # the hook blocks, where its line stands in for the Grep's own results.
  # ix_query_intent has already sent every regex-looking pattern to the native
  # Grep, so whatever reaches here is a plain name `ix locate` can take.
  ix_log "RUN ix locate pattern='$PATTERN'"
  _t0=$(ix_now_ms)
  _loc_err=$(mktemp)
  ix_log_command ix locate "$PATTERN" --format json
  _loc_status=0
  _LOC_RAW=$(ix_run_bounded "${IX_LOCATE_TIMEOUT:-4}" ix locate "$PATTERN" --format json 2>"$_loc_err") || _loc_status=$?
  if [ "$_loc_status" -ne 0 ]; then
    # An unresolved target exits non-zero but still prints its JSON body
    # (Ix#539): an answer, not a failure. Only an empty body is a failure worth
    # filing -- otherwise every symbol that does not exist files an error.
    if [ -n "$_LOC_RAW" ]; then
      ix_log "MISS ix locate exited ${_loc_status} with a body; treated as no-match"
    else
      ix_capture_async "ix" "ix-locate" "locate failed" "$_loc_status" \
        "ix locate '${PATTERN}'" "$(head -3 "$_loc_err")"
    fi
  fi
  rm -f "$_loc_err"
  [ -z "$_LOC_RAW" ] && { ix_log "SKIP empty ix locate"; exit 0; }

  # Gate on graph confidence from locate result. One jq pass for the four
  # fields: this hook holds up the Grep, and a jq process apiece cost as much
  # as the rest of the hook's own work.
  CONF_WARN=""
  HOOK_MODE="allow"
  LOC_PART=""
  _confidence=""
  _loc_type=""
  _loc_name=""
  _loc_path=""
  _LOC_JSON=$(parse_json "$_LOC_RAW")
  if [ -n "$_LOC_JSON" ]; then
    _loc_fields=$(printf '%s' "$_LOC_JSON" | jq -r '
      [ ((.confidence // (.resolvedTarget.confidence // 1)) | tostring),
        (.resolvedTarget.type // .resolvedTarget.kind // "unknown"),
        (.resolvedTarget.name // ""),
        (.resolvedTarget.path // "") ]
      | map(tostring | gsub("[\u001f\n]"; " ")) | join("\u001f")' 2>/dev/null) || _loc_fields=""
    [ -n "$_loc_fields" ] && IFS=$'\x1f' read -r _confidence _loc_type _loc_name _loc_path <<< "$_loc_fields" || true
    [ -n "$_loc_name" ] && LOC_PART="symbol: ${_loc_name} (${_loc_type}${_loc_path:+, ${_loc_path##*/}})"
    ix_log "RESULTS locate='${LOC_PART:-<none>}'"
    ix_confidence_gate "${_confidence:-1}"
    if [ "$CONF_GATE" = "drop" ]; then
      LOC_PART=""
      ix_log "CONFIDENCE gate=drop conf=${_confidence:-?} → suppressing ix injection"
    fi
    if [ "${IX_BLOCK_ON_HIGH_CONFIDENCE:-0}" = "1" ] && [ "$QUERY_INTENT" = "symbol" ] && \
       [ "$CONF_GATE" = "ok" ] && [ -n "$_loc_name" ] && [ -n "$_loc_path" ]; then
      HOOK_MODE="block"
    fi
    ix_log "CONFIDENCE gate=$CONF_GATE conf=${_confidence:-?} → mode=$HOOK_MODE"
  fi

  # Augment with what the Grep about to run cannot say -- the definition and
  # its callers -- or with nothing. Its own results list every text hit, so a
  # summary of `ix text`'s hits, or candidate names with a pointer to more ix
  # commands, only repeated them (see ix_definition_context).
  DEF_PART=""
  ix_definition_context "$_LOC_RAW"
  CONTEXT="$DEF_PART"
  if [ "$HOOK_MODE" != "block" ] && [ -n "$DEF_PART" ]; then
    HOOK_MODE="augment"
  fi
  ix_log "DECISION mode=$HOOK_MODE"

# ── Glob: file pattern search ─────────────────────────────────────────────────
elif [ "$TOOL" = "Glob" ]; then
  PATTERN=$(echo "$INPUT" | jq -r '.tool_input.pattern // empty')
  [ -z "$PATTERN" ] && { ix_log "SKIP empty pattern"; exit 0; }

  PATH_ARG=$(echo "$INPUT" | jq -r '.tool_input.path // empty')
  ix_log "GLOB pattern='$PATTERN' path='${PATH_ARG:-<none>}'"
  [ -z "$PATH_ARG" ] && { ix_log "SKIP no path arg (Glob without path, native tool will run)"; exit 0; }

  # Intent classification — allow literal globs through without ix
  GLOB_INTENT="architecture"
  if printf '%s\n' "$PATTERN" | grep -qE '^\*\.[a-zA-Z0-9]+$'; then
    GLOB_INTENT="literal"
  fi
  if printf '%s\n' "$PATTERN" | grep -qE '^[^*]+/[^*]+$'; then
    GLOB_INTENT="literal"
  fi
  ix_log "GLOB intent=$GLOB_INTENT"
  [ "$GLOB_INTENT" = "literal" ] && { ix_log "SKIP literal glob pattern"; exit 0; }

  INV_PATH=$(ix_normalize_path_for_ix "$PATH_ARG" "$CWD" 2>/dev/null || true)
  [ -z "$INV_PATH" ] && INV_PATH="$PATH_ARG"
  INV_ARGS=("--kind" "file" "--format" "json" "--path" "$INV_PATH")

  ix_log "RUN ix inventory raw_path='$PATH_ARG' normalized_path='$INV_PATH' cwd='${CWD:-${PWD:-}}'"
  ix_log_command ix inventory "${INV_ARGS[@]}"
  _t0=$(ix_now_ms)
  _inv_err=$(mktemp)
  # Same rule as the other hooks: a non-zero exit with a body is an answer.
  # `inventory` is not in Ix#547's set today, but it takes a `--path` that may
  # not resolve, and the CLI is moving toward reporting that as a record with a
  # non-zero exit. Guarding now costs nothing and means this hook does not have
  # to be found again later.
  # Bounded (IX_INVENTORY_TIMEOUT, 6s) inside the 10s hooks.json timeout.
  _exit=0
  INV_RAW=$(ix_run_bounded "${IX_INVENTORY_TIMEOUT:-6}" ix inventory "${INV_ARGS[@]}" 2>"$_inv_err") || _exit=$?
  if [ "$_exit" -ne 0 ] && [ -z "$INV_RAW" ]; then
    ix_capture_async "ix" "ix-inventory" "inventory failed" "$_exit" \
      "ix inventory '$INV_PATH' (from '$PATH_ARG')" "$(head -3 "$_inv_err")"
    ix_log "FAILED ix inventory exit=$_exit"
    rm -f "$_inv_err"
    exit 0
  fi
  [ "$_exit" -ne 0 ] && ix_log "MISS ix inventory exited ${_exit} with a body; treated as an answer"
  rm -f "$_inv_err"
  [ -z "$INV_RAW" ] && { ix_log "SKIP empty inventory result"; exit 0; }

  INV_JSON=$(parse_json "$INV_RAW")
  [ -z "$INV_JSON" ] && { ix_log "SKIP inventory parse failed"; exit 0; }

  TOTAL=$(echo "$INV_JSON" | jq -r '(.summary.total // (.results | length) // 0)' 2>/dev/null || echo 0)
  SAMPLE=$(echo "$INV_JSON" | jq -r '[.results[:5][].name] | join(", ")' 2>/dev/null || echo "")

  [ "${TOTAL:-0}" -eq 0 ] && { ix_log "SKIP inventory returned 0 entities"; exit 0; }
  ix_log "INVENTORY total=$TOTAL sample='${SAMPLE:-}'"

  GLOB_HOOK_MODE="augment"
  if [ "${IX_BLOCK_ON_HIGH_CONFIDENCE:-0}" = "1" ] && [ "${TOTAL:-0}" -gt 0 ] && [ "${TOTAL:-0}" -le 20 ]; then
    GLOB_HOOK_MODE="block"
  fi
  ix_log "DECISION mode=$GLOB_HOOK_MODE"

  CONTEXT="[ix inventory] '${PATTERN}' in ${PATH_ARG}: ${TOTAL} entities"
  [ -n "$SAMPLE" ] && CONTEXT="${CONTEXT} — ${SAMPLE}$([ "${TOTAL}" -gt 5 ] && echo ' ...' || echo '')"

else
  ix_log "SKIP unknown tool=$TOOL"
  exit 0
fi

[ -z "${CONTEXT:-}" ] && exit 0

_elapsed_ms=$(( $(ix_now_ms) - _t0 ))
if [ "$TOOL" = "Grep" ]; then
  if [ "$HOOK_MODE" = "block" ]; then
    # A block denies the Grep, so its reason is all the model gets: here, and
    # only here, a one-line summary of the text hits is not a repeat. Bounded
    # short (IX_TEXT_TIMEOUT, 2s) so locate + callers + text stay inside the
    # hook's 10s timeout; on a failure or overrun the line is just left out.
    TEXT_PART=""
    PATH_ARG=$(echo "$INPUT" | jq -r '.tool_input.path // empty')
    LANG_ARG=$(echo "$INPUT" | jq -r '.tool_input.type // empty')
    _TEXT_ARGS=("$PATTERN" "--limit" "15" "--format" "json")
    [ -n "$PATH_ARG" ] && _TEXT_ARGS+=("--path" "$PATH_ARG")
    [ -n "$LANG_ARG" ] && _TEXT_ARGS+=("--language" "$LANG_ARG")
    _text_err=$(mktemp)
    ix_log_command ix text "${_TEXT_ARGS[@]}"
    _text_status=0
    _TEXT_RAW=$(ix_run_bounded "${IX_TEXT_TIMEOUT:-2}" ix text "${_TEXT_ARGS[@]}" 2>"$_text_err") || _text_status=$?
    if [ "$_text_status" -ne 0 ] && [ -z "$_TEXT_RAW" ]; then
      ix_capture_async "ix" "ix-text" "text search failed" "$_text_status" \
        "ix text '${PATTERN}'" "$(head -3 "$_text_err")"
    fi
    rm -f "$_text_err"
    ix_summarize_text "$_TEXT_RAW"
    _elapsed_ms=$(( $(ix_now_ms) - _t0 ))

    REASON="[ix text + ix locate] '${PATTERN}'"
    REASON="${REASON}"$'\n'"Found: ${_loc_name} (${_loc_type:-unknown}) at ${_loc_path}"
    [ -n "$TEXT_PART" ] && REASON="${REASON}"$'\n'"${TEXT_PART}"
    REASON="${REASON}"$'\n'"Next: ix read ${_loc_name} | ix explain ${_loc_name}"
    ix_ledger_append "PreToolUse" "Grep" "${#REASON}" "text,locate" "${_confidence:-1}" "" "$_elapsed_ms" \
      "surfaced a graph-backed match for ${_loc_name:-$PATTERN} and pointed to the right follow-up path."
    echo "ix locate '${PATTERN}' → ${_loc_name} at ${_loc_path} [BLOCKED]" >&2
    ix_hook_fallback "block" "$REASON" "$CONTEXT"
  elif [ "$HOOK_MODE" = "augment" ]; then
    ix_ledger_append "PreToolUse" "Grep" "${#CONTEXT}" "locate,callers" "${_confidence:-1}" "" "$_elapsed_ms" \
      "answered Grep for ${PATTERN} with its definition and callers."
    ix_log_injection "additionalContext" "$CONTEXT"
    echo "ix locate + callers: '${PATTERN}' → ${LOC_PART:-no exact match}" >&2
    ix_hook_fallback "augment" "$CONTEXT"
  else
    exit 0
  fi
else
  if [ "${GLOB_HOOK_MODE:-augment}" = "block" ]; then
    _first_sample=$(printf '%s' "$SAMPLE" | cut -d',' -f1 | tr -d ' ')
    # The reason is all the model gets in place of the Glob result, so it lists
    # every entity ix returned (block only fires at <= 20), not the 5-name
    # sample the augment line uses -- a sample would just send the model back to
    # Glob for the rest.
    _all_names=$(echo "$INV_JSON" | jq -r '[.results[]?.name | select(. != null)] | join(", ")' 2>/dev/null || echo "")
    _shown=$(echo "$INV_JSON" | jq -r '[.results[]?] | length' 2>/dev/null || echo 0)
    REASON="[ix inventory] '${PATTERN}' in ${PATH_ARG}: ${TOTAL} entities — ${_all_names:-$SAMPLE}"
    [ "${_shown:-0}" -lt "${TOTAL:-0}" ] && REASON="${REASON} (${_shown} of ${TOTAL} listed)"
    [ -n "$_first_sample" ] && REASON="${REASON} | Next: ix overview ${_first_sample}"
    ix_ledger_append "PreToolUse" "Glob" "${#REASON}" "inventory" "1" "" "$_elapsed_ms" \
      "surveyed ${PATTERN} with inventory and highlighted likely targets."
    echo "ix inventory: '${PATTERN}' in ${PATH_ARG} → ${TOTAL} entities [BLOCKED]" >&2
    ix_hook_fallback "block" "$REASON" "$CONTEXT"
  else
    ix_ledger_append "PreToolUse" "Glob" "${#CONTEXT}" "inventory" "1" "" "$_elapsed_ms" \
      "surveyed ${PATTERN} with inventory and highlighted likely targets."
    ix_log_injection "additionalContext" "$CONTEXT"
    echo "ix inventory: '${PATTERN}' in ${PATH_ARG} → ${TOTAL} entities" >&2
    ix_hook_fallback "augment" "$CONTEXT"
  fi
fi
exit 0
