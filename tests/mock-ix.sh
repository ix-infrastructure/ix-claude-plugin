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
#   IX_MOCK_EXPECT_INVENTORY_PATH — expected `--path` arg for `ix inventory`
#   IX_MOCK_BRIEFING_FILE  — path to fixture for `ix briefing` (default: briefing.json)
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
    if [ -n "${IX_MOCK_EXPECT_INVENTORY_PATH:-}" ]; then
      _inventory_path=""
      shift
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --path)
            _inventory_path="${2:-}"
            shift 2
            ;;
          *)
            shift
            ;;
        esac
      done
      if [ "${_inventory_path}" != "${IX_MOCK_EXPECT_INVENTORY_PATH}" ]; then
        echo "mock-ix: expected inventory path '${IX_MOCK_EXPECT_INVENTORY_PATH}', got '${_inventory_path}'" >&2
        exit 1
      fi
    fi
    cat "${IX_MOCK_INVENTORY_FILE:-${FX}/inventory_results.json}"
    ;;
  map)
    exit 0
    ;;
  briefing)
    if [ "${2:-}" = "--help" ]; then
      exit 0
    fi
    cat "${IX_MOCK_BRIEFING_FILE:-${FX}/briefing.json}"
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
