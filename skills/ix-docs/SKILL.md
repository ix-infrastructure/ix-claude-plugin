---
name: ix-docs
description: Generate deep, structured documentation for a system, subsystem, module, or component. Synthesizes architecture, behavior, relationships, risk, and health into a single cohesive document. Use --full for complete repository coverage.
argument-hint: <target> [--out <path>] [--full] [--split] [--single-doc] [--concise] [--depth 1|2|3] [--focus architecture|behavior|risk|dependencies]
---

Check `command -v ix` first. If unavailable, stop and say so.

---

## Argument parsing

| Fragment | Variable | Default |
|---|---|---|
| first non-flag token | `TARGET` | (required — use `.` or repo name for whole repo) |
| `--out <path>` | `OUT_PATH` | auto-detect (see below) |
| `--full` | `FULL=true` | false |
| `--split` | `SPLIT=true` | false (auto-set if FULL + repo is large) |
| `--single-doc` | `SINGLE=true` | false |
| `--concise` | `CONCISE=true` | false |
| `--depth <n>` | `DEPTH` | 1 (2 in full mode) |
| `--focus <area>` | `FOCUS` | all |

**`--focus` values:** `architecture` / `behavior` / `risk` / `dependencies`

**`--split` vs `--single-doc`:** If neither is set and full mode is triggered on a large target (> 10 subsystems), auto-set `SPLIT=true` and inform the user. `--single-doc` overrides this and forces one file regardless of size.

**Output path auto-detection:**
1. `docs/` exists at workspace root → `docs/<target-name>.md` (or `docs/<target-name>/` in split mode)
2. `doc/` exists → `doc/<target-name>.md` (or `doc/<target-name>/`)
3. Otherwise → `<target-name>.md` at workspace root (or `<target-name>/` in split mode)

---

## Pre-run: scope assessment

Always run before any other phase:

```bash
ix stats --format json
ix subsystems --format json
```

Extract: total entity count, subsystem count, system count.

**In full mode — emit warning and plan before proceeding:**

```
⚠ Full coverage run requested.
  Repo: [N] entities across [M] subsystems in [K] systems
  Mode: [single document | split — root + M subsystem files]
  Output: [OUT_PATH]
  Depth: [DEPTH]
  Note: Traversal is deeper and broader. This will take longer and produce more output.
```

Then state the execution plan: which systems will be documented, what depth, whether splitting.

**Auto-split threshold:** If `FULL=true` and subsystem count > 10 and `SINGLE=false`, set `SPLIT=true` automatically.

**Extremely large repos (> 50 subsystems):** In split mode, document top-level systems fully and create stubs for subsystems below rank threshold. State this in the warning: *"Repo has N subsystems. Full-depth docs will be created for the top [K] by importance. Remaining subsystems get overview stubs."*

---

## Phase 1 — Scope resolution

Determine what `TARGET` refers to and select budget tier.

**Normal mode — tier selection:**

Run in parallel:
```bash
ix locate "$TARGET" --limit 5 --format json
```
(subsystems already retrieved in pre-run)

Classify and select tier:

| Tier | Condition |
|------|-----------|
| **XL** | repo target, OR > 20 child regions, OR > 2000 total entities |
| **L** | subsystem with 5–20 child regions, OR 200–2000 entities |
| **M** | class/file/small module, 20–200 entities |
| **S** | single function/symbol, < 20 entities |

**Full mode — tier is always XL regardless of target, but XL constraints are lifted.** See full mode phase overrides below.

If ambiguous, resolve with `--pick`, `--path`, or `--kind` before proceeding.

---

## Phase 2 — Structure

**Normal mode — by tier:**

*Tier XL:*
```bash
ix subsystems --format json          # already ran — reuse
ix subsystems --list --format json
ix rank --by dependents --kind class    --top 5  --exclude-path test --format json
ix rank --by callers   --kind function  --top 5  --exclude-path test --format json
```
Document system-level shape only. Do not drill into individual subsystems.

*Tier L:*
```bash
ix subsystems "$TARGET" --format json
ix subsystems "$TARGET" --explain
ix rank --by dependents --kind class    --top 10 --exclude-path test --format json
ix rank --by callers   --kind function  --top 10 --exclude-path test --format json
```

*Tier M:*
```bash
ix overview  "$TARGET" --format json
ix contains  "$TARGET" --format json
ix imports   "$TARGET" --format json
```

