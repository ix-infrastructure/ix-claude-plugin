#!/usr/bin/env bash
# install-local.sh — Register the local ix-claude-plugin as the active Claude plugin.
#
# Usage: ./install-local.sh
#
# Run this after uninstalling the ix-memory plugin in Claude, or whenever you
# want Claude to load the plugin from this working directory instead of the
# GitHub-pulled cache.
#
# Safe to re-run at any time. Does not require Claude to be closed.

set -euo pipefail

PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLED_PLUGINS="$HOME/.claude/plugins/installed_plugins.json"
SETTINGS="$HOME/.claude/settings.json"
PLUGIN_KEY="ix-memory@ix-claude-plugin"

# Get current git SHA for metadata (non-fatal if not in a git repo)
GIT_SHA=$(git -C "$PLUGIN_DIR" rev-parse HEAD 2>/dev/null || echo "local")
NOW=$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")

echo "Plugin directory : $PLUGIN_DIR"
echo "Git SHA          : $GIT_SHA"
echo "Target file      : $INSTALLED_PLUGINS"
echo "Settings file    : $SETTINGS"

# Build the new plugin entry using Python (available on all supported platforms)
python3 - "$INSTALLED_PLUGINS" "$PLUGIN_KEY" "$PLUGIN_DIR" "$GIT_SHA" "$NOW" <<'PYEOF'
import json, sys, os

installed_plugins_path, plugin_key, plugin_dir, git_sha, now = sys.argv[1:]

# Read existing file (or start fresh if it doesn't exist / was cleared by uninstall)
if os.path.exists(installed_plugins_path):
    with open(installed_plugins_path) as f:
        data = json.load(f)
else:
    data = {"version": 2, "plugins": {}}

# Ensure top-level structure is correct
data.setdefault("version", 2)
data.setdefault("plugins", {})

# Build entry pointing at the local working directory
entry = {
    "scope": "user",
    "installPath": plugin_dir,
    "version": "local",
    "installedAt": now,
    "lastUpdated": now,
    "gitCommitSha": git_sha,
}

data["plugins"][plugin_key] = [entry]

with open(installed_plugins_path, "w") as f:
    json.dump(data, f, indent=4)

print(f"Registered '{plugin_key}' -> {plugin_dir}")
PYEOF

# Enable the plugin in settings.json so /skills shows it
python3 - "$SETTINGS" "$PLUGIN_KEY" <<'PYEOF'
import json, sys, os

settings_path, plugin_key = sys.argv[1:]

if os.path.exists(settings_path):
    with open(settings_path) as f:
        data = json.load(f)
else:
    data = {}

data.setdefault("enabledPlugins", {})
if data["enabledPlugins"].get(plugin_key) is not True:
    data["enabledPlugins"][plugin_key] = True
    with open(settings_path, "w") as f:
        json.dump(data, f, indent=2)
    print(f"Enabled '{plugin_key}' in settings.json")
else:
    print(f"'{plugin_key}' already enabled in settings.json")
PYEOF

echo ""
echo "Done. Restart Claude Code (or start a new session) for changes to take effect."
