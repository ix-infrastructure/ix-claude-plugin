#!/usr/bin/env bash
# Copyright 2026 Ix Infrastructure INC

# ix-report.sh — Show locally captured errors
#
# Usage:
#   bash hooks/ix-report.sh          # show recent captured errors
#   bash hooks/ix-report.sh --list   # alias for above

set +e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/index.sh" 2>/dev/null || {
  echo "[ix-report] Error: could not load hooks/lib/index.sh" >&2
  exit 1
}

echo "[ix-report] Store: ${IX_ERROR_STORE}"
if [ -f "${IX_ERROR_STORE}/errors.jsonl" ]; then
  echo ""
  echo "Recent errors (last 10):"
  tail -10 "${IX_ERROR_STORE}/errors.jsonl" \
    | jq -r '"  [\(.ts)] \(.type)/\(.component): \(.message)"' 2>/dev/null \
    || tail -10 "${IX_ERROR_STORE}/errors.jsonl"
else
  echo "  No errors recorded."
fi
