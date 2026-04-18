# ix-claude-plugin

A Claude Code plugin that turns Claude into a **graph-reasoning engineering agent** using [Ix Memory](https://github.com/ix-infrastructure/Ix) as its structured memory backend.

Claude + Ix = reasoning engine + persistent code knowledge graph. Skills are cognitive abstractions (not CLI wrappers) that minimize token usage and maximize accuracy.

## Installation

```
/plugin marketplace add ix-infrastructure/ix-claude-plugin
/plugin install ix-memory
```

Restart Claude Code after installing.

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
| User sends any prompt | `UserPromptSubmit` → `ix-briefing.sh` | Injects session briefing (goals, bugs, decisions) once per 10 min — **requires Ix Pro** |
| Claude runs `Grep` or `Glob` | `PreToolUse` → `ix-intercept.sh` | Front-runs with `ix text` + `ix locate`/`ix inventory` |
| Claude runs `Read` | `PreToolUse` → `ix-read.sh` | Front-runs with `ix inventory` + `ix overview` for the file |
| Claude runs `Bash` with grep/rg | `PreToolUse` → `ix-bash.sh` | Extracts pattern, front-runs with `ix text` + `ix locate` |
| Claude edits a file | `PreToolUse` → `ix-pre-edit.sh` | Runs `ix impact` before the edit |
| Claude edits a file | `PostToolUse` → `ix-ingest.sh` (async) | Runs `ix map <file>` to update the graph |
| Claude finishes responding | `Stop` → `ix-map.sh` (async) | Runs `ix map` to refresh the full graph |

All hooks bail silently if `ix` is not in PATH or the backend is unreachable.

## Uninstall

```
/plugin uninstall ix-memory
```
