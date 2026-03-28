---
name: ix-understand
description: Build a mental model of a system, subsystem, or the whole repo. Graph-first, no code reads unless necessary.
argument-hint: [target — subsystem name, path, or empty for whole repo]
---

Check `command -v ix` first. If unavailable, stop and say so.

## Goal

Build an accurate mental model of the target's structure, purpose, and key components. Stop as soon as you can answer: *what does this do, what are its key parts, and where should someone explore next?*

## Phase 1 — Orient (always run)

Run in parallel:
```bash
ix subsystems --format json
ix rank --by dependents --kind class --top 10 --exclude-path test --format json
ix rank --by callers   --kind function --top 10 --exclude-path test --format json
```

If `$ARGUMENTS` is non-empty, also run:
```bash
ix locate "$ARGUMENTS" --limit 5 --format json
```

Extract from subsystems: region names, file counts, cohesion scores.
Extract from rank: the 3–5 most structurally central classes and functions.

**Stop here if:** `$ARGUMENTS` is empty and rank + subsystems give a clear picture.

## Phase 2 — Key components (run only if needed)

Pick the **2–4 most central or unclear** components from Phase 1 results. Run in parallel:
```bash
ix overview <component> --format json
```

Do NOT run `ix explain` yet. `ix overview` is cheaper and sufficient for most components.

**Stop here if:** you can describe what each component does and how they relate.

## Phase 3 — Clarify (run only if still unclear)

For at most **2** components still unclear after Phase 2:
```bash
ix explain <component> --format json
```

**Hard limits:** No `ix read`. No `ix map`. No `ix trace`. This skill never reads source code.

## Output

```
# [Target] — System Overview

## What it does
[One paragraph. Purpose, primary job, who uses it.]

## Key Components
- **X** (<kind>) — [role in one line, evidence: rank position / cohesion score]
- **Y** (<kind>) — [role in one line]
[3–5 max. Omit if fully explained by parent.]

## Structure
[Subsystem breakdown: name → file count → cohesion score → what it owns]

## Where to explore next
- `/ix-investigate <X>` — understand the most central component
- `/ix-architecture` — analyze coupling and design health
- `/ix-debug <X>` — if investigating a suspected bug
```

**Evidence labels:** Mark every claim as `[graph]` (direct ix data) or `[inferred]` (structural reasoning). Never state facts without one of these labels.
