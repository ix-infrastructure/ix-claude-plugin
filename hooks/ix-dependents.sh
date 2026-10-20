#!/usr/bin/env bash
# Copyright 2026 Ix Infrastructure Inc.

# ix-dependents.sh — PostToolUse hook for Edit, MultiEdit, Write and Bash
#
# Fires after Claude changes something. Hands the hook input to
# `ix hook claude-post-edit` (Ix CLI 0.12.1+), which reads the working tree's
# `git diff` against HEAD and, for each code symbol the edit changed, names the
# callers (at their call sites), the importers that use it and the tests that
# reach it -- each symbol once per session, in at most ~300 tokens. That is the
# part of a change an agent most often leaves undone: a caller still passing
# the old arguments, a stale label in another file.
#
# Bash too: agents edit with `python3 - <<EOF` and `sed -i` as often as with
# Edit, and the pre-edit and ingest hooks (matched on the edit tools) never see
# those. The diff does. A Bash command that can only read (`cat`, `ls`,
# `git diff`; see hooks/lib/bash-write.sh) skips `ix hook`: the diff has not
# moved, and the next command that may write catches up. After a report, the
# next command runs it once even if it only reads, as ix carries the symbols it
# capped to its next run. IX_BASH_EDIT_CLASSIFIER=off runs it after every Bash
# command.
#
# Never in the way: an older ix without `ix hook`, a backend that is down, an
# unmapped project or a timeout all print nothing and exit 0.
#
# Off by default: the report rarely names a caller that changes what the agent
# does next, and it blocks every edit and Bash call while it runs.
# IX_EDIT_DEPENDENTS=on turns it on.
#
# Exit 0 + JSON stdout → hookSpecificOutput.additionalContext after the tool result
# Exit 0 + no stdout  → no-op

# One EXIT line with this run's wall time in IX_DEBUG_LOG; nothing when unset.
[ -z "${IX_DEBUG_LOG:-}" ] || source "${BASH_SOURCE[0]%/*}/lib/timing.sh" ix-dependents 2>/dev/null

set -euo pipefail

# Off: exit before reading stdin, jq or the library.
[ "${IX_EDIT_DEPENDENTS:-off}" = "on" ] || exit 0
INPUT=$(cat)
TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty')
[ -z "$TOOL" ] && exit 0
_HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The marker that says this session's last report is owed a follow-up run. It
# lives in the plugin's state dir (IX_STATE_DIR in ix-lib.sh: the uid-scoped
# cache dir, else the XDG one), found here without the library so a read-only
# command can check it cheaply. Empty when neither dir is usable yet.
_dep_owed_marker() {
  local _sid="${1:-none}" _d
  for _d in "${TMPDIR:-/tmp}/ix-plugin-cache-${UID:-0}" \
            "${XDG_STATE_HOME:-${HOME:-/nonexistent}/.local/state}/ix-claude-plugin"; do
    if [ -d "$_d" ] && [ -O "$_d" ] && [ ! -L "$_d" ]; then
      printf '%s/dependents-owed-%s' "$_d" "${_sid//[^A-Za-z0-9_.-]/_}"
      return 0
    fi
  done
}

SESSION=$(echo "$INPUT" | jq -r '.session_id // empty')
_followup=""
if [ "$TOOL" = "Bash" ] && [ "${IX_BASH_EDIT_CLASSIFIER:-on}" != "off" ]; then
  source "${_HOOK_DIR}/lib/bash-write.sh"
  if ! ix_bash_may_write "$(echo "$INPUT" | jq -r '.tool_input.command // empty')"; then
    _owed=$(_dep_owed_marker "$SESSION")
    { [ -n "$_owed" ] && [ -e "$_owed" ]; } || exit 0
    _followup=" (read-only, follow-up after a report)"
  fi
fi

# ── Shared library ────────────────────────────────────────────────────────────
source "${_HOOK_DIR}/lib/index.sh"

ix_health_check
IX_HOOK_NAME="ix-dependents"
ix_log "ENTRY tool=$TOOL${_followup}"

# The library has created the state dir by now; this run settles any debt.
_owed=$(_dep_owed_marker "$SESSION")
if [ -n "$_owed" ] && [ -e "$_owed" ]; then rm -f "$_owed" 2>/dev/null || true; fi

_t0=$(ix_now_ms)
ix_log_command ix hook claude-post-edit
_out=""
_status=0
# `ix hook` keeps its own deadline (IX_HOOK_TIMEOUT_MS, 3s); the bound here is
# for an ix that hangs before it gets that far.
_out=$(printf '%s' "$INPUT" | ix_run_bounded "${IX_DEPENDENTS_TIMEOUT:-8}" ix hook claude-post-edit 2>/dev/null) \
  || _status=$?
if [ "$_status" -ne 0 ]; then
  ix_log "SKIP ix hook exited ${_status} (older ix, or nothing to say)"
  exit 0
fi

CONTEXT=$(printf '%s' "$_out" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null || echo "")
[ -z "$CONTEXT" ] && { ix_log "SKIP no dependents to report"; exit 0; }

# Owe the next command a run, even a read-only one.
{ [ -z "$_owed" ] || : > "$_owed"; } 2>/dev/null || true

_elapsed_ms=$(( $(ix_now_ms) - _t0 ))
ix_log "DECISION augment ${#CONTEXT} chars (${_elapsed_ms}ms)"
ix_log_injection "additionalContext" "$CONTEXT"
ix_ledger_append "PostToolUse" "$TOOL" "${#CONTEXT}" "hook" "1" "" "$_elapsed_ms" \
  "named what depends on the code the edit changed: callers, importers and tests."

ix_emit_context "PostToolUse" "$CONTEXT"
exit 0
