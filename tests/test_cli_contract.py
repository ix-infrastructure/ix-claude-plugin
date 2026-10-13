# Copyright 2026 Ix Infrastructure Inc.

"""Prove the validator catches drift, including examples not exercised by hooks."""

from pathlib import Path
import tempfile
import unittest

from check_cli_contract import (
    DefinitionUnavailable, help_definitions, invocations, plugin_paths, scan, validate,
)


class CliContractTests(unittest.TestCase):
    def definitions(self, command):
        definitions = {
            ("locate",): ({"--path", "--pick", "--kind", "--format"}, set()),
            ("text",): ({"--path", "--format", "--limit", "--language"}, set()),
            ("plan",): ({"--help"}, {"list", "create"}),
            ("plan", "list"): ({"--format"}, set()),
        }
        if command not in definitions:
            raise ValueError(f"unknown command: {' '.join(command)}")
        return definitions[command]

    def test_unknown_command_is_rejected(self):
        mention = next(invocations("ix made-up-command target", "example.md", 1))
        with self.assertRaisesRegex(ValueError, "unknown command"):
            validate(mention, self.definitions)

    def test_unknown_long_short_and_equals_flags_are_rejected(self):
        for flag in ("--made-up", "--made-up=value", "-Z"):
            with self.subTest(flag=flag):
                mention = next(invocations(f"ix locate target {flag}", "example.md", 1))
                with self.assertRaisesRegex(ValueError, "unknown flags"):
                    validate(mention, self.definitions)

    def test_subcommand_flags_use_child_definitions(self):
        mention = next(invocations("ix plan list --format text", "example.md", 1))
        validate(mention, self.definitions)
        mention = next(invocations("ix plan missing --format text", "example.md", 1))
        with self.assertRaisesRegex(ValueError, "unknown subcommand"):
            validate(mention, self.definitions)

    def test_oss_pro_stub_is_explicitly_unverified(self):
        mention = next(invocations("ix plan list --format text", "example.md", 1))
        with self.assertRaises(DefinitionUnavailable):
            validate(mention, lambda command: ({"-h", "--help"}, set()))

    def test_missing_standard_flag_is_still_a_failure(self):
        mention = next(invocations("ix locate target --made-up", "example.md", 1))
        with self.assertRaisesRegex(ValueError, "unknown flags") as raised:
            validate(mention, lambda command: ({"-h", "--help"}, set()))
        self.assertNotIsInstance(raised.exception, DefinitionUnavailable)

    def test_help_examples_cannot_legalize_unknown_flags(self):
        options, children = help_definitions(
            "Usage: ix locate [options] <target>\n\nOptions:\n"
            "  --path <path>  Filter path\n  -h, --help  Show help\n"
            "\nExamples:\n  ix locate target --made-up\n"
        )
        self.assertEqual(options, {"--path", "-h", "--help"})
        self.assertFalse(children)

    def test_markdown_inline_fenced_and_separate_option_spans(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "example.md"
            path.write_text(
                "`ix locate target --pick 2`\n"
                "```bash\nix text target --language python\n```\n"
                "| `ix locate target` | Options: `--made-up` |\n"
            )
            mentions = list(scan(path))
        self.assertEqual(len(mentions), 3)
        for mention in mentions[:2]:
            validate(mention, self.definitions)
        with self.assertRaisesRegex(ValueError, "unknown flags"):
            validate(mentions[2], self.definitions)

    def test_shell_arrays_continuations_and_quoted_log_data(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "example.sh"
            path.write_text(
                'ARGS=("--format" "json")\n'
                'ARGS+=("--made-up" "value")\n'
                'ix_capture_async "ix" "ix-locate" "ix locate failed"\n'
                'ix text "$target" \\\n  "${ARGS[@]}"\n'
            )
            mentions = list(scan(path))
        self.assertEqual(len(mentions), 1)
        self.assertEqual(mentions[0].flags, {"--format", "--made-up"})
        with self.assertRaisesRegex(ValueError, "unknown flags"):
            validate(mentions[0], self.definitions)

    def test_unknown_shell_array_is_not_silently_skipped(self):
        with self.assertRaisesRegex(ValueError, "untracked ix argument array"):
            list(invocations('ix text "${UNKNOWN[@]}"', "hook.sh", 1))

    def test_dynamic_commands_are_not_silently_skipped(self):
        with self.assertRaisesRegex(ValueError, "dynamic ix command"):
            list(invocations('ix "$COMMAND" target', "hook.sh", 1))
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "hook.sh"
            path.write_text('ix "$COMMAND" target\n')
            with self.assertRaisesRegex(ValueError, "dynamic ix command"):
                list(scan(path))

    def test_json_hook_commands_are_checked(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "hooks.json"
            path.write_text('{"hooks":{"SessionStart":[{"hooks":[{"command":"ix locate target --made-up"}]}]}}')
            mentions = list(scan(path))
        self.assertEqual(len(mentions), 1)
        with self.assertRaisesRegex(ValueError, "unknown flags"):
            validate(mentions[0], self.definitions)

    def test_command_probe_flags_are_not_ix_flags(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "example.md"
            path.write_text("Check `command -v ix` and `ix locate target`.\n")
            mentions = list(scan(path))
        self.assertEqual(len(mentions), 1)
        validate(mentions[0], self.definitions)

    def test_warning_about_unsupported_flag_is_not_an_invocation(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "example.md"
            path.write_text("Note: `ix locate` does not support `--made-up`.\n"
                            "Do not use `ix locate target --made-up`.\n")
            mentions = list(scan(path))
        self.assertEqual(len(mentions), 2)
        validate(mentions[0], self.definitions)
        with self.assertRaisesRegex(ValueError, "unknown flags"):
            validate(mentions[1], self.definitions)

    def test_every_shipped_path_can_be_scanned(self):
        paths = list(plugin_paths())
        self.assertIn("ix-cheatsheet.txt", [path.name for path in paths])
        for path in paths:
            with self.subTest(path=path):
                list(scan(path))


if __name__ == "__main__":
    unittest.main()