*Tier S:*
```bash
ix explain   "$TARGET" --format json
ix overview  "$TARGET" --format json
```

**Full mode — expanded structure:**

```bash
ix subsystems --format json           # reuse from pre-run
ix subsystems --list --format json    # reuse from pre-run
ix rank --by dependents --kind class    --top 20 --exclude-path test --format json
ix rank --by callers   --kind function  --top 20 --exclude-path test --format json
```

Then for **each top-level system** (not each subsystem — keep this one level deep in Phase 2):
```bash
ix subsystems "<system>" --format json
ix subsystems "<system>" --explain
```
Run in parallel. Cap at the top 5 systems by entity count or rank.

**Ordering rule (full mode):** Always process systems and subsystems in rank order (most important first), never alphabetically.

---

## Phase 3 — Behavior

Skip if `--concise`, `--focus architecture`, or `--focus risk`.

**Normal mode:**
- *XL:* Skip — no individual explains
- *L:* `ix explain` top **3** entities by rank
- *M:* `ix explain` top **5** entities; skip if role obvious from Phase 2
- *S:* Already ran in Phase 2

**Full mode:**

For each system identified in Phase 2, run in parallel:
```bash
ix rank --by dependents --kind class    --top 10 --path "<system-path>" --exclude-path test --format json
ix rank --by callers   --kind function  --top 5  --path "<system-path>" --exclude-path test --format json
```

Then `ix explain` for:
- Top 5 classes per system (by dependents rank)
- Top 3 functions per system (by callers rank)
- Any entity with > 20 direct dependents regardless of system

**Deduplication:** If the same entity appears in multiple system rank lists, explain it once and cross-reference.

**Skip threshold:** Do not explain entities ranked below #10 in any metric unless they appear in a smell result or have > 15 cross-subsystem callers.

If `DEPTH >= 2`: run one trace per top-level system entry point:
```bash
ix trace "<top-entry-point>" --downstream --format json
```

---

## Phase 4 — Relationships

Skip if `--focus architecture`.

**Normal mode:**
- *XL:* `ix imported-by "$TARGET"` only — callers not meaningful at repo scope
- *L:* `ix callers --limit 20`, group if > 15
- *M:* `ix callers --limit 20` individually, `ix callees --limit 15`
- *S:* all callers (no cap), all callees, `ix depends --depth 2`

**Full mode:**

For the target scope:
```bash
ix callers     "$TARGET" --limit 50 --format json
ix imported-by "$TARGET" --format json
ix depends     "$TARGET" --depth 2  --format json
```

For each documented system/subsystem:
```bash
ix callers "<subsystem-entry-point>" --limit 20 --format json
```
Run in parallel. Group callers by subsystem — never list > 15 individual names; summarize the rest.

**Cross-subsystem edges (full mode priority):** Extract all calls that cross a system boundary. These are the highest-signal relationships — list them explicitly regardless of count.

If `--focus dependencies` or `DEPTH >= 3`:
```bash
ix depends "$TARGET" --depth 3 --format json
ix trace   "$TARGET" --format json
```

---

## Phase 5 — Risk

Always run.

```bash
ix impact "$TARGET" --format json
```

**Normal mode:** If risk is `high`/`critical`, add `ix depends --depth 2` and `ix callers --limit 30`.

**Full mode — expanded coverage:**

```bash
ix impact "$TARGET" --format json
```

Additionally, for each system/subsystem with high rank centrality (top 3 by dependents):
```bash
ix impact "<high-centrality-entity>" --format json
```
Run in parallel. Cap at 5 impact calls total — pick the highest-rank entities.

If any result is `critical`: immediately flag in the document and add:
```bash
ix depends "<critical-entity>" --depth 2 --format json
ix callers "<critical-entity>" --limit 30 --format json
```

**Group callers by subsystem** when count > 15. Never list individually beyond that.

---

## Phase 6 — Health

Skip if `--concise`.

**Normal mode:**
- *XL:* `ix smells --format json` — high-severity only, flag top 3 worst regions
- *L/M:* `ix smells --path "$TARGET" --format json`
- *S:* Skip

