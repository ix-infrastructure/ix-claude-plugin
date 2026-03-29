#!/usr/bin/env bash
# test-local.sh — Sync dev repo to plugin cache and verify everything looks right
# Run from anywhere: bash ~/ix/ix-claude-plugin/test-local.sh

set -euo pipefail

REPO="$HOME/ix/ix-claude-plugin"

ok()   { echo "  [ok] $*"; }
fail() { echo "  [FAIL] $*"; FAILURES=$((FAILURES+1)); }
info() { echo "  ---  $*"; }

FAILURES=0

echo ""
echo "═══════════════════════════════════════════"
echo "  ix-claude-plugin — local test sync"
echo "═══════════════════════════════════════════"
echo ""

# ── 1. Prereqs ────────────────────────────────────────────────────────────────
echo "── Checking prereqs ──"

[ -d "$REPO" ] && ok "dev repo found: $REPO" || { fail "dev repo not found: $REPO"; exit 1; }
command -v jq  >/dev/null 2>&1 && ok "jq"   || { fail "jq not in PATH"; exit 1; }
command -v ix  >/dev/null 2>&1 && ok "ix"   || fail "ix not in PATH — hook tests will be skipped"
IX_OK=$(command -v ix >/dev/null 2>&1 && echo 1 || echo 0)

echo ""

# ── 2. Locate the active plugin cache ─────────────────────────────────────────
echo "── Locating plugin cache ──"

PLUGIN_VERSION=$(jq -r '.plugins[0].version' "$REPO/.claude-plugin/marketplace.json")
CACHE_BASE="$HOME/.claude/plugins/cache/ix-claude-plugin/ix-memory"

if [ -d "$CACHE_BASE/$PLUGIN_VERSION" ]; then
  CACHE="$CACHE_BASE/$PLUGIN_VERSION"
  ok "Cache found at v$PLUGIN_VERSION (matches source)"
else
  INSTALLED=$(ls "$CACHE_BASE" 2>/dev/null | grep -v '^\.' | sort -V | tail -1)
  if [ -n "$INSTALLED" ]; then
    CACHE="$CACHE_BASE/$INSTALLED"
    info "Source is v$PLUGIN_VERSION but cache has v$INSTALLED — syncing to installed version"
    info "Run '/plugin update ix-memory' after pushing to get v$PLUGIN_VERSION"
  else
    fail "No plugin cache found at $CACHE_BASE — is ix-memory installed?"
    exit 1
  fi
fi

ok "Syncing to: $CACHE"
echo ""

# ── 3. Sync files ─────────────────────────────────────────────────────────────
echo "── Syncing dev repo → plugin cache ──"

rsync -a --delete "$REPO/skills/"  "$CACHE/skills/"  && ok "skills/ synced"
rsync -a --delete "$REPO/agents/"  "$CACHE/agents/"  && ok "agents/ synced"
rsync -a          "$REPO/hooks/"   "$CACHE/hooks/"   && ok "hooks/ synced"
cp "$REPO/.claude-plugin/plugin.json"      "$CACHE/.claude-plugin/plugin.json"      && ok "plugin.json synced"
cp "$REPO/.claude-plugin/marketplace.json" "$CACHE/.claude-plugin/marketplace.json" && ok "marketplace.json synced"
[ -f "$REPO/CLAUDE.md" ] && cp "$REPO/CLAUDE.md" "$CACHE/CLAUDE.md" && ok "CLAUDE.md synced"
chmod +x "$CACHE/hooks/"*.sh 2>/dev/null && ok "hook scripts marked executable"

echo ""

# ── 4. Validate structure ─────────────────────────────────────────────────────
echo "── Validating structure ──"

jq -e . "$CACHE/.claude-plugin/plugin.json" >/dev/null 2>&1 \
  && ok "plugin.json is valid JSON" \
  || fail "plugin.json is invalid JSON"

CACHE_VER=$(jq -r '.version' "$CACHE/.claude-plugin/plugin.json")
[ "$CACHE_VER" = "$PLUGIN_VERSION" ] \
  && ok "plugin.json version: $CACHE_VER" \
  || fail "version mismatch: source=$PLUGIN_VERSION cache=$CACHE_VER"

echo ""
echo "  Skills (expected):"
for skill in ix-understand ix-investigate ix-impact ix-plan ix-debug ix-architecture ix-docs; do
  [ -f "$CACHE/skills/$skill/SKILL.md" ] && ok "$skill" || fail "missing: skills/$skill/SKILL.md"
done

echo ""
echo "  Skills (should be removed):"
for skill in ix-search ix-explain ix-trace ix-smells ix-depends ix-subsystems ix-diff ix-read ix-before-edit; do
  [ ! -f "$CACHE/skills/$skill/SKILL.md" ] && ok "removed: $skill" || fail "stale skill still present: skills/$skill/SKILL.md"
