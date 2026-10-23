# ix-claude-plugin

[![Sponsor](https://img.shields.io/badge/sponsor-%E2%9D%A4-db61a2)](https://github.com/sponsors/ix-infrastructure)

A Claude Code plugin that turns Claude into a **graph-reasoning engineering agent** using [Ix Memory](https://github.com/ix-infrastructure/Ix) as its structured memory backend.

Claude + Ix = reasoning engine + persistent code knowledge graph. Skills are cognitive abstractions (not CLI wrappers) that minimize token usage and maximize accuracy.

## Installation

```
/plugin marketplace add ix-infrastructure/ix-claude-plugin
/plugin install ix-memory
```

Restart Claude Code after installing.

After install, Claude is taught to prefer Ix for structural questions, hooks automatically front-run common search/edit paths with Ix context, and Claude appends a short final `Ix` section when hooks materially helped on that turn.

## Requirements

- [Ix Memory](https://github.com/ix-infrastructure/Ix) installed and running (`ix status` returns ok)
- `jq` in PATH
- `ripgrep` (`rg`) in PATH

```bash
# Ubuntu/Debian
sudo apt install jq ripgrep

# macOS
brew install jq ripgrep
```

**Ix Pro** is optional. All skills and hooks work with basic Ix. Pro adds session briefing injection (goals, bugs, decisions) via the `ix-briefing.sh` hook.

## Skills

High-level cognitive skills — each one infers intent, orchestrates multiple graph queries, and synthesizes output. None are CLI aliases.

| Skill | What it does | Key rule |
|-------|-------------|----------|
| `/ix-understand [target]` | Build a mental model of a system or the whole repo | Graph only — no source reads |
| `/ix-investigate <symbol>` | Deep dive: what it is, how it connects, execution path | Graph first, one symbol read max |
| `/ix-impact <target>` | Change risk: blast radius, affected systems, test targets | Depth scales with risk level |
| `/ix-plan <targets...>` | Risk-ordered implementation plan for a set of changes | Parallel impact, finds shared dependents |
| `/ix-debug <symptom>` | Root cause analysis from symptom to candidates | Targeted reads at suspects only |
| `/ix-architecture [scope]` | Design health: coupling, smells, hotspots | Graph only — never reads source |
| `/ix-docs <target> [--full] [--style narrative|reference|hybrid] [--split] [--single-doc] [--out <path>]` | Generate narrative-first system documentation with a selective reference layer | Default is onboarding-focused; `--full --style hybrid` gives the deepest coverage |

All skills fall back gracefully when ix is unavailable.

Skills are slash commands you type. They are hidden from the model (`disable-model-invocation: true`), so Claude does not start one by itself, and their descriptions are not sent with every model call.

## Agent

One agent, `ix-explorer`: graph-first exploration for open-ended questions about unfamiliar code. Its one-line description is the only part of the plugin's skills and agents that Claude Code lists in every model call.

Skills that delegate deeper work launch `ix-explorer` with a role brief that sits beside the skill:

| Skill | Role brief | Purpose |
|-------|-----------|---------|
| `/ix-understand`, `/ix-docs` | `skills/ix-understand/system-explorer-brief.md` | Full architectural model of a codebase or region |
| `/ix-debug` | `skills/ix-debug/bug-investigator-brief.md` | Investigation from symptom to root cause candidates |
| `/ix-plan` | `skills/ix-plan/refactor-planner-brief.md` | Blast radius + safe change sequencing for refactors |
| `/ix-architecture` | `skills/ix-architecture/architecture-auditor-brief.md` | Full structural health report with ranked improvements |

## Automatic hooks

| Trigger | Hook | Default | Effect |
|---------|------|---------|--------|
| User sends any prompt | `UserPromptSubmit` → `ix-briefing.sh` | on | Injects session briefing (goals, bugs, decisions) once per 10 min — **requires Ix Pro**. On a session's first task-sized prompt, also the files Ix trusts as starting points for it (`ix context --from-issue - --lean`; `IX_ISSUE_START=off` to disable). Can also ask Claude to append a short final `Ix` section (`IX_ANNOTATE_CHANNEL`) |
| Claude runs `Grep` or `Glob` | `PreToolUse` → `ix-intercept.sh` | off: `IX_GREP_INTERCEPT=on` (or `IX_BLOCK_ON_HIGH_CONFIDENCE=1`) | Grep naming one definition: where it is defined and its callers at their call sites (`ix locate` + `ix callers`), else silent. Glob with a path: `ix inventory`. When on, costs `ix locate` + `ix text` before every Grep and `ix inventory` before most Globs with a path; it rarely names something the search does not find itself |
| Claude runs `Bash` with grep/rg | `PreToolUse` → `ix-bash.sh` | off: `IX_GREP_INTERCEPT=on` | Extracts the pattern; if it names one definition, adds where it is defined and its callers, else silent. When on, costs one `ix locate` before every shell grep |
| Claude edits a file | `PreToolUse` → `ix-pre-edit.sh` | off: `IX_PRE_EDIT_GATE=on` | Runs `ix impact` before the edit and warns when the file has many dependents (a count and a risk level). When on, costs one `ix impact` before every edit |
| Claude edits a file | `PostToolUse` → `ix-ingest.sh` (async) | on | Requests the guarded root map (below); never maps the single file |
| Claude edits, by tool or through `Bash` | `PostToolUse` → `ix-dependents.sh` | off: `IX_EDIT_DEPENDENTS=on` | `ix hook claude-post-edit` (Ix CLI 0.12.1+): from the working tree's diff, the callers, importers and tests of each symbol the edit changed, once per session. When on, costs one `ix hook` after every edit and after every Bash command that may write; a Bash command that can only read (`cat`, `ls`, `git diff`, ...) skips it, except right after a report (`IX_BASH_EDIT_CLASSIFIER=off` runs it after every Bash command) |
| Claude finishes responding | `Stop` → `ix-annotate.sh` | on | Emits a factual summary of how ix helped on that turn on non-`modelSuffix` channels |
| Claude finishes responding | `Stop` → `ix-map.sh` (async) | on | Guarded `ix map <root> --silent`: git root of the session's cwd (not `$HOME`), already-mapped projects only, debounced per root, detached |

The hooks that are off by default block the tool call while they run, and what they say rarely changes what Claude does next. Off, each exits on its first lines (no ix call, no jq, nothing printed). To turn one back on, set its switch in the environment Claude Code starts in, e.g. `export IX_EDIT_DEPENDENTS=on`.

`hooks/ix-read.sh` remains in the repo as a disabled placeholder, but it is not registered in `hooks/hooks.json` and does not run at runtime.

All hooks bail silently if `ix` is not in PATH or the backend is unreachable.

## Debugging ix Hook Calls

If you want to see exactly which `ix` CLI commands Claude-triggered hooks run, start Claude Code with `IX_DEBUG_LOG` set in its environment:

```bash
export IX_DEBUG_LOG=/tmp/ix-hooks.log
tail -f /tmp/ix-hooks.log
```

The hooks will append lines like:

```text
[2026-04-19T12:34:56-0700] [ix-intercept] CMD ix text AuthService --limit 15 --format json --path src/
[2026-04-19T12:34:56-0700] [ix-intercept] CMD ix locate AuthService --format json
```

`CMD ...` lines are the exact shell-escaped `ix` invocations. `INJECT ...` lines show the exact context a hook injected back into Claude.

Every hook run also ends with exactly one `EXIT` line, on every path (including the runs where the hook decided to say nothing): wall time in milliseconds from the hook's first line to its exit, its exit code, and the payload's `tool_name` (`-` when there is none):

```text
[2026-10-15T18:54:03] [ix-intercept] EXIT ms=37 rc=0 tool=Grep
```

To see where a recorded session's hook time went, sum them by hook:

```bash
awk '/ EXIT ms=/ { sub(/^ms=/, "", $4); n[$2]++; t[$2] += $4 }
     END { for (h in t) printf "%-16s %5d runs %8d ms\n", h, n[h], t[h] }' /tmp/ix-hooks.log
```

With `IX_DEBUG_LOG` unset the hooks skip all of this: no timer, no trap, no file.

## Uninstall

```
/plugin uninstall ix-memory
```
