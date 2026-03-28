#!/usr/bin/env bash
# test-local.sh — Sync dev repo to plugin cache and verify everything looks right
# Run this from anywhere: bash ~/ix/ix-claude-plugin/test-local.sh

set -euo pipefail

REPO="$HOME/ix/ix-claude-plugin"
CACHE="$HOME/.claude/plugins/cache/ix-memory/ix-memory/1.0.0"

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

[ -d "$REPO" ]   && ok "dev repo found: $REPO"   || { fail "dev repo not found: $REPO"; exit 1; }
[ -d "$CACHE" ]  && ok "plugin cache found"       || { fail "plugin cache not found: $CACHE"; exit 1; }
command -v jq   >/dev/null 2>&1 && ok "jq"        || { fail "jq not in PATH"; exit 1; }
command -v ix   >/dev/null 2>&1 && ok "ix"        || fail "ix not in PATH — hook tests will be skipped"
IX_OK=$( command -v ix >/dev/null 2>&1 && echo 1 || echo 0 )

echo ""

# ── 2. Sync files ─────────────────────────────────────────────────────────────
echo "── Syncing dev repo → plugin cache ──"

# skills
cp -r "$REPO/skills" "$CACHE/"
ok "skills/ synced"

# agents (already there but re-sync to catch any updates)
cp -r "$REPO/agents" "$CACHE/"
ok "agents/ synced"

# plugin.json
cp "$REPO/.claude-plugin/plugin.json" "$CACHE/.claude-plugin/plugin.json"
ok "plugin.json synced"

echo ""

# ── 3. Validate structure ─────────────────────────────────────────────────────
echo "── Validating structure ──"

# plugin.json is valid JSON and has agents + skills fields
jq -e '.agents and .skills' "$CACHE/.claude-plugin/plugin.json" >/dev/null \
  && ok "plugin.json has agents + skills fields" \
  || fail "plugin.json missing agents or skills fields"

# Agent file
AGENT="$CACHE/agents/ix-explorer.md"
[ -f "$AGENT" ] && ok "agent: ix-explorer.md" || fail "missing agent: $AGENT"

# Skill files
for skill in ix-search ix-explain ix-impact ix-trace ix-smells; do
  SKILL_FILE="$CACHE/skills/$skill/SKILL.md"
  [ -f "$SKILL_FILE" ] \
    && ok "skill: /$skill" \
    || fail "missing skill file: $SKILL_FILE"
done

# All hook scripts are executable
for hook in ix-briefing.sh ix-intercept.sh ix-read.sh ix-bash.sh ix-ingest.sh ix-map.sh; do
  HOOK_PATH="$HOME/.local/share/ix/plugin/hooks/$hook"
  [ -x "$HOOK_PATH" ] \
    && ok "hook executable: $hook" \
    || fail "hook not executable or missing: $HOOK_PATH"
done

echo ""

# ── 4. Validate hook output ───────────────────────────────────────────────────
echo "── Testing hooks (dry run) ──"

if [ "$IX_OK" = "1" ]; then
  ix status >/dev/null 2>&1 \
    && ok "ix status: healthy" \
    || fail "ix status: unhealthy — hooks will bail silently"

  # Test ix-read hook
  READ_OUT=$(echo '{"tool_name":"Read","tool_input":{"file_path":"'"$REPO/hooks/ix-read.sh"'"}}' \
    | bash "$HOME/.local/share/ix/plugin/hooks/ix-read.sh" 2>/dev/null || echo "")
  if echo "$READ_OUT" | jq -e '.additionalContext' >/dev/null 2>&1; then
    ok "ix-read.sh → additionalContext injected"
  else
    info "ix-read.sh → no output (ix may have no data for this file yet)"
  fi

  # Test ix-intercept hook (Grep)
  GREP_OUT=$(echo '{"tool_name":"Grep","tool_input":{"pattern":"ix inventory"}}' \
    | bash "$HOME/.local/share/ix/plugin/hooks/ix-intercept.sh" 2>/dev/null || echo "")
  if echo "$GREP_OUT" | jq -e '.additionalContext' >/dev/null 2>&1; then
    ok "ix-intercept.sh (Grep) → additionalContext injected"
  else
    info "ix-intercept.sh → no output (ix may have no data yet)"
  fi

  # Test ix-bash hook
  BASH_OUT=$(echo '{"tool_name":"Bash","tool_input":{"command":"rg \"def \" --type py"}}' \
    | bash "$HOME/.local/share/ix/plugin/hooks/ix-bash.sh" 2>/dev/null || echo "")
  if echo "$BASH_OUT" | jq -e '.additionalContext' >/dev/null 2>&1; then
    ok "ix-bash.sh → additionalContext injected"
  else
    info "ix-bash.sh → no output (ix may have no data yet)"
  fi

else
  info "ix not available — skipping hook output tests"
fi

echo ""

# ── 5. Summary ────────────────────────────────────────────────────────────────
echo "── Summary ──"
echo ""
if [ "$FAILURES" -eq 0 ]; then
  echo "  All checks passed."
else
  echo "  $FAILURES check(s) failed — see [FAIL] lines above."
fi

echo ""
echo "── Next: manual tests in Claude Code ──"
echo ""
echo "  Restart Claude Code, then try:"
echo ""
echo "    /ix-search <any symbol in your codebase>"
echo "    /ix-explain <a function name>"
echo "    /ix-impact <a file path>"
echo "    /ix-trace <a function name>"
echo "    /ix-smells"
echo ""
echo "  For the agent, ask Claude:"
echo "    'Explore how [something] works in this codebase'"
echo "  You should see it use ix commands before reaching for Grep/Read."
echo ""
echo "  To confirm hooks are still firing after a Read:"
echo "    date -d @\$(cat /tmp/ix-healthy)"
echo ""

exit $FAILURES