**Full mode:**
```bash
ix smells --format json
```
Reuse `ix subsystems --list` data from pre-run. Flag:
- All `god-module` smells (no threshold)
- All `orphan` files with 0 connections
- All regions with `crosscut_score > 0.15` (stricter than normal mode's 0.1)
- Top 5 regions by `external_coupling` score

**Group smells by system** — don't present as a flat list.

---

## Phase 7 — Code reads

**Normal mode:**
- *XL/L:* Never
- *M:* 2 symbol reads max
- *S:* 1 read if needed

**Full mode:**

Read code only for:
1. **Orchestrators** with > 15 dependents whose behavior is still unclear after `ix explain`
2. **Critical path entry points** identified in Phase 4 traces
3. **High-risk entities** flagged as `critical` in Phase 5

```bash
ix read <symbol> --format json
```

Cap: **5 symbol reads** total across the entire full mode run. Symbol-level only. Never full files.

**Skip criteria:** If `ix explain` returned high-confidence data (confidence > 0.8), do not read the source — the graph is sufficient.

---

## Output

### Single document (`--single-doc` or small target)

Write one file to `OUT_PATH`. Scale all sections to the tier/full-mode scope.

### Split mode (`--split` or auto-triggered)

Write a directory of files:

```
<OUT_DIR>/
  index.md              ← root architecture doc (Sections 1, 2, 7, 8, 9)
  <system-1>.md         ← full doc for system 1 (all 9 sections)
  <system-2>.md         ← full doc for system 2
  ...
  <system-N-stub>.md    ← overview stub for lower-ranked systems
```

Each subsystem file follows the same 9-section structure. Cross-link between files:
- Root `index.md` links to each system file
- Each system file links back to `index.md` and to adjacent systems

**Stub format** (for subsystems below rank threshold):
```markdown
# [Subsystem] — Overview Stub

> Full documentation not generated (below rank threshold).
> Run `/ix-docs <subsystem>` for complete documentation.

## Overview
[One paragraph from ix subsystems --explain]

## Key components
[Top 3 by rank]

## Risk
[ix impact result]
```

---

## Document structure (all modes)

```markdown
# [Target] — Documentation

> **Generated:** [date]
> **Scope:** [repo | subsystem | path | symbol]
> **Mode:** [standard | full | full --split | full --single-doc]
> **Tier:** [XL | L | M | S]  *(standard mode only)*
> **Evidence quality:** [strong | partial | weak]
> **Graph revision:** [N]
> *(full mode)* Coverage: [K] systems, [N] subsystems documented. [M] subsystems as stubs.
> *(full mode)* Files written: [list if split]

---

## 1. Overview
## 2. Architecture
## 3. Key Components
## 4. Behavior & Flow
## 5. Relationships
## 6. Risk & Impact
## 7. Architecture Health
## 8. Recommendations
## 9. Next Exploration Paths
```

Section content scales with mode and tier exactly as defined in the phase instructions above.

---

## Post-write confirmation

```
Documentation written.

Mode:   [standard | full | full --split]
Output: [OUT_PATH or list of files written]
Scope:  [K] systems · [N] subsystems · [M] key components documented
Graph revision: [N]
Evidence quality: [strong | partial | weak]

Summary: [2–3 sentences — most important architectural finding]

[Full mode only:]
Stubs created for: [list of subsystems below rank threshold]
To expand a stub: /ix-docs <subsystem-name>
```

---

## Budget table

| | XL (normal) | L | M | S | Full mode |
|---|---|---|---|---|---|
| Entity explains | 0 | 3 | 5 | 1 | 5 per system, skip if confidence > 0.8 |
| Callers fetched | N/A | 20, group > 15 | 20, group > 20 | all | 50 target + 20 per subsystem, always group > 15 |
| Rank results | top 5 | top 10 | top 10 | N/A | top 20 global + top 10 per system |
| Depends depth | 1 | 2 | 2 | 2 | 2 (3 with --depth 3) |
| Code reads | 0 | 0 | 2 max | 1 | 5 max total (orchestrators + critical path only) |
| Trace calls | 0 | 0 | 1 at depth ≥ 2 | 1 | 1 per top-level system at depth ≥ 2 |
| Smells | high-severity only | path-scoped | path-scoped | skip | full, grouped by system |
| Impact calls | 1 | 1 | 1 | 1 | 1 + up to 5 for high-centrality entities |

**Grouping rule (all modes):** When caller/dependent count exceeds the cap, always summarize as *"N callers across X subsystems, primarily in [top 2–3 subsystem names]"* — never truncate silently.

**Reuse rule:** Never re-run a command whose output was already collected in an earlier phase. Extract from existing results.

**Ordering rule (full mode):** All expansion decisions — which systems to document fully, which entities to explain, which to stub — are driven by rank position and risk level. Never alphabetical, never first-N.
