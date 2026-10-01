#!/usr/bin/env bash
# Copyright 2026 Ix Infrastructure Inc.

# ix-map.sh — Stop hook (async)
#
# Fires after Claude finishes each response. Asks for the guarded automatic
# map of the project root (ix_request_auto_map in ix-lib.sh) so the next
# session starts from a current graph. Everything that decides whether a map
# actually runs lives there:
#   - root = git top-level of the payload's `cwd` (not a git repo / $HOME → skip)
#   - only an already-mapped project (`ix status` graphCompleted) is refreshed
#   - per-root debounce (IX_MAP_DEBOUNCE_SECONDS, default 300) in a per-user dir
#   - `ix map <root> --silent`, IX_AUTO_MAP=1, run detached from the root
#
# Before, this ran a bare `ix map` from whatever directory the hook started in,
# behind a machine-wide /tmp debounce and lock, inside the hook's 60s timeout —
# while the CLI's own map deadline is far longer, so a slow map was killed
# midway after the debounce had already been written.
#
# System-message annotation (when enabled) is handled by ix-annotate.sh, which
# runs synchronously before this hook so the message appears before the session
# ends. Model-authored "Ix:" lines are injected earlier by ix-briefing.sh.

set -euo pipefail

INPUT=$(cat)

# ── Shared library ────────────────────────────────────────────────────────────
_HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_HOOK_DIR}/lib/index.sh"

ix_health_check
IX_HOOK_NAME="ix-map"

_project_dir=$(ix_payload_project_dir "$INPUT" || true)
ix_log "ENTRY project_dir=${_project_dir:-<none>}"
ix_request_auto_map "$_project_dir"

exit 0
