---
name: ix-understand
description: Build a detailed architectural mental model of a system, subsystem, or the whole repo. Graph-first, source reads only when needed for data flow or key patterns.
argument-hint: [target] [--shallow (default) | --medium | --deep]
---

> [ix-claude-plugin shared model](../shared.md)

Check `command -v ix` first. If unavailable, stop and say so.

## Flag parsing

Parse `$ARGUMENTS` before doing anything else:
- The first non-flag token is `TARGET` (may be empty — means whole repo)
- `--shallow`: orient only, no agents (default if no flag given)
- `--medium`: single agent regardless of system count
- `--deep`: full parallel agent strategy

**MANDATORY for `--medium` and `--deep`: This skill MUST use the Agent tool (subagent_type: "ix-memory:ix-system-explorer") for all exploration work. Do NOT run ix commands yourself except for the Phase 1 orient commands below. All subsystem exploration MUST be delegated to agents.**

## Phase 1 — Orient

Run these commands **in parallel** to discover the architecture:

```bash
ix subsystems --format json
ix subsystems --list --format json
ix rank --by dependents --kind class --top 15 --exclude-path test --format json
ix rank --by callers --kind function --top 15 --exclude-path test --format json
ix stats --format json
```

From the results, identify:
- All top-level systems (names, file counts, cohesion, coupling scores)
- The top 10-15 structurally important classes and functions
- Total codebase scale (files, nodes, edges)

If `TARGET` is set, scope the orient to that target's subsystems.

**Confidence check:** Scan `confidence` scores in the `ix subsystems` results:
- Any system with `confidence < 0.5`: add this caveat to the final output header: `⚠ Graph boundary confidence is low for [system] (${confidence}). Structural claims for this region may not reflect actual file relationships.`
- Any system with `confidence < 0.3`: report fuzzy boundary as an explicit finding. Label **all** structural claims for that region as `[uncertain]`.

## Depth routing

Choose the path based on the parsed depth flag:

### --shallow (default)

Synthesize from Phase 1 data only — no agents. Produce:

```
# [TARGET or "Whole Repo"] — System Overview

**Scale:** [files, nodes, edges — from ix stats]

## Subsystem Map
| Subsystem | Files | Cohesion | Coupling | Role |
|-----------|-------|----------|----------|------|
[one row per subsystem from ix subsystems]

## Top Classes (by dependents)
[top 10 from ix rank results]

## Top Functions (by callers)
[top 10 from ix rank results]

## Quick Assessment
[1–2 sentences on overall shape and structural health based on the metrics]
```

Then stop. Suggest deeper options at the bottom:
> For a single-agent summary: `/ix-understand [target] --medium`
> For full parallel analysis: `/ix-understand [target] --deep`

### --medium

Launch a **single** `ix-memory:ix-system-explorer` agent regardless of system count. Do not proceed to Phase 2.

Pass:
> Build an architectural mental model of: $TARGET (or the whole repo if no target)
>
> **Orient data (pre-computed):**
> [Paste Phase 1 results — subsystem list, top components, stats]
>
> **Skip Step 1** — orient data is provided. Start from Step 2.
>
> **Depth:** Cover all major subsystems at one level of depth each. Prioritize breadth over depth — no need to drill into internals of every component.
>
> **Label every claim as [graph] or [inferred].**

Present the agent's output directly to the user. Do not proceed to Phase 2.

### --deep

Continue to Phase 2.

## Phase 2 — Decide: serial or parallel (--deep only)

Count the number of **significant top-level systems** (file count >= 10 or confidence >= 0.5).

- **≤ 3 significant systems**: Launch a **single** `ix-system-explorer` agent with the full prompt (Phase 3A).
- **> 3 significant systems**: Launch **parallel** `ix-system-explorer` agents, one per system (Phase 3B).

## Phase 3A — Single agent (--deep, small codebase)

**You MUST use the Agent tool** with `subagent_type: "ix-memory:ix-system-explorer"` here. Do NOT do this work yourself. Launch one agent with:

> Build a **detailed** architectural mental model of: $TARGET
>
> If no target is specified, explore the whole repo.
>
> **Orient data (pre-computed):**
> [Paste the orient results from Phase 1 — subsystem list, top components, stats]
>
> **Skip Step 1** — orient data is provided above. Start from Step 2.
>
> **Depth expectations:** Comprehensive architectural document for onboarding. Go wide AND deep. Enumerate all major subsystems. For important ones, drill into internal structure.
>
> **What to cover:** subsystem internals, type system, data flows (ASCII diagrams), key components (up to 15), build/test infra, coupling, risks (security/complexity/data integrity), navigation shortcuts, where to go deeper.
>
> **Label every claim as [graph] or [inferred]. Use tables and ASCII diagrams.**

