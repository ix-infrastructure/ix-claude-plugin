#!/usr/bin/env bash
# tests/mock-ix.sh — Mock ix binary for hook testing.
#
# Intercepts ix CLI calls and returns fixture JSON based on the subcommand.
# Default fixtures live in tests/fixtures/ix_outputs/; override per-subcommand
# via env vars so the test harness can set different fixtures per test case.
#
# Env overrides:
#   IX_MOCK_TEXT_FILE      — path to fixture for `ix text`     (default: text_results.json)
#   IX_MOCK_LOCATE_FILE    — path to fixture for `ix locate`   (default: locate_resolved.json)
#   IX_MOCK_OVERVIEW_FILE  — path to fixture for `ix overview` (default: overview_normal.json)
#   IX_MOCK_IMPACT_FILE    — path to fixture for `ix impact`   (default: impact_high.json)
#   IX_MOCK_INVENTORY_FILE — path to fixture for `ix inventory`(default: inventory_results.json)
#   IX_MOCK_FAIL=1         — exit 1 for all data-returning commands (simulates ix failure)

SUBCOMMAND="${1:-}"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FX="${SELF_DIR}/fixtures/ix_outputs"

# Simulated failure mode
if [ "${IX_MOCK_FAIL:-0}" = "1" ] && [ "$SUBCOMMAND" != "map" ] && [ "$SUBCOMMAND" != "status" ]; then
  echo "mock-ix: simulated failure for subcommand: $SUBCOMMAND" >&2
  exit 1
fi

case "$SUBCOMMAND" in
  text)
    cat "${IX_MOCK_TEXT_FILE:-${FX}/text_results.json}"
    ;;
  locate)
    cat "${IX_MOCK_LOCATE_FILE:-${FX}/locate_resolved.json}"
    ;;
  overview)
    cat "${IX_MOCK_OVERVIEW_FILE:-${FX}/overview_normal.json}"
    ;;
  impact)
    cat "${IX_MOCK_IMPACT_FILE:-${FX}/impact_high.json}"
    ;;
  inventory)
    cat "${IX_MOCK_INVENTORY_FILE:-${FX}/inventory_results.json}"
    ;;
  map)
    exit 0
    ;;
  briefing)
    # Called by ix_check_pro as `ix briefing --help`; return success to signal Pro available
    exit 0
    ;;
  status)
    # Called by ix_capture_async (fire-and-forget); silently succeed
    exit 0
    ;;
  *)
    echo "mock-ix: unknown subcommand: ${SUBCOMMAND}" >&2
    exit 1
    ;;
esac
