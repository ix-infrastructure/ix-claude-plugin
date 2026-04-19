---
name: ix-docs
description: Generate narrative-first, importance-weighted documentation for a repo, system, or subsystem with a selective reference layer. Use --full for deeper module/class/method coverage.
argument-hint: <target> [--full] [--style narrative|reference|hybrid] [--split] [--single-doc] [--out <path>] [--save [path]]
---

> [ix-claude-plugin shared model](../shared.md)

Check `command -v ix` first. If unavailable, stop and say so.

## Goal

Produce documentation that helps a new engineer understand the system quickly and gives an LLM strong architectural context without drowning it in low-value detail.

Write like real engineering documentation for a framework or subsystem:
- teach the system
- explain how it works
- show where the important parts live
- surface risks and fragile boundaries
- point the reader to the next files or symbols to inspect

Never write a raw report dump.

---

## Core model

Every `ix-docs` run produces **two layers**:

1. **Narrative layer** (always first)
   - human-readable explanation
   - onboarding-focused
   - architecture, flow, usage, risks, navigation guidance

2. **Reference layer** (always present, but selective)
   - compressed summaries of important modules, classes, and services
   - short, structured, high-signal entries
   - no code dumping

**Mode behavior**
- `ix-docs <target>`: narrative-heavy by default, with a minimal selective reference appendix
- `ix-docs <target> --full`: deeper coverage for important components, still importance-weighted

**Style behavior**
- `--style narrative` (default): prose-first narrative sections; reference layer stays compact
- `--style reference`: tighter, docs-site style structure; narrative stays brief but is not removed
- `--style hybrid`: full narrative plus fuller selective reference; best match for `--full`

---

## Flags

| Fragment | Variable | Default |
|---|---|---|
| first non-flag token | `TARGET` | required |
| `--full` | `FULL=true` | false |
| `--style narrative|reference|hybrid` | `STYLE` | `narrative` |
| `--split` | `SPLIT=true` | false |
| `--single-doc` | `SINGLE=true` | false |
| `--out <path>` | `OUT_PATH` | auto-detect |
| `--save [path]` | alias for `--out` when `--out` is absent; if both are given, `--out` wins | — |

**Parsing**
Scan `$ARGUMENTS` left to right:
- The first token that does not begin with `--` is `TARGET`
- `--style` and `--out` consume the next token as their value (also accept `--style=value` form)
- All other flags are boolean toggles
- If `TARGET` is missing, stop and ask the user to supply a target before continuing

**Output rules**
- `--single-doc` forces one Markdown file
- `--split` produces a directory with `index.md` plus per-system or per-subsystem docs
- if neither is set and `FULL=true` on a repo with more than 10 subsystems, auto-enable `SPLIT=true`
- `--single-doc` overrides auto-splitting

**Output path auto-detection**
1. `docs/` exists at workspace root → `docs/<target-name>.md` or `docs/<target-name>/`
2. `doc/` exists → `doc/<target-name>.md` or `doc/<target-name>/`
3. otherwise → `<target-name>.md` or `<target-name>/` at workspace root

If `FULL=true`, tell the user the planned mode, output path, and whether splitting was auto-enabled before generating the docs.

---

## Non-negotiable rules

1. **Graph first**
   - Start with `ix subsystems`, `ix overview`, `ix rank`, `ix explain`
   - Use `ix read` only after graph data leaves an important behavior unclear

2. **Importance-weighted expansion**
   - Expand detail by centrality, risk, coupling, orchestration role, and user focus
   - Never treat all modules equally

3. **Selective low-level detail**
   - Default mode: module and class summaries only for important parts
   - Full mode: method summaries only for key classes or services

4. **No raw dumps**
   - Never output raw JSON
   - Never paste command logs
   - Never dump full file inventories, all callers, or all methods

5. **No redundancy**
   - Group repeated patterns
   - If several modules have the same role, summarize the pattern once
   - If an entity appears in multiple rankings, explain it once and cross-reference

6. **Code reads are rare**
   - Default mode: at most 2 `ix read` calls total
   - Full mode: at most 5 `ix read` calls total
   - Symbol-level only; never read whole files for this skill

---

## Coverage policy

Use the following ranking factors to decide what gets expanded:

