#!/usr/bin/env bash
# Copyright 2026 Ix Infrastructure Inc.

# SessionStart also fires after compact: restore the triggers without a backend
# query or a per-prompt reminder. Keep the injected text under 600 bytes.
set -euo pipefail
_HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
jq -n --arg guide "$(cat "${_HOOK_DIR}/ix-cheatsheet.txt")" \
  '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$guide}}'
