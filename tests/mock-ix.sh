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
#   IX_MOCK_EXPECT_INVENTORY_KIND — expected `--kind` arg for `ix inventory`
#   IX_MOCK_BRIEFING_FILE  — path to fixture for `ix briefing` (default: briefing.json)
#   IX_MOCK_FAIL=1         — exit 1 for all data-returning commands (simulates ix failure)
#   IX_MOCK_LOCATE_EXIT=N     — `ix locate` exits N *after* printing its body
#                            (Ix#539)
#   IX_MOCK_OVERVIEW_EXIT=N   — `ix overview` exits N *after* printing its body
#   IX_MOCK_IMPACT_EXIT=N     — `ix impact` exits N *after* printing its body
#   IX_MOCK_INVENTORY_EXIT=N  — `ix inventory` exits N *after* printing its body
#                            (Ix#547: an unresolved target is a non-zero exit
#                            with a usable payload, not an absent one.
#                            Simulated separately from IX_MOCK_FAIL, which
#                            suppresses the output too.)
#                            Written as `if`, never `[ -n "$V" ] && exit "$V"`:
#                            that form evaluates to status 1 when V is unset and
#                            becomes the mock's own exit status, so every call
#                            would fail. It is invisible while the code under
#                            test tolerates a non-zero exit -- which is exactly
#                            what these variables exist to test.

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
    # Ix#539 makes an unresolved target exit non-zero while still printing its
    # body. Simulated separately from IX_MOCK_FAIL, which suppresses output too:
    # the whole point is a failing exit code *with* usable output.
    #
    # `if`, never `[ -n "$V" ] && exit "$V"`. That form evaluates to status 1
    # when V is unset, and as the last command in this branch it becomes the
    # mock's own exit status -- so `ix locate` would exit 1 on every call, in
    # every test. It is invisible precisely because the fix in this PR makes the
    # hook tolerate a non-zero exit with a body, so the suite stays green while
    # no longer testing what it claims to.
    if [ -n "${IX_MOCK_LOCATE_EXIT:-}" ]; then exit "${IX_MOCK_LOCATE_EXIT}"; fi
    ;;
  overview)
    cat "${IX_MOCK_OVERVIEW_FILE:-${FX}/overview_normal.json}"
    if [ -n "${IX_MOCK_OVERVIEW_EXIT:-}" ]; then exit "${IX_MOCK_OVERVIEW_EXIT}"; fi
    ;;
  impact)
    cat "${IX_MOCK_IMPACT_FILE:-${FX}/impact_high.json}"
    if [ -n "${IX_MOCK_IMPACT_EXIT:-}" ]; then exit "${IX_MOCK_IMPACT_EXIT}"; fi
    ;;
  inventory)
    if [ -n "${IX_MOCK_EXPECT_INVENTORY_PATH:-}" ] || [ -n "${IX_MOCK_EXPECT_INVENTORY_KIND:-}" ]; then
      _inventory_path=""
      _inventory_kind=""
      shift
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --path)
            _inventory_path="${2:-}"
            shift 2
            ;;
          --kind)
            _inventory_kind="${2:-}"
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
      if [ -n "${IX_MOCK_EXPECT_INVENTORY_KIND:-}" ] && [ "${_inventory_kind}" != "${IX_MOCK_EXPECT_INVENTORY_KIND}" ]; then
        echo "mock-ix: expected inventory kind '${IX_MOCK_EXPECT_INVENTORY_KIND}', got '${_inventory_kind}'" >&2
        exit 1
      fi
    fi
    cat "${IX_MOCK_INVENTORY_FILE:-${FX}/inventory_results.json}"
    if [ -n "${IX_MOCK_INVENTORY_EXIT:-}" ]; then exit "${IX_MOCK_INVENTORY_EXIT}"; fi
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