1. **Centrality**: `ix rank`, caller count, dependent count
2. **Risk**: `ix impact`
3. **Coupling**: cross-system or cross-subsystem relationships
4. **Orchestration role**: coordinators, entry points, workflow managers from `ix explain`
5. **User focus**: the exact target and its immediate neighborhood

### Always include
- top-level architecture
- all major subsystems in scope
- the most important modules or services

### Sometimes include
- important files
- key classes or services
- notable boundary functions or entry points

### Only in `--full`
- selective method summaries for the most important classes or services
- expanded per-subsystem module coverage

### Never
- exhaustive inventories
- equal treatment for every module
- long method lists

### Expansion budgets

**Default mode**
- repo or large system: cover all major subsystems, expand the top 3-5 most important ones, reference 5-8 key components total
- subsystem or module: expand the target fully, reference the top 5-8 entities in scope
- symbol or small component: focus on the target, its immediate collaborators, and the surrounding subsystem

**Full mode**
- repo or large system: cover all major systems, expand the top 5-8 by importance, create short stubs for lower-ranked ones when split output is large
- subsystem or module: expand the top 8-12 entities, add method summaries for the top 3-5 classes or services only

When a repo is very large, prefer:
- full docs for the highest-ranked systems
- short overview stubs for the lower-ranked remainder

---

## Command strategy

Do not run every command mechanically. Reuse earlier results and stop when additional depth would not materially improve the documentation.

### Phase 1 — Scope

**Stop early:** If `TARGET` is an unambiguous symbol or small component and scope is clear from `ix stats` alone, skip the remaining Phase 1 commands and proceed to Phase 2.

Always start with:
```bash
ix stats --format json
ix subsystems --format json
ix subsystems --list --format json
ix briefing --format json 2>&1
```

**Pro check:** If `ix briefing` returns JSON with a `revision` field, Pro is available. Extract `activeGoals`, `recentDecisions`, and `recentChanges` for use in **[Pro]** steps. If it errors, skip all Pro-labeled steps — the skill works fully without them.

If `TARGET` is not obviously the whole repo:
```bash
ix locate "$TARGET" --format json
```

Resolve whether the target is:
- repo
- top-level system
- subsystem
- module or file
- class, service, or symbol

If ambiguous, resolve it before proceeding.

### Parallel agent dispatch (large / full-mode runs)

**Trigger:** `FULL=true` AND the target is a repo or top-level system with **more than 5 subsystems**.

**Phase 1 reuse:** Before running Phase 1 commands, check whether subsystem and rank data is already present in context from a prior `/ix-understand` run in this session. If `ix subsystems` results and rank results are already available, skip those Phase 1 commands and use the cached data directly — do not re-run them.

**Step 1 — Per-system agents:** From the Phase 1 rank results, select the top systems by importance (cap at 5). For each, spawn one `ix-system-explorer` agent in the background:

> Task template: *"Build a complete architectural mental model of `$SYSTEM` within `$TARGET`. Focus on: (1) internal module structure and responsibilities, (2) the most important and most-coupled components, (3) main execution flows within this subsystem, (4) outbound dependencies and shared interfaces with other subsystems. Return structured findings with: a one-paragraph subsystem summary, top 5 important modules with roles, key internal flows, and coupling risks."*

**Step 2 — Cross-cutting agent:** Immediately after spawning the per-system agents, spawn one additional `ix-system-explorer` agent for cross-system concerns:

> Task: *"In the `$TARGET` codebase, identify only what crosses subsystem boundaries: (1) shared types, base classes, and utilities used across multiple subsystems, (2) cross-system execution flows and handoff points, (3) infrastructure or platform services that multiple systems depend on, (4) god-modules or highly-central components visible from the dependency graph. Do NOT explore individual subsystems in depth — focus exclusively on cross-cutting structure. Return structured findings."*

**Do not wait** for any agent before starting Phase 2. Continue running Phase 2 commands while all agents work.

**Step 3 — Synthesis (when agent results arrive):**

Merge all agent findings with your Phase 2/3 graph results:

- **Per-system outputs** → populate per-system narrative sections (Sections 2–6) and per-system doc files in split mode. Use the agent's module characterizations and coupling insights; keep your rank-based ordering as the primary importance signal.
- **Cross-cutting output** → populate Section 5 (Dependencies & Relationships) and the cross-system sections of `index.md` in split mode.
- **Conflict resolution:** if an agent contradicts graph data, note the discrepancy and prefer the graph.
- **Failures:** if any agent fails or times out, continue without it — do not retry. Note the gap in the Coverage field of the document header.

