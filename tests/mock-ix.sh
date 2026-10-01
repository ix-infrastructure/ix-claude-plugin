#!/usr/bin/env bash
# Copyright 2026 Ix Infrastructure Inc.

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
#   IX_MOCK_BRIEFING_SLEEP=N — `ix briefing` sleeps N seconds before answering
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
#   IX_MOCK_MAPPED_ROOTS   — `:`-separated roots for which `ix status --format
#                            json --root R` reports graphCompleted=true (all
#                            others report false, as the real CLI does for a
#                            workspace that was never mapped)
#   IX_MOCK_MAP_LOG        — `ix map` appends "argv=… | IX_AUTO_MAP=… | cwd=…"
#
# Strict where the real CLI is strict, so a hook cannot keep calling something
# that only ever worked against this mock:
#   `ix map <file>`         → exit 1 "Map path is not a directory" (Ix #545)
#   `ix map --unknown`      → exit 1 "unknown option"
#   `ix locate … --limit`   → exit 1 "unknown option '--limit'"
#   `ix smells … --path`    → exit 1 "unknown option '--path'"

SUBCOMMAND="${1:-}"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FX="${SELF_DIR}/fixtures/ix_outputs"

# Simulated failure mode
if [ "${IX_MOCK_FAIL:-0}" = "1" ] && [ "$SUBCOMMAND" != "map" ] && [ "$SUBCOMMAND" != "status" ]; then
  echo "mock-ix: simulated failure for subcommand: $SUBCOMMAND" >&2
  exit 1
fi

# `ix status --format json` — the guard the automatic map consults. Bare
# `ix status` (ix_capture_async) still falls through to the silent branch below.
if [ "$SUBCOMMAND" = "status" ]; then
  _st_json=0; _st_root=""
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --format) [ "${2:-}" = "json" ] && _st_json=1; shift 2 ;;
      --root) _st_root="${2:-}"; shift 2 ;;
      *) shift ;;
    esac
  done
  if [ "$_st_json" -eq 1 ]; then
    _st_done=false
    _st_ifs="$IFS"; IFS=:
    for _st_mapped in ${IX_MOCK_MAPPED_ROOTS:-}; do
      [ -n "$_st_mapped" ] && [ "$_st_mapped" = "$_st_root" ] && _st_done=true
    done
    IFS="$_st_ifs"
    printf '{"backend":"ok","graphCompleted":%s,"mapCompleted":%s,"currentRev":0,"lastIngestAt":null,"staleFiles":0,"sampleChangedFiles":[]}\n' \
      "$_st_done" "$_st_done"
    exit 0
  fi
  exit 0
fi

case "$SUBCOMMAND" in
  text)
    cat "${IX_MOCK_TEXT_FILE:-${FX}/text_results.json}"
    ;;
  locate)
    for _arg in "$@"; do
      if [ "$_arg" = "--limit" ]; then
        echo "error: unknown option '--limit'" >&2
        exit 1
      fi
    done
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
    shift
    _map_path=""
    _map_argv=("map" "$@")
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --format|--level|--min-confidence|--max-items|--sort|--fields) shift 2 ;;
        --all-items|--graph|--list|--full|--verbose|--silent|--pretty|--quiet|-h|--help) shift ;;
        -*) echo "error: unknown option '$1'" >&2; exit 1 ;;
        *) _map_path="$1"; shift ;;
      esac
    done
    if [ -n "$_map_path" ] && [ ! -d "$_map_path" ]; then
      echo "Map path is not a directory: $_map_path" >&2
      exit 1
    fi
    if [ -n "${IX_MOCK_MAP_LOG:-}" ]; then
      printf 'argv=%s | IX_AUTO_MAP=%s | cwd=%s\n' \
        "${_map_argv[*]}" "${IX_AUTO_MAP:-}" "$PWD" >> "$IX_MOCK_MAP_LOG"
    fi
    exit 0
    ;;
  smells)
    for _arg in "$@"; do
      if [ "$_arg" = "--path" ]; then
        echo "error: unknown option '--path'" >&2
        exit 1
      fi
    done
    echo '[]'
    ;;
  briefing)
    if [ "${2:-}" = "--help" ]; then
      exit 0
    fi
    # A briefing that takes longer than the hook's budget: what a slow or
    # half-up backend does, and the case the Pro probe has to survive.
    if [ -n "${IX_MOCK_BRIEFING_SLEEP:-}" ]; then
      sleep "${IX_MOCK_BRIEFING_SLEEP}"
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
