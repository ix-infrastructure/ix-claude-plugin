---
name: ix-impact
description: Change risk analysis — blast radius, affected systems, and what to test. Depth scales with risk level; low-risk targets stop early.
argument-hint: <symbol or file>
---

Check `command -v ix` first. If unavailable, use Grep to find all usages and estimate impact manually.

## Goal

Answer: *what breaks if this changes, and is it safe to proceed?* Stop as early as the risk level allows.

## Phase 1 — Risk score (always)

```bash
ix impact $ARGUMENTS --format json
```

**Immediately classify:**

| Risk level | Action |
|---|---|
| `low` + < 3 dependents | **STOP** — safe to proceed. Report and suggest verification targets. |
| `medium` OR 3–10 dependents | Go to Phase 2 |
| `high` or `critical` OR > 10 dependents | Go to Phase 2 + 3 |

## Phase 2 — Callers and dependents (medium/high/critical)

Run in parallel:
```bash
ix callers  $ARGUMENTS --limit 20 --format json
ix depends  $ARGUMENTS --depth 2 --format json
```

Extract: direct callers by name and subsystem, transitive count.

**Stop here if risk is `medium`:** report callers, suggest verification, done.

## Phase 3 — Import chain and subsystem spread (high/critical only)

```bash
ix imported-by $ARGUMENTS --format json
```

Cross-reference callers + dependents + importers to identify:
- Which subsystems are in the blast radius
- Whether the change crosses an architectural boundary
- Any tests that cover the affected paths

## Output

```
## Impact: [target]

**Risk level:** <critical | high | medium | low>
**Verdict:** <SAFE TO PROCEED | REVIEW CALLERS FIRST | NEEDS CHANGE PLAN>

**Blast radius:**
- Direct dependents: N
- Transitive (depth 2): M
- Subsystems affected: [list — only if phase 3 ran]

**Key callers:** [top 5, with subsystem label]

**At-risk behaviors:** [from ix impact atRiskBehavior field]

**Recommended action:**
- low: proceed, verify [specific callers]
- medium: test [caller list] after change
- high/critical: run `/ix-plan $ARGUMENTS` before editing
```

Never read source code in this skill. Risk analysis is purely graph-based.
