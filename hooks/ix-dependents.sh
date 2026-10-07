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
# those. The diff does. A Bash call that changed nothing costs `ix hook` one
# git call and prints nothing.
#
# Never in the way: an older ix without `ix hook`, a backend that is down, an
# unmapped project or a timeout all print nothing and exit 0.
#
# IX_EDIT_DEPENDENTS=off turns it off.
#
# Exit 0 + JSON stdout → hookSpecificOutput.additionalContext after the tool result
# Exit 0 + no stdout  → no-op

set -euo pipefail

[ "${IX_EDIT_DEPENDENTS:-on}" = "off" ] && exit 0
INPUT=$(cat)
TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty')
[ -z "$TOOL" ] && exit 0

# ── Shared library ────────────────────────────────────────────────────────────
_HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_HOOK_DIR}/lib/index.sh"

ix_health_check
IX_HOOK_NAME="ix-dependents"
ix_log "ENTRY tool=$TOOL"

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

_elapsed_ms=$(( $(ix_now_ms) - _t0 ))
ix_log "DECISION augment ${#CONTEXT} chars (${_elapsed_ms}ms)"
ix_log_injection "additionalContext" "$CONTEXT"
ix_ledger_append "PostToolUse" "$TOOL" "${#CONTEXT}" "hook" "1" "" "$_elapsed_ms" \
  "named what depends on the code the edit changed: callers, importers and tests."

ix_emit_context "PostToolUse" "$CONTEXT"
exit 0