**Skip this dispatch entirely** if:
- `FULL=false`
- the target is a subsystem, module, or symbol
- the repo has 5 or fewer subsystems

### Phase 2 — Architecture

**Stop when:** you have identified the top 3-5 important components and the subsystem structure is clear. Do not run additional rank queries once the most central components are known.

Use the graph to identify systems, subsystem boundaries, and the most important modules.

Common commands:
```bash
ix overview "$TARGET" --format json
ix rank --by dependents --kind class --top 10 --exclude-path test --format json
ix rank --by callers   --kind function --top 10 --exclude-path test --format json
```

If `TARGET` is the whole repo, skip `ix overview "$TARGET"` and rely on the pre-run subsystem data plus the rank results.

Additional commands by scope:

For repo or system targets:
```bash
ix subsystems "$TARGET" --format json
ix subsystems "$TARGET" --explain
```

For module or file targets:
```bash
ix contains "$TARGET" --format json
ix imports  "$TARGET" --format json
```

Full mode:
- raise rank budgets to 20
- inspect the most important systems first, never alphabetically
- for the top systems, collect `ix subsystems <system>` and `ix subsystems <system> --explain`

### Phase 3 — Behavior

**Stop when:** the main execution flow is understood. Skip `ix trace` if `ix explain` results are sufficient — do not run a trace just to be thorough.

This phase answers **how the system works**.

Use:
```bash
ix explain "$TARGET" --format json
```

Also run `ix explain` for the most important orchestrators, services, or entry points identified in Phase 2.

Behavior budget:
- default mode: explain the top 3-5 important entities
- full mode: for each important subsystem, explain the top 5 classes or services and the top 3 functions or entry points

Optional:
- run **one** `ix trace` only if the main execution flow is still unclear after `ix explain`

Describe:
- request or data lifecycle
- orchestration paths
- subsystem handoffs
- where decisions, transformation, or state changes happen

Do not narrate every edge in a trace.

### Phase 4 — Relationships

**Stop when:** for symbol-level or small single-module targets, skip this phase entirely — relationship data at that scope adds minimal value to the documentation.

Map the important dependencies and coupling points.

Use:
```bash
ix callers "$TARGET" --limit 15 --format json
ix callees "$TARGET" --limit 15 --format json
ix depends "$TARGET" --depth 2 --format json
```

**Repo-level guard:** If `TARGET` is the whole repo, skip `ix callers "$TARGET"`, `ix callees "$TARGET"`, and `ix depends "$TARGET"` entirely — these commands are not meaningful at repo scope and will produce noise. Instead, run them for the top 3-5 boundary components, orchestrators, or subsystem entry points identified in Phase 2, and summarize the cross-subsystem edges they reveal.

For repo or large system targets, focus on:
- cross-system relationships
- shared infrastructure
- boundary modules
- the most central components from the rank results

When counts are large:
- group callers by subsystem
- summarize repeated patterns
- never list more than 15 similar names individually

### Phase 5 — Risk

**Repo-level gate:** If `TARGET` is the whole repo, do not run `ix impact "$TARGET"` — impact analysis is not meaningful at repo scope. Skip directly to running `ix impact` for the top 3-5 high-centrality entities identified in Phase 2.

Otherwise run:
```bash
ix impact "$TARGET" --format json
```

Full mode:
- also run `ix impact` for the top 2-5 high-centrality entities

Use this phase to populate:
- fragile integration points
- change-sensitive modules
- shared infrastructure warnings
- parts of the system that need careful testing

### Phase 6 — Health

**Stop when:** for symbol-level or single-module targets, skip this phase — health issues at that scope are rarely actionable at the documentation level.

Use:
```bash
ix smells --format json
```

Note: `ix smells` does not support `--path` scoping — results are always repo-wide. If the target is a subsystem or module, filter results by path prefix after retrieval.

**[Pro]** If Pro is available and `recentDecisions` is non-empty, include relevant architectural decisions in the risk and complexity section:
```bash
ix decisions --format json
```

Prioritize:
- god modules
- highly coupled regions
- orphaned or poorly connected components
- subsystems with weak boundaries

Group health issues by subsystem, not as a flat dump.

### Phase 7 — Optional reads