done

echo ""
echo "  Agents:"
for agent in ix-explorer ix-system-explorer ix-bug-investigator ix-safe-refactor-planner ix-architecture-auditor; do
  [ -f "$CACHE/agents/$agent.md" ] && ok "$agent" || fail "missing: agents/$agent.md"
done

echo ""
echo "  Hooks:"
for hook in ix-briefing.sh ix-intercept.sh ix-read.sh ix-bash.sh ix-pre-edit.sh ix-ingest.sh ix-map.sh ix-report.sh; do
  HOOK_FILE="$CACHE/hooks/$hook"
  if   [ -f "$HOOK_FILE" ] && [ -x "$HOOK_FILE" ]; then ok "$hook"
  elif [ -f "$HOOK_FILE" ]; then fail "$hook not executable"
  else fail "missing: hooks/$hook"
  fi
done

[ -f "$CACHE/hooks/ix-errors.sh" ] \
  && ok "ix-errors.sh (library)" \
  || fail "missing: hooks/ix-errors.sh"

source "$CACHE/hooks/ix-errors.sh" 2>/dev/null \
  && ok "ix-errors.sh: sourceable" \
  || fail "ix-errors.sh: failed to source"

jq -e . "$CACHE/hooks/hooks.json" >/dev/null 2>&1 \
  && ok "hooks.json is valid JSON" \
  || fail "hooks.json is invalid JSON"

[ ! -d "$CACHE/skills/ix-understand/references" ] \
  && ok "ix-understand/references/ removed" \
  || fail "orphaned ix-understand/references/ still present"

echo ""

# ── 5. Hook output tests ──────────────────────────────────────────────────────
echo "── Testing hooks (dry run) ──"

if [ "$IX_OK" = "1" ]; then
  ix status >/dev/null 2>&1 \
    && ok "ix status: healthy" \
    || fail "ix status: unhealthy — hooks will bail silently"

  READ_OUT=$(echo "{\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"$REPO/hooks/ix-read.sh\"}}" \
    | bash "$CACHE/hooks/ix-read.sh" 2>/dev/null || echo "")
  echo "$READ_OUT" | jq -e '.additionalContext' >/dev/null 2>&1 \
    && ok "ix-read.sh → additionalContext injected" \
    || info "ix-read.sh → no output (run 'ix map' first)"

  GREP_OUT=$(echo '{"tool_name":"Grep","tool_input":{"pattern":"ix inventory"}}' \
    | bash "$CACHE/hooks/ix-intercept.sh" 2>/dev/null || echo "")
  echo "$GREP_OUT" | jq -e '.additionalContext' >/dev/null 2>&1 \
    && ok "ix-intercept.sh → additionalContext injected" \
    || info "ix-intercept.sh → no output"

  BASH_OUT=$(echo '{"tool_name":"Bash","tool_input":{"command":"rg \"def \" --type py"}}' \
    | bash "$CACHE/hooks/ix-bash.sh" 2>/dev/null || echo "")
  echo "$BASH_OUT" | jq -e '.additionalContext' >/dev/null 2>&1 \
    && ok "ix-bash.sh → additionalContext injected" \
    || info "ix-bash.sh → no output"

  EDIT_OUT=$(echo "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$REPO/skills/ix-understand/SKILL.md\",\"old_string\":\"x\",\"new_string\":\"y\"}}" \
    | bash "$CACHE/hooks/ix-pre-edit.sh" 2>/dev/null || echo "")
  echo "$EDIT_OUT" | jq -e '.additionalContext' >/dev/null 2>&1 \
    && ok "ix-pre-edit.sh → additionalContext injected" \
    || info "ix-pre-edit.sh → no output"
else
  info "ix not available — skipping hook output tests"
fi

echo ""

# ── 6. Summary ────────────────────────────────────────────────────────────────
echo "── Summary ──"
echo ""
if [ "$FAILURES" -eq 0 ]; then
  echo "  ✓ All checks passed."
  echo ""
  echo "  Restart Claude Code, then try:"
  echo ""
  echo "    /ix-understand                  ← full repo mental model"
  echo "    /ix-investigate <symbol>        ← deep dive into a component"
  echo "    /ix-impact <file or symbol>     ← blast radius before editing"
  echo "    /ix-debug <symptom>             ← root cause analysis"
  echo "    /ix-architecture                ← design health audit"
  echo "    /ix-docs <target>               ← narrative-first system documentation"
  echo "    /ix-docs <target> --full --style hybrid"
  echo "                                   ← deeper docs with selective reference"
  echo ""
  echo "  To confirm hooks are firing: stat /tmp/ix-healthy"
else
  echo "  ✗ $FAILURES check(s) failed — see [FAIL] lines above."
fi

echo ""
exit $FAILURES
