#!/usr/bin/env bash
# Copyright 2026 Ix Infrastructure Inc.

# ix-ingest.sh — PostToolUse hook for Write, Edit, MultiEdit, NotebookEdit
#
# Fires after Claude modifies a file. When the file is inside the project, asks
# for the guarded automatic map of the project ROOT (ix_request_auto_map in
# ix-lib.sh: mapped projects only, per-root debounce shared with the Stop hook,
# detached). It no longer maps the edited file: `ix map` takes a directory and
# rejects a file with "Map path is not a directory", so the per-edit map this
# hook used to run failed on every single edit.
#
# Runs async (does not block Claude's response).

set -euo pipefail

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty')
[ -z "$FILE_PATH" ] && exit 0

# ── Shared library ────────────────────────────────────────────────────────────
_HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_HOOK_DIR}/lib/index.sh"

ix_health_check
IX_HOOK_NAME="ix-ingest"

_project_dir=$(ix_payload_project_dir "$INPUT" || true)
ix_log "ENTRY file=$FILE_PATH project_dir=${_project_dir:-<none>}"
[ -z "$_project_dir" ] && exit 0

# An edit outside the project (a scratch file, a config in $HOME) changes
# nothing a map of the project would pick up.
_root=$(ix_git_root "$_project_dir" || true)
case "$FILE_PATH" in
  "$_project_dir"/*) ;;
  *)
    if [ -z "$_root" ] || [[ "$FILE_PATH" != "$_root"/* ]]; then
      ix_log "SKIP file outside project: $FILE_PATH"
      exit 0
    fi
    ;;
esac

ix_request_auto_map "$_project_dir"

exit 0