**Stop when:** you reach the read budget. Never exceed it regardless of how many unclear behaviors remain — omit or note gaps instead.

Only read code when graph data is insufficient for an important behavior.

Allowed use cases:
- orchestrators with unclear control flow
- critical entry points on the main execution path
- high-risk components whose role is still ambiguous after `ix explain`

Use:
```bash
ix read <symbol> --format json
```

Do not summarize implementation line-by-line. Extract only the behavior needed to clarify the docs.

---

## Writing rules by style

### `--style narrative`
- lead with prose
- each narrative section should explain how to think about the system
- reference layer should stay compressed

### `--style reference`
- still keep the narrative layer first, but tighten it to short paragraphs
- use more headings, bullets, and compact summaries
- make the reference layer more prominent than in narrative mode

### `--style hybrid`
- full narrative layer
- fuller reference layer
- best option for `--full`, onboarding docs, and handoff docs

---

## Output structure

The document should feel like real documentation, not an investigation transcript.

Use this structure.

```markdown
# [Target] — Documentation

> Generated: [date]
> Scope: [repo | system | subsystem | module | symbol]
> Mode: [standard | full]
> Style: [narrative | reference | hybrid]
> Evidence quality: [strong | partial | weak]
> Coverage: [what was expanded vs summarized]

## Part 1 — Narrative

### 1. Overview
- what the system is
- what it does
- why it exists
- **[Pro]** active project goals this system serves (from `ix briefing` activeGoals), if available

### 2. Architecture
- systems -> subsystems -> modules
- boundaries and responsibilities
- high-level structure

### 3. How It Works
- main execution flows
- request or data lifecycle
- orchestration paths

### 4. Key Components
- the most important modules, classes, or services
- why they matter

### 5. Dependencies & Relationships
- major dependencies
- cross-system interactions
- important coupling points

### 6. Risk & Complexity
- high-risk areas
- fragile components
- change sensitivity

### 7. How to Work With This Repo
- where to start
- how to navigate
- common workflows
- what to modify carefully

### 8. Where to Go Deeper
- next files, modules, or symbols to inspect
- suggested exploration paths

## Part 2 — Selective Reference

### Module Summary
For each major module:
- purpose
- responsibilities
- dependencies
- key contained components

### Class / Service Summary
For each important class or service:
- role (orchestrator, boundary, helper, store, adapter, etc.)
- what it manages
- where it is used

### Method Summary
Only in `--full`, and only for key classes or services:
- method name
- 1-2 line role summary
- role in the system, not implementation detail
```

### Reference layer rules
- include only important modules or classes
- if a module is obvious and low-risk, omit it
- if multiple entities share a pattern, summarize the pattern once
- do not add method summaries in default mode unless the user explicitly asks for reference-heavy output

---

## Split output

Use split output when:
- `--split` is passed, or
- `FULL=true` and the repo is large enough that one doc would become unwieldy

Recommended structure:

```markdown
<OUT_DIR>/
  index.md
  <system-1>.md
  <system-2>.md
  ...
  <lower-ranked-system>-stub.md
```

### `index.md`
Should contain:
- overall overview
- top-level architecture
- the most important cross-system flows
- repo navigation guidance
- links to the per-system docs

### Per-system docs
Each system doc should contain:
- the full narrative structure
- a selective reference section for that system

### Stubs
For lower-ranked systems, create short stubs instead of full docs:
- one-paragraph overview
- top 3 important components
- one risk note
- clear instruction to rerun `ix-docs <system> --full` if deeper coverage is needed

---

## Success criteria

The output is successful if:
- a new engineer can understand the system quickly
- an LLM can reason about the system without rereading dozens of files
- the important parts are obvious
- the main execution flow is understandable
- guidance for deeper exploration is explicit

The output has failed if:
- it reads like a dump
- low-level detail dominates the document
- important components are buried
- every module gets equal treatment
- it gives no practical guidance on where to start

---

## Post-write confirmation

After writing the file or files, confirm:

```text
Documentation written.

Mode:   [standard | full]
Style:  [narrative | reference | hybrid]
Output: [path or directory]
Scope:  [repo/system/subsystem/module/symbol]
Coverage: [systems/subsystems/components expanded]

Summary: [2-3 sentences on the system and the most important architectural fact]

[If split:]
Files written: [index + key system docs + stubs]
```
