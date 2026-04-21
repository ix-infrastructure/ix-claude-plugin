#!/usr/bin/env bash
# hooks/lib/index.sh — Barrel entry point for all ix hook shared libraries
#
# Source this file from any hook instead of loading ix-errors.sh and ix-lib.sh
# individually. Creates a single import hub so the ix graph can see all hooks
# as a connected component rather than isolated single-file regions.
#
# Usage (from any hook in hooks/):
#   _HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "${_HOOK_DIR}/lib/index.sh"
#
# Exports (via ix-errors.sh):
#   IX_ERROR_MODE, IX_ERROR_STORE, ix_capture_async
#
# Exports (via ix-lib.sh):
#   IX_HEALTH_CACHE, IX_PRO_CACHE
#   ix_health_check, ix_check_pro, ix_now_ms
#   parse_json, ix_run_text_locate, ix_summarize_text, ix_summarize_locate
#
# Exports (via ix-ledger.sh):
#   IX_LEDGER_FILE
#   ix_ledger_append, ix_ledger_last_turn
#
# Env defaults (set here, override via shell env):
#   IX_ANNOTATE_MODE, IX_ANNOTATE_CHANNEL, IX_INGEST_INJECT
#   IX_MAP_DEBOUNCE_SECONDS, IX_MAP_LOCK_PATH
#   IX_HOOK_OUTPUT_STYLE, IX_SKIP_SECRET_PATTERNS, IX_BLOCK_ON_HIGH_CONFIDENCE

_IX_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_IX_LIB_DIR}/../ix-errors.sh" 2>/dev/null || true
source "${_IX_LIB_DIR}/../ix-lib.sh"
source "${_IX_LIB_DIR}/../ix-ledger.sh" 2>/dev/null || true

# ── Plugin env defaults (override via shell env) ──────────────────────────────
IX_ANNOTATE_MODE="${IX_ANNOTATE_MODE:-brief}"                   # off | brief | debug | verbose
IX_ANNOTATE_CHANNEL="${IX_ANNOTATE_CHANNEL:-both}"             # systemMessage | modelSuffix | both
IX_INGEST_INJECT="${IX_INGEST_INJECT:-off}"                    # off | on | debug-only
IX_MAP_DEBOUNCE_SECONDS="${IX_MAP_DEBOUNCE_SECONDS:-300}"
IX_MAP_LOCK_PATH="${IX_MAP_LOCK_PATH:-${TMPDIR:-/tmp}/ix-map.lock}"
IX_HOOK_OUTPUT_STYLE="${IX_HOOK_OUTPUT_STYLE:-legacy}"         # legacy | structured (Phase C)
IX_SKIP_SECRET_PATTERNS="${IX_SKIP_SECRET_PATTERNS:-1}"        # Phase C
IX_BLOCK_ON_HIGH_CONFIDENCE="${IX_BLOCK_ON_HIGH_CONFIDENCE:-1}"  # Phase E