Then present the agent's output directly to the user.

## Phase 3B — Parallel agents (--deep, large codebase)

**You MUST use the Agent tool** with `subagent_type: "ix-memory:ix-system-explorer"` for each system. Launch **ALL agents in a single message** (this runs them in parallel). Do NOT use `run_in_background`. You must wait for all agents to return before proceeding to Phase 4. Each agent gets:

> Explore the **$SYSTEM_NAME** subsystem in detail.
>
> **Orient data (pre-computed):**
> [Paste the full orient results so each agent has global context]
>
> **Skip Step 1** — orient data is provided. Start from Step 2 scoped to **$SYSTEM_NAME**.
>
> **What to produce:**
> 1. What $SYSTEM_NAME does — purpose, path, file count, role in the architecture
> 2. Internal structure — sub-components table (name, path, kind, role)
> 3. Key types and abstractions within this system
> 4. Top 3-5 most important components (with `ix explain`) — role, dependents, callers
> 5. Primary data flow within this system (ASCII diagram if applicable)
> 6. External coupling — which OTHER systems does this one connect to and how?
> 7. Risk areas specific to this system
> 8. 1-2 targeted source reads (`ix read`) only if the graph left key patterns unclear
>
> **Output format:**
> ```
> ## $SYSTEM_NAME (path)
>
> **Purpose:** [one sentence]
> **Scale:** [file count, key entity counts]
>
> ### Internal Structure
> | Component | Kind | Role |
> |-----------|------|------|
>
> ### Key Components
> | Component | Location | Role | Dependents | Risk |
> |-----------|----------|------|------------|------|
>
> ### Data Flow
> [ASCII diagram if applicable]
>
> ### External Coupling
> [Which systems it connects to, edge counts, coupling direction]
>
> ### Risks
> [Specific risks with file paths]
> ```
>
> **Label every claim as [graph] or [inferred].**

Include one additional **ix-system-explorer** agent in the same single message for **cross-cutting concerns**:

> Analyze **cross-system structure** for this codebase.
>
> **Orient data (pre-computed):**
> [Paste orient results]
>
> Using the graph, determine:
> 1. **Core type system / data model** — what are the fundamental types shared across systems? Use `ix rank --by dependents --kind class --top 15 --exclude-path test --format json` and `ix explain` on the top 5.
> 2. **Primary data flows** — trace 1-3 key execution paths end-to-end across system boundaries using `ix trace`. Produce ASCII diagrams.
> 3. **Build & development infrastructure** — `ix inventory --kind file --path test --limit 10 --format json`, `ix inventory --kind file --path cmd --limit 20 --format json`, and Glob for build files if needed.
> 4. **Cross-system coupling hotspots** — which system pairs have the most edges between them?
> 5. **Navigation shortcuts** — "To find X, look at Y" table for common tasks.
> 6. **Where to go deeper** — specific ix commands for follow-up.
>
> **Label every claim as [graph] or [inferred].**

## Phase 4 — Synthesize (--deep only)

**Do NOT proceed until ALL agents from Phase 3 have returned their results.** Once all agents complete, **you** (not an agent) assemble the final document:

```
# System: [name or "Whole Repo"]

## Overview
[What the system is and does — purpose, language, scale. Sourced from orient data.]

## Architecture

### System Map
[Table of ALL top-level systems with file counts, cohesion, coupling, roles — from orient data]

[Insert each subsystem agent's output as its own ### section]

## Core Abstractions / Type System
[From cross-cutting agent]

## Data Flows
[From cross-cutting agent — ASCII diagrams showing end-to-end paths across systems]

## Key Components
[Merged table from all subsystem agents, sorted by dependents descending, top 15]

| Component | System | Location | Role | Dependents | Risk |
|-----------|--------|----------|------|------------|------|

## Build & Development Infrastructure
[From cross-cutting agent]

## Dependencies & Coupling
[From cross-cutting agent — cross-system coupling hotspots + external deps]

## Risk Areas

### Security Risks
[Merged from all agents]

### Complexity Risks
[Merged from all agents]

### Data Integrity Risks
[Merged from all agents]

## Navigation Shortcuts
[From cross-cutting agent]

| To find... | Look at... |
|------------|-----------|

## Where to Go Deeper
[From cross-cutting agent]

## Selective Reference
[Top 15-20 most important entities across all systems — merged and deduplicated]
```

**Quality bar:** The final document must be comprehensive (all systems covered), specific (file paths, counts), structured (tables, ASCII diagrams), actionable (navigation shortcuts), and evidenced ([graph] or [inferred] labels).
