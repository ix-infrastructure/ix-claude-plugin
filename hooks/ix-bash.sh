#!/usr/bin/env bash
# Copyright 2026 Ix Infrastructure Inc.

# ix-bash.sh — PreToolUse hook for Bash
#
# Fires before Claude runs a Bash command. Finds the names its grep/rg searches
# look for and, for each name that is one definition in the graph, says what the
# grep will not: where it is defined and who calls it (ix_definition_context).
# Otherwise it stays silent and the grep answers on its own.
#
# Claude rarely greps for one bare name. It batches: one command with several
# greps (`grep -n A f; grep -rn "B\|C" src | head`), alternations of names,
# `def name` / `class Name`. So every grep/rg in the command is read, each
# alternation is split into its names, a leading declaration keyword is dropped,
# and up to IX_GREP_MAX_NAMES (3) names are answered within IX_GREP_BUDGET_MS
# (6000) of ix time. A name answered once in a session is not answered again.
#
# Output is one line per answered name — not raw JSON dumps.
#
# Off by default: IX_GREP_INTERCEPT=on turns it on (together with the Grep/Glob
# hint in ix-intercept.sh).
#
# Exit 0 + JSON stdout → hookSpecificOutput.additionalContext, Bash still runs
# Exit 0 + no stdout  → no-op, Bash runs normally

# One EXIT line with this run's wall time in IX_DEBUG_LOG; nothing when unset.
[ -z "${IX_DEBUG_LOG:-}" ] || source "${BASH_SOURCE[0]%/*}/lib/timing.sh" ix-bash 2>/dev/null

set -euo pipefail

# Off: exit before reading stdin, jq or the library.
[ "${IX_GREP_INTERCEPT:-off}" = "on" ] || exit 0

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
[ -z "$COMMAND" ] && exit 0
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || echo "")

# Every grep/rg in the command. Commands are split on `;`, `&&`, `||` and
# newlines (not on a single `|`: that is a pipeline, or an alternation inside a
# quoted pattern). Within a segment the search starts at grep/rg, so wrapped
# forms still count:
#   cd src && rg AuthService
#   (cd src; grep AuthService)
#   find . | xargs grep AuthService
SEARCH_CMDS=$(printf '%s\n' "$COMMAND" \
  | sed -E 's/&&|\|\|/\n/g; s/;/\n/g' \
  | grep -oE '(^|[[:space:]|&()])(grep|rg|egrep)[[:space:]].*' \
  | sed -E 's/^[[:space:]|&()]+//; s/[[:space:]]*\)+[[:space:]]*$//' 2>/dev/null) || SEARCH_CMDS=""
[ -z "$SEARCH_CMDS" ] && exit 0

# ── Shared library ────────────────────────────────────────────────────────────
_HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_HOOK_DIR}/lib/index.sh"

ix_health_check
IX_HOOK_NAME="ix-bash"
ix_log "ENTRY command='${COMMAND:0:80}'"

# ── The search pattern of one grep/rg command ────────────────────────────────
# Sets PATTERN: the first double- or single-quoted word, else the first word
# that is not an option.
_pattern_of() {
  local _cmd="$1"
  PATTERN=$(echo "$_cmd" | sed -E 's/^[^"]*[[:space:]]"([^"]+)".*/\1/' 2>/dev/null) || PATTERN=""
  if [ -z "$PATTERN" ] || [ "$PATTERN" = "$_cmd" ]; then
    PATTERN=$(echo "$_cmd" | sed -E "s/^[^']*[[:space:]]'([^']+)'.*/\\1/" 2>/dev/null) || PATTERN=""
  fi
  if [ -z "$PATTERN" ] || [ "$PATTERN" = "$_cmd" ]; then
    PATTERN=$(echo "$_cmd" | sed -E 's/^[[:space:]]*(grep|rg|egrep)[[:space:]]+(-[a-zA-Z0-9]+[[:space:]]+|--[a-zA-Z-]+=[^[:space:]]+[[:space:]]+)*([^-][^ ]*).*/\3/' 2>/dev/null) || PATTERN=""
  fi
  [ "$PATTERN" = "$_cmd" ] && PATTERN=""
  return 0
}

