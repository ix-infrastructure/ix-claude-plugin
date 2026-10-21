# Copyright 2026 Ix Infrastructure Inc.

"""Check shipped commands against the installed CLI's own help definitions.

Only --help is executed, never examples or hook commands. Covers hook shell
invocations (including argument arrays), skill/agent code, and current docs.
TASKS.md and CHANGELOG.md are historical records, not current CLI guidance.
"""

from dataclasses import dataclass
import json
from pathlib import Path
import re
import shlex
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
FLAG = re.compile(r"(?<![\w-])--[a-z][\w-]*|(?<![\w-])-[a-zA-Z](?![\w-])")
PRO_ROW = next(line for line in (ROOT / "skills/shared.md").read_text().splitlines()
               if line.startswith("| **Pro only**"))
PRO_COMMANDS = frozenset(re.findall(r"`([a-z][\w-]*)`", PRO_ROW))


class DefinitionUnavailable(ValueError):
    """A registered OSS stub cannot describe the real Pro command contract."""


@dataclass(frozen=True)
class Mention:
    path: str
    line: int
    argv: tuple
    flags: frozenset


def invocations(code, path, line, arrays=None):
    """Lex code, without evaluating shell substitutions or documentation targets."""
    literal_commands = set(re.findall(r"(?<![\w\"'-])ix\s+([a-z][\w-]*|--[\w-]+)", code))
    lexer = shlex.shlex(code, posix=True, punctuation_chars="|;&()")
    lexer.whitespace_split = True
    lexer.commenters = "#"
    try:
        tokens = list(lexer)
    except ValueError as exc:
        raise ValueError(f"{path}:{line}: cannot scan code: {exc}") from exc
    for index, token in enumerate(tokens):
        if token != "ix":
            continue
        args = []
        for arg in tokens[index + 1:]:
            if re.fullmatch(r"[|;&()]+", arg) or arg in ("→", "+"):
                break
            args.append(arg.strip("\"'"))
        if not args:
            continue
        if args[0].startswith("$") and re.search(r"(?<![\w\"'-])ix\s+[\"']?\$", code):
            raise ValueError(f"{path}:{line}: dynamic ix command cannot be validated")
        # Quoted log/function arguments such as "ix" "ix-impact" are data.
        if args[0] not in literal_commands:
            continue
        # Reject dynamic command names; dynamic targets are fine. Every literal
        # command, including an unknown one, is checked by the real CLI.
        if not re.fullmatch(r"[a-z][\w-]*|--[\w-]+", args[0]):
            raise ValueError(f"{path}:{line}: dynamic ix command cannot be validated")
        flags = set()
        for arg in args:
            if arg.startswith("-"):
                flags.update(FLAG.findall(arg.split("=", 1)[0]))
            array = re.fullmatch(r"\$\{(\w+)\[@\]\}", arg)
            if array:
                if array[1] not in (arrays or {}):
                    raise ValueError(f"{path}:{line}: untracked ix argument array {array[1]}")
                flags.update(arrays[array[1]])
        yield Mention(str(path), line, tuple(args), frozenset(flags))


def scan(path):
    text = path.read_text()
    relative = path.relative_to(ROOT) if path.is_relative_to(ROOT) else path
    if path.suffix == ".json":
        def commands(value):
            if isinstance(value, dict):
                for key, child in value.items():
                    if key == "command" and isinstance(child, str):
                        yield child
                    else:
                        yield from commands(child)
            elif isinstance(value, list):
                for child in value:
                    yield from commands(child)

        for command in commands(json.loads(text)):
            yield from invocations(command, relative, 1)
    elif path.suffix == ".sh":
        arrays = {}
        for match in re.finditer(r"\b(\w+)\+?=\(([^\n]*)", text):
            arrays.setdefault(match[1], set()).update(FLAG.findall(match[2]))
        # Shell continuation lines form one command. Logging strings remain
        # single tokens, so prose such as "ix unavailable" is not an invocation.
        start = 1
        pending = ""
        for number, raw in enumerate(text.splitlines(), 1):
            if not pending:
                start = number
            if raw.lstrip().startswith("#"):
                # Code examples in shell comments are still documentation.
                for code in re.findall(r"`([^`]+)`", raw):
                    yield from invocations(code, relative, number, arrays)
                continue
            pending += raw.rstrip("\\") + " "
            if raw.endswith("\\"):
                continue
            # Unrelated shell lines can contain unmatched quotes from multiline
            # strings. Only command-shaped lines need shell lexing.
            if re.search(r"\bix\s+(?:[a-z][\w-]*|--[\w-]+|[\"']?\$)", pending):
                yield from invocations(pending, relative, start, arrays)
            pending = ""
    else:
        fenced = False
        language = ""
        for number, line in enumerate(text.splitlines(), 1):
            if line.lstrip().startswith("```"):
                fenced = not fenced
                language = line.strip()[3:]
                continue
            if fenced:
                if re.match(r"\s*ix\s+[a-z-]", line) or re.search(r"\bCMD ix\s+", line) or (
                    language in ("bash", "sh", "shell") and re.search(r"\bix\s+[a-z-]", line)
                ):
                    yield from invocations(line, relative, number)
                continue
            codes = re.findall(r"`([^`]+)`", line)
            mentions = [m for code in codes for m in invocations(code, relative, number)]
            # Options explained in a command's table row are often in separate
            # inline spans: validate those too, against that command.
            if len(mentions) == 1 and not re.search(
                r"does not support|do not (?:pass|use)|not accepted|unknown options?", line
            ):
                m = mentions[0]
                # Only standalone flag spans belong to this command. A shell
                # probe such as `command -v ix` has its own options.
                flags = m.flags | frozenset(
                    f for code in codes if code.startswith("-") for f in FLAG.findall(code)
                )
                mentions = [Mention(m.path, m.line, m.argv, flags)]
            yield from mentions
            # Bare command names in the shared command taxonomy are guidance.
            if re.match(r"\| \*\*(Standard|Pro only)\*\*", line):
                for code in codes:
                    yield Mention(str(relative), number, (code,), frozenset())


