#!/usr/bin/env bash
# ix-report.sh — Retry unsent error reports
#
# Processes errors stored in ~/.local/share/ix/plugin/errors/unsent/ and
# attempts to create GitHub issues for them. Safe to run repeatedly.
#
# Usage:
#   bash hooks/ix-report.sh          # retry unsent errors
#   bash hooks/ix-report.sh --list   # show recent captured errors

set +e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/ix-errors.sh" 2>/dev/null || {
  echo "[ix-report] Error: could not load ix-errors.sh" >&2
  exit 1
}

if [ "${1:-}" = "--list" ]; then
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
  echo ""
  unsent_count=$(ls "${IX_ERROR_STORE}/unsent/"*.json 2>/dev/null | wc -l || echo 0)
  echo "Unsent: ${unsent_count}"
  exit 0
fi

UNSENT_DIR="${IX_ERROR_STORE}/unsent"
[ -d "$UNSENT_DIR" ] || { echo "[ix-report] No unsent errors."; exit 0; }

command -v gh >/dev/null 2>&1 || {
  echo "[ix-report] gh not found — cannot report to GitHub" >&2
  exit 1
}

PROCESSED=0
FAILED=0

for f in "$UNSENT_DIR"/*.json; do
  [ -f "$f" ] || continue

  fp=$(jq -r '.fp // empty' "$f" 2>/dev/null)
  title=$(jq -r '.title // empty' "$f" 2>/dev/null)
  body=$(jq -r '.body // empty' "$f" 2>/dev/null)
  labels=$(jq -r '.labels // "auto-reported"' "$f" 2>/dev/null)

  [ -z "$fp" ] && { rm -f "$f"; continue; }
  [ -z "$title" ] && { FAILED=$(( FAILED + 1 )); continue; }

  url=$(gh issue create \
    --repo "$IX_ERROR_REPO" \
    --title "$title" \
    --body "$body" \
    --label "$labels" \
    2>/dev/null) || { FAILED=$(( FAILED + 1 )); continue; }

  issue_num=$(printf '%s' "$url" | grep -oE '[0-9]+$' || echo "")
  _ixe_rate_update "$fp" "$issue_num"
  rm -f "$f"
  PROCESSED=$(( PROCESSED + 1 ))
done

echo "[ix-report] Processed: ${PROCESSED} | Failed: ${FAILED}"
