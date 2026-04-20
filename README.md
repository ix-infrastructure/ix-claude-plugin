# ix-claude-plugin

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

## Agents

Autonomous multi-step agents for complex tasks:

| Agent | Purpose |
|-------|---------|
| `ix-explorer` | General-purpose graph exploration, open-ended questions |
| `ix-system-explorer` | Full architectural model of a codebase or region |
| `ix-bug-investigator` | Autonomous investigation from symptom to root cause candidates |
| `ix-safe-refactor-planner` | Blast radius + safe change sequencing for refactors |
| `ix-architecture-auditor` | Full structural health report with ranked improvements |

## Automatic hooks

| Trigger | Hook | Effect |
|---------|------|--------|
| User sends any prompt | `UserPromptSubmit` → `ix-briefing.sh` | Injects session briefing (goals, bugs, decisions) once per 10 min — **requires Ix Pro**; also instructs Claude to append a short final `Ix` section when hooks helped |
| Claude runs `Grep` or `Glob` | `PreToolUse` → `ix-intercept.sh` | Front-runs with `ix text` + `ix locate`/`ix inventory` |
| Claude runs `Bash` with grep/rg | `PreToolUse` → `ix-bash.sh` | Extracts pattern, front-runs with `ix text` + `ix locate` |
| Claude edits a file | `PreToolUse` → `ix-pre-edit.sh` | Runs `ix impact` before the edit |
| Claude edits a file | `PostToolUse` → `ix-ingest.sh` (async) | Runs `ix map <file>` to update the graph |
| Claude finishes responding | `Stop` → `ix-annotate.sh` | Emits a factual summary of how ix helped on that turn on non-`modelSuffix` channels |
| Claude finishes responding | `Stop` → `ix-map.sh` (async) | Runs `ix map` to refresh the full graph |

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

## Uninstall

```
/plugin uninstall ix-memory
```