# ── The code names a pattern searches for ────────────────────────────────────
# Prints one name per line, or nothing when the pattern is not a search for
# names (a phrase, a log line, a regex with structure, a secret):
#   AuthService                    → AuthService
#   convertParameters\|parseParams → convertParameters, parseParams
#   ix_ledger_last_turn|ix_append  → ix_ledger_last_turn, ix_append
#   def build_url / class Foo      → build_url / Foo
#   \bmapCwd\b, \<mapCwd\>         → mapCwd
#   "error: could not" / TODO / a.*b / foo(  → nothing
_names_of() {
  local _p="$1" _piece _out=""
  [ ${#_p} -gt 200 ] && return 0
  # Alternation: \| (basic regex) or | (extended); each part on its own line.
  _p=$(printf '%s' "$_p" | sed -E 's/\\\|/\n/g; s/\|/\n/g')
  while IFS= read -r _piece; do
    # Word boundaries and anchors around a name are not part of it.
    _piece=$(printf '%s' "$_piece" | sed -E 's/^(\\b|\\<|\^)+//; s/(\\b|\\>|\$)+$//')
    # A declaration keyword before the name: `def x`, `class X`, `function x`.
    _piece=$(printf '%s' "$_piece" | sed -E 's/^(def|class|function|func|fn|interface|struct|enum|trait|type|const|let|var|public|private|protected|static|async)[[:space:]]+//')
    _piece=$(printf '%s' "$_piece" | sed -E 's/^(def|class|function|func|fn|interface|struct|enum|trait|type)[[:space:]]+//')
    # A secret is checked per part: a whole alternation of camelCase names
    # (`convertParameters\|parseParameters`) reads like a long token.
    if [ "${IX_SKIP_SECRET_PATTERNS:-1}" = "1" ] && ix_looks_like_secret "$_piece"; then
      ix_log "SKIP looks like secret/token"
      continue
    fi
    # Language keywords and builtins name nothing worth a lookup
    # (`grep -n "import\|from"` is a common grep).
    case "$_piece" in
      import|from|export|require|return|self|this|super|None|null|nil|true|false|True|False|async|await|yield|lambda|static|public|private|protected|class|def|function|const|let|var|new|delete|typeof|instanceof|extends|implements|interface|package|module|include|using|namespace|throw|throws|raise|except|catch|try|finally|else|elif|while|for|with|pass|print|println|console|warnings|logging|logger|TODO|FIXME|XXX|NOTE) continue ;;
    esac
    # Only a name (or Owner.name) of 3+ characters counts.
    if printf '%s' "$_piece" | grep -qE '^[A-Za-z_][A-Za-z0-9_]{2,}(\.[A-Za-z_][A-Za-z0-9_]*)?$'; then
      ix_query_intent "$_piece"
      [ "$QUERY_INTENT" = "symbol" ] && _out="${_out}${_piece}"$'\n'
    fi
  done <<< "$_p"
  printf '%s' "$_out"
}

NAMES=""
while IFS= read -r _search; do
  [ -z "$_search" ] && continue
  ix_log "SEARCH command='${_search:0:80}'"
  _pattern_of "$_search"
  [ -z "$PATTERN" ] && continue
  ix_log "PATTERN extracted='${PATTERN:0:80}'"
  NAMES="${NAMES}$(_names_of "$PATTERN")"$'\n'
done <<< "$SEARCH_CMDS"
NAMES=$(printf '%s\n' "$NAMES" | awk 'NF && !seen[$0]++')
if [ -z "$NAMES" ]; then
  ix_log "SKIP literal intent — shell grep will run"
  exit 0
fi

# ── Names already answered in this session ───────────────────────────────────
# The model keeps the earlier answer in context: repeating it only costs tokens.
_SEEN_FILE=""
if [ -n "$SESSION_ID" ] && [ -n "${IX_STATE_DIR:-}" ]; then
  _SEEN_FILE="${IX_STATE_DIR}/grep-answered-$(printf '%s' "$SESSION_ID" | tr -cd 'A-Za-z0-9_-' | cut -c1-64)"
fi

# ── Resolve each name to a definition, and its callers ───────────────────────
# Only locate: the grep about to run lists every text hit itself, so `ix text`
# would only repeat them back.
CONTEXT=""
ANSWERED=""
_max="${IX_GREP_MAX_NAMES:-3}"
_budget="${IX_GREP_BUDGET_MS:-6000}"
_t0=$(ix_now_ms)
_tried=0
while IFS= read -r PATTERN; do
  [ -z "$PATTERN" ] && continue
  [ "$_tried" -ge "$_max" ] && { ix_log "SKIP name cap ${_max} reached"; break; }
  if [ $(( $(ix_now_ms) - _t0 )) -ge "$_budget" ]; then ix_log "SKIP time budget ${_budget}ms spent"; break; fi
  if [ -n "$_SEEN_FILE" ] && [ -f "$_SEEN_FILE" ] && grep -qxF "$PATTERN" "$_SEEN_FILE" 2>/dev/null; then
    ix_log "SKIP '${PATTERN}' already answered this session"
    continue
  fi
  _tried=$(( _tried + 1 ))
  ix_log "RUN ix locate pattern='$PATTERN'"
  _loc_err=$(mktemp)
  ix_log_command ix locate "$PATTERN" --format json
  _loc_status=0
  _LOC_RAW=$(ix_run_bounded "${IX_LOCATE_TIMEOUT:-4}" ix locate "$PATTERN" --format json 2>"$_loc_err") || _loc_status=$?
  if [ "$_loc_status" -ne 0 ]; then
    # An unresolved target exits non-zero but still prints its JSON body (Ix#539):
    # an answer, not a failure. Only an empty body is a failure worth filing.
    if [ -n "$_LOC_RAW" ]; then
      ix_log "MISS ix locate exited ${_loc_status} with a body; treated as no-match"
    else
      ix_capture_async "ix" "ix-locate" "locate failed" "$_loc_status" \
        "ix locate '${PATTERN}'" "$(head -3 "$_loc_err")"
    fi
  fi
  rm -f "$_loc_err"
  [ -z "$_LOC_RAW" ] && { ix_log "SKIP empty ix locate for '${PATTERN}'"; continue; }
  ix_definition_context "$_LOC_RAW"
  [ -z "$DEF_PART" ] && { ix_log "SKIP no single confident definition for '${PATTERN}' — grep answers alone"; continue; }
  # Only the name searched for, as spelled: locate matches case-insensitively,
  # so a grep for the word `parameters` would otherwise be answered with the
  # class `Parameters`. For Owner.name, the definition is named `name`.
  _resolved=$(printf '%s' "$DEF_PART" | sed -E 's/^\[ix\] `([^`]+)`.*/\1/')
  if [ "$_resolved" != "$PATTERN" ] && [ "$_resolved" != "${PATTERN##*.}" ]; then
    ix_log "SKIP '${PATTERN}' resolved to '${_resolved}', another name"
    continue
  fi
  # One line per definition, in this command and in the session.
  _def_key=$(printf '%s' "$DEF_PART" | sed -E 's/; (called from|the graph has).*//')
  if printf '%s\n' "$CONTEXT" | grep -qF "$_def_key" \
     || { [ -n "$_SEEN_FILE" ] && [ -f "$_SEEN_FILE" ] && grep -qxF "def:${_def_key}" "$_SEEN_FILE" 2>/dev/null; }; then
    ix_log "SKIP '${PATTERN}' already answered as the same definition"
    continue
  fi
  [ -n "$_SEEN_FILE" ] && printf 'def:%s\n' "$_def_key" >> "$_SEEN_FILE" 2>/dev/null || true
  CONTEXT="${CONTEXT:+${CONTEXT}$'\n'}${DEF_PART}"
  ANSWERED="${ANSWERED:+${ANSWERED},}${PATTERN}"
  [ -n "$_SEEN_FILE" ] && printf '%s\n' "$PATTERN" >> "$_SEEN_FILE" 2>/dev/null || true
done <<< "$NAMES"

[ -z "$CONTEXT" ] && { ix_log "SKIP nothing resolved — grep answers alone"; exit 0; }

_elapsed_ms=$(( $(ix_now_ms) - _t0 ))
ix_log "DECISION augment ${#CONTEXT} chars (${_elapsed_ms}ms) names=${ANSWERED}"
ix_log_injection "additionalContext" "$CONTEXT"
ix_ledger_append "PreToolUse" "Bash" "${#CONTEXT}" "locate,callers" "1" "" "$_elapsed_ms" \
  "answered shell grep for ${ANSWERED} with definition and callers."

# Context only, in both output styles: no permissionDecision. An "allow" here
# would also skip the user's permission prompt for this tool call.
ix_emit_context "PreToolUse" "$CONTEXT"
exit 0
