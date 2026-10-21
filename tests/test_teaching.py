# Copyright 2026 Ix Infrastructure Inc.

"""Regression checks for the teaching Claude receives at discovery/session start."""

import json
from pathlib import Path
import re
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]


class TeachingTests(unittest.TestCase):
    def test_descriptions_have_use_when_trigger(self):
        for path in (ROOT / "skills").glob("*/SKILL.md"):
            with self.subTest(skill=path.parent.name):
                description = re.search(r"(?m)^description: (.*)$", path.read_text())
                self.assertIsNotNone(description)
                self.assertTrue(description[1].startswith("Use when "), description[1])

    def test_no_dangling_help_skill(self):
        for directory in (ROOT / "skills", ROOT / "agents"):
            for path in directory.rglob("*.md"):
                self.assertFalse(re.search(r"(?:/|\[)ix-help\b", path.read_text()), str(path))
        self.assertNotIn("ix-help/", (ROOT / "CLAUDE.md").read_text())

    def test_session_start_including_compact_teaches_all_triggers(self):
        registry = json.loads((ROOT / "hooks/hooks.json").read_text())
        entries = registry["hooks"].get("SessionStart", [])
        self.assertTrue(entries, "SessionStart teaching is not registered")
        for source in ("startup", "resume", "clear", "compact"):
            with self.subTest(source=source):
                contexts = []
                for entry in entries:
                    if not re.search(entry.get("matcher", ".*"), source):
                        continue
                    for hook in entry["hooks"]:
                        script = hook["command"].replace("${CLAUDE_PLUGIN_ROOT}", str(ROOT))
                        result = subprocess.run(
                            ["bash", script], input=json.dumps({"source": source}),
                            text=True, capture_output=True, check=True,
                            timeout=hook["timeout"],
                        )
                        output = json.loads(result.stdout)["hookSpecificOutput"]
                        self.assertEqual(output["hookEventName"], "SessionStart")
                        contexts.append(output["additionalContext"])
                guide = "\n".join(contexts)
                self.assertGreater(len(guide.encode()), 0)
                self.assertLess(len(guide.encode()), 600)
                self.assertLess(len((ROOT / "hooks/ix-cheatsheet.txt").read_bytes()), 600)
                for command in ("ix locate <name>", "ix search <term>",
                                "ix callers <sym>", "ix impact <sym>",
                                "ix explain", "ix overview", "ix around <file>"):
                    self.assertIn(command, guide)
                self.assertIn("before grep", guide)
                self.assertIn("if available", guide)

    def test_recovery_uses_candidates_before_native_search(self):
        shared = (ROOT / "skills/shared.md").read_text()
        recovery = shared.split("**When ix returns an error:**", 1)[1].split("---", 1)[0]
        for term in ("exit 1", "ambiguous_target", "--pick N", "--path <file>",
                     "--kind <kind>", "candidates", "unresolved_target",
                     "ix search", "partial", "git grep", "just wrote"):
            self.assertIn(term, recovery)


if __name__ == "__main__":
    unittest.main()
