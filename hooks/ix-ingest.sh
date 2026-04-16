#!/usr/bin/env bash
# ix-ingest.sh — PostToolUse hook for Write, Edit, MultiEdit, NotebookEdit
#
# Fires after Claude modifies a file. Runs ix map on the changed file to keep
# the graph current so the next query reflects the current code state.
#
# Runs async (does not block Claude's response).

set -euo pipefail

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
[ -z "$FILE_PATH" ] && exit 0

# Bail silently if ix is not in PATH
# ── Shared library ────────────────────────────────────────────────────────────
_HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_HOOK_DIR}/lib/index.sh"

ix_health_check

IX_INGEST_INJECT="${IX_INGEST_INJECT:-off}"

# ── Map file (retry once on failure) ─────────────────────────────────────────
_map_err=$(mktemp)
ix map "$FILE_PATH" >/dev/null 2>"$_map_err" || {
  # Retry once before reporting
  ix map "$FILE_PATH" >/dev/null 2>"$_map_err" || {
    _exit=$?
    ix_capture_async "ix" "ix-map" "ix map failed" "$_exit" \
      "ix map $(basename "$FILE_PATH")" "$(head -3 "$_map_err")"
    rm -f "$_map_err"
    exit 0
  }
}
rm -f "$_map_err"

if [ "$IX_INGEST_INJECT" = "on" ]; then
  jq -n --arg fp "$FILE_PATH" \
    '{"additionalContext": ("[ix] Graph updated — mapped: " + $fp)}'
elif [ "$IX_INGEST_INJECT" = "debug-only" ]; then
  ix_capture_async "ix" "ix-ingest" "mapped: $FILE_PATH" "0" "ix map $FILE_PATH" ""
fi
# Default (off): silent success — no injection, no log

exit 0
