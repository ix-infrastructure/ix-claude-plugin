# ix-claude-plugin

This repo is the Claude Code plugin for [Ix Memory](https://github.com/ix-infrastructure/Ix). When working in this repo, use `ix` commands to navigate it just like any other codebase.

---

## Cognitive Model

Claude + Ix operates as a **three-layer system**:

```
Ix Graph     = structured memory (code relationships, history, decisions)
Claude       = reasoning engine (infers, synthesizes, decides)
Skills/Agents = cognition layer (task abstractions over the graph)
```

This means Claude is **not a command wrapper**. Claude uses Ix as memory to reason, then synthesizes answers. The graph provides facts; Claude provides understanding.

---

## Behavioral Rules

### Always
- Use Ix graph data **before** reading source code
- Read at **symbol level** only — `ix read <function>`, never whole files
- Use **high-level skills** (`/ix-investigate`, `/ix-understand`) not raw commands
- **Stop early** — once you can answer the question, stop querying
- **Label evidence** — distinguish graph-backed facts from inferences

### Never
- Scan entire files unless the whole file is the explicit subject
- Call `ix depends --depth 3+` or `ix trace` without a specific question
- Assume behavior without graph or code evidence
- Output raw JSON — always synthesize and summarize
- Run `ix map` for exploration (use `ix subsystems` — it reads cached data)
- Run `ix rank` without `--by <metric>` and `--kind <kind>` (will error)

---

## Reasoning Strategy

When answering a question about the codebase:

```
1. Orient       → ix subsystems or ix overview (understand the shape)
2. Locate       → ix locate (find the specific entity)
3. Explain      → ix explain (get role, connections from graph)
4. Trace/Depend → ix trace or ix depends (only if flow/blast-radius needed)
5. Read         → ix read <symbol> (only if implementation detail needed)
6. Synthesize   → answer the question, cite evidence
7. Suggest      → one useful next step
```

**Skip steps** if earlier steps answer the question. Most questions stop at step 3.

---

## Token Budget Rules

| Operation | Rule |
|---|---|
| Text search | `--limit 20` cap |
| Symbol rank | `--top 10` cap, always `--exclude-path test` |
| Callers/callees | `--limit 15` cap |
| Dependency tree | `--depth 2` max unless user asks for deeper |
| Code reads | Symbol-level only, max 2 per task |
| Traces | One trace per investigation; `--depth 2` max |

---

## Skill Reference

| Skill | Purpose | When to use |
|---|---|---|
| `/ix-understand [target]` | Mental model of a system | Onboarding, architecture questions, "how does X work?" |
| `/ix-investigate <symbol>` | Deep dive into a component | Before modifying, explaining, or debugging something |
| `/ix-impact <target>` | Change risk analysis | Before any non-trivial edit |
| `/ix-plan <targets...>` | Risk-ordered change plan; delegates to `ix-safe-refactor-planner` for targets with >20 dependents or region coupling >5 | Multi-file changes, refactors |
| `/ix-debug <symptom>` | Root cause analysis; delegates to `ix-bug-investigator` for multi-subsystem or low-confidence bugs | Bug investigation, unexpected behavior |
| `/ix-architecture [scope]` | Design health analysis; delegates to `ix-architecture-auditor` when ≥3 smells, god-module, or crosscut >0.1 | Code review, architecture discussions |
| `/ix-docs <target> [--full] [--style narrative|reference|hybrid] [--split] [--single-doc] [--out <path>]` | Write narrative-first docs; dispatches parallel `ix-system-explorer` agents for large targets in `--full` mode | Onboarding docs, handoffs, deep reference |

`ix-docs` writes a narrative-first Markdown document (or split doc set) to disk. Each run starts with an onboarding-friendly narrative layer and ends with a selective reference section for the most important modules, classes, and, in `--full`, key methods. Output path auto-detects `docs/`, `doc/`, or workspace root if `--out` is omitted.

**Modes:**
- *(default)* — narrative-focused onboarding doc with a compact selective reference appendix
- `--full` — deeper coverage for important systems, modules, classes, and selected methods; still importance-weighted, never exhaustive
- `--style narrative` — prose-first narrative sections with a compact reference layer
- `--style reference` — docs-site style structure with a briefer narrative layer
- `--style hybrid` — full narrative plus fuller selective reference; recommended with `--full`
- `--full --split` — produce `index.md` plus per-system or per-subsystem docs for large repos
- `--full --single-doc` — force one large file regardless of repo size

---

## Agent Reference

| Agent | Purpose |
|---|---|
| `ix-explorer` | General-purpose exploration, open-ended questions |
| `ix-system-explorer` | Full architectural mental model of a codebase or region |
| `ix-bug-investigator` | Autonomous root cause analysis from symptom to candidates |
| `ix-safe-refactor-planner` | Blast radius + safe change sequencing for refactors |
| `ix-architecture-auditor` | Full structural health report with ranked improvements |

---

## Repo Structure

```
skills/
  ix-understand/SKILL.md     — mental model (graph only)
  ix-investigate/SKILL.md    — symbol deep dive (graph + minimal read)
  ix-impact/SKILL.md         — risk analysis (graph only)
  ix-plan/SKILL.md           — change plan (graph + optional read)
  ix-debug/SKILL.md          — root cause analysis (graph + targeted read)
  ix-architecture/SKILL.md   — design health (graph only)

agents/
  ix-explorer.md             — general exploration
  ix-system-explorer.md      — architectural model building
  ix-bug-investigator.md     — autonomous debugging
  ix-safe-refactor-planner.md — refactor safety planning
  ix-architecture-auditor.md — structural health audit

hooks/
  ix-briefing.sh    — UserPromptSubmit: inject session context (Pro)
  ix-intercept.sh   — PreToolUse(Grep|Glob): front-run with ix text + ix locate
  ix-read.sh        — PreToolUse(Read): inject ix overview + inventory
  ix-bash.sh        — PreToolUse(Bash): intercept grep/rg, run ix text instead
  ix-pre-edit.sh    — PreToolUse(Edit|Write): run ix impact before edits
  ix-ingest.sh      — PostToolUse(Write|Edit): async ix map <file>
  ix-map.sh         — Stop: async ix map to refresh full graph
  hooks.json        — hook event → script mapping

.claude-plugin/
  plugin.json       — plugin manifest (name, version)
```

---

## Skill Format

```markdown
---
name: ix-<name>
description: <one-line description>
argument-hint: <shown as placeholder>
---

<reasoning protocol — not a command list>
```

`$ARGUMENTS` = user input after the skill name.

### Writing a good skill

A valid skill:
- Has **phases with stop conditions** (stop when answer is sufficient)
- **Scales depth with risk** (low-risk = less queries)
- **Reads code last** and only at symbol level
- Produces **structured output** (Summary, Findings, Evidence, Next Step)
- Is a **capability**, not a CLI alias

An invalid skill:
- Maps 1:1 to a CLI command
- Has no conditional logic or stop conditions
- Reads full files or too much code
- Outputs raw command results

---

## ix CLI quick reference

| Task | Command |
|---|---|
| Architecture overview | `ix subsystems --format json` |
| Structural summary | `ix overview <name> --format json` |
| Understand a symbol | `ix explain <symbol> --format json` |
| Find definition | `ix locate <symbol> --format json` |
| Read one symbol's source | `ix read <symbol> --format json` |
| Trace call chain | `ix trace <symbol> --format json` |
| Who calls it | `ix callers <symbol> --format json` |
| What it calls | `ix callees <symbol> --limit 15 --format json` |
| What imports it | `ix imported-by <path> --format json` |
| Members of a class | `ix contains <symbol> --format json` |
| Upstream dependents | `ix depends <symbol> --depth 2 --format json` |
| Blast radius | `ix impact <target> --format json` |
| List entities in path | `ix inventory --kind function --path <dir> --format json` |
| Text search | `ix text <pattern> --limit 20 --format json` |
| Code smells | `ix smells --format json` |
| Rank key components | `ix rank --by dependents --kind class --top 10 --format json` |
| Refresh graph | `ix map --silent` |

> `ix rank` requires `--by` (dependents/callers/importers/members) and `--kind` — both required options.
> Never use `ix query` — deprecated.
