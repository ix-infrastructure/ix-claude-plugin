---
name: ix-plan
description: Generate a risk-ordered implementation plan for a set of targets. Assesses blast radius per target, finds data flows between them, and produces a safe change sequence.
argument-hint: <symbol1> [symbol2] [symbol3] ... OR description of change
---

Check `command -v ix` first. If unavailable, use Grep + Read to manually assess blast radius per target.

## Goal

Answer: *in what order should these changes be made, what will break, and what needs testing?*

## Phase 1 — Scope (always)

If `$ARGUMENTS` contains symbol names, proceed.
If `$ARGUMENTS` is a description (no identifiable symbols), first run:
```bash
ix text "$ARGUMENTS" --limit 10 --format json
ix locate "$ARGUMENTS" --limit 5 --format json
```
Identify the 1–4 most relevant symbols and treat those as targets.

## Phase 2 — Impact per target (parallel)

For each identified target, run simultaneously:
```bash
ix impact  <target> --format json
ix callers <target> --limit 10 --format json
```

Rank targets by risk level: critical > high > medium > low.

## Phase 3 — Data flow (only if 2+ targets)

Find how the targets connect:
```bash
ix trace <highest-risk-target> --to <second-target> --format json
```

Run for the most architecturally significant pair. Skip if targets are in independent subsystems.

## Phase 4 — Shared dependents (only if high/critical targets exist)

```bash
ix depends <highest-risk-target> --depth 2 --format json
```

Identify if any third symbol depends on multiple targets (shared blast radius — highest testing priority).

## Phase 5 — Ix Pro plan (if ix pro available)

If `ix briefing` returns plans/tasks, check for existing relevant plans:
```bash
ix plans --format json
```
Skip this phase if ix pro is unavailable.

## Output

```
# Change Plan

## Targets & Risk

| Target | Risk | Dependents | Key Callers |
|--------|------|------------|-------------|
| <A>    | high | 12         | X, Y, Z     |
| <B>    | low  | 2          | P           |

## Change Order

Edit in this sequence to minimize breakage:
1. [target] — [reason: lowest risk / most-depended-upon first]
2. ...

## Data Flow
[A → trace path → B — or "targets are independent"]

## Shared Risk
[Symbols affected by changes to multiple targets — these need testing after every change]

## Test Checkpoints
After [target A]: verify [specific callers]
After [target B]: verify [specific callers]

## Red Flags
- [any critical/high target needing extra care]
- [any cross-subsystem boundary being crossed]
```

Do not read source code in this skill unless a target cannot be resolved by `ix locate`.