def plugin_paths():
    yield from sorted((ROOT / "hooks").rglob("*.sh"))
    yield ROOT / "hooks/hooks.json"
    yield ROOT / "hooks/ix-cheatsheet.txt"
    yield from sorted((ROOT / "skills").rglob("*.md"))
    yield from sorted((ROOT / "agents").rglob("*.md"))
    for name in ("README.md", "CLAUDE.md", "IX_CLAUDE_PLUGIN_OVERVIEW.md"):
        yield ROOT / name


def help_definitions(text):
    # Read declarations only, not Examples (which can themselves be stale).
    options = set()
    commands = set()
    section = ""
    for line in text.splitlines():
        if re.match(r"^[A-Za-z][\w /-]*:$", line):
            section = line
        if section == "Options:":
            declaration = re.split(r"\s{2,}", line.strip(), maxsplit=1)[0]
            options.update(FLAG.findall(declaration))
        elif section == "Commands:":
            match = re.match(r"\s{2,}([a-z][\w-]*)\b", line)
            if match:
                commands.add(match[1])
    return options, commands


class CliHelp:
    def __init__(self):
        self.cache = {}

    def __call__(self, command):
        if command not in self.cache:
            result = subprocess.run(
                ["ix", *command, "--help"], capture_output=True, text=True, timeout=15,
            )
            if result.returncode or not re.search(r"^Usage: ix\b", result.stdout, re.M):
                raise ValueError(f"ix {' '.join(command)} --help: "
                                 f"{(result.stderr or result.stdout).strip()[:300]}")
            self.cache[command] = help_definitions(result.stdout)
        return self.cache[command]


def validate(mention, definitions):
    argv = mention.argv
    command = () if argv[0].startswith("-") else (argv[0],)
    options, children = definitions(command)
    if (argv[0] in PRO_COMMANDS and not children and options <= {"-h", "--help"}
            and (len(argv) > 1 or mention.flags - options)):
        raise DefinitionUnavailable(f"ix {argv[0]}: Pro definitions are not installed")
    index = len(command)
    while index < len(argv) and children:
        candidate = argv[index]
        if candidate.startswith("-"):
            break
        if candidate not in children:
            raise ValueError(f"unknown subcommand: ix {' '.join(command)} {candidate}")
        command += (candidate,)
        options, children = definitions(command)
        index += 1
    unknown = mention.flags - options
    if unknown:
        raise ValueError(f"ix {' '.join(command)}: unknown flags {' '.join(sorted(unknown))}")


def main():
    definitions = CliHelp()
    count = 0
    failures = []
    unavailable = set()
    for path in plugin_paths():
        try:
            for mention in scan(path):
                count += 1
                try:
                    validate(mention, definitions)
                except DefinitionUnavailable as exc:
                    unavailable.add(str(exc))
                except ValueError as exc:
                    failures.append(f"{mention.path}:{mention.line}: {exc}")
        except ValueError as exc:
            failures.append(str(exc))
    if failures:
        print("\n".join(sorted(set(failures))), file=sys.stderr)
        return 1
    if unavailable:
        print("\n".join(sorted(unavailable)), file=sys.stderr)
        print(f"CLI contract: scanned {count} mentions; full Pro validation unverified", file=sys.stderr)
        return 2
    print(f"CLI contract: {count} mentions checked against {len(definitions.cache)} help definitions")
    return 0


if __name__ == "__main__":
    sys.exit(main())
