---
name: ix-architecture
description: Analyze system design — structure, coupling, code smells, and high-risk hotspots. Purely graph-based, no code reads.
argument-hint: [path or subsystem name — empty for whole repo] [--save [path]]
---

> [ix-claude-plugin shared model](../shared.md)

## Argument parsing

Strip `--save` and any following path token from `$ARGUMENTS` before processing the scope.
- If `--save <path>` is present, set `SAVE_PATH` to that path.
- If `--save` is present without a path, auto-generate `ix-architecture-<scope-slug>.md` in cwd (scope slug = `$ARGUMENTS` with spaces and slashes replaced by `-`, or `repo` if arguments are empty).
- If `--save` is absent, `SAVE_PATH` is empty — do not write a file.

## Health gate

Before anything else, run:
```bash
command -v ix
ix status
```
If either fails, stop: *"ix graph unavailable — run `ix connect` or check your connection."*

Then verify the graph has data:
```bash
ix subsystems --list --format json
```
If the result is empty or returns an error, stop: *"No graph data yet — run `ix map` to build the graph first."*

## Pro check

```bash
ix briefing --format json 2>&1
```
If it returns JSON with a `revision` field, Pro is available. Note `recentDecisions` for use below. Skip all **[Pro]** steps if it errors.

---

## Phase 1 — Subsystem structure

```bash
ix subsystems --format json
```

Filter results to `$ARGUMENTS` scope if provided (match on subsystem name or path prefix). Store the full JSON as `SUBSYSTEMS`.

**Early-stop gate:** Examine each region's metrics. If ALL of the following are true across every region:
- `cohesion > 0.7`
- `coupling < 0.4`
- `crosscut_score ≤ 0.1` (or field absent)
- `confidence ≥ 0.6`

→ Report *"System appears structurally healthy — no significant coupling, cohesion, or crosscutting issues detected."* List subsystems with their metrics and stop. Do not proceed to Phase 2.

---

## Phase 2 — Smell analysis

```bash
ix smells --format json
```

Filter to scope if `$ARGUMENTS` was provided. Store as `SMELLS`.

**Health gate — choose one path:**

**Inline path** (all must be true):
- Smell count < 3
- No `god-module` smell present
- No smell has `crosscut_score > 0.1`

→ Synthesize the report inline using `SUBSYSTEMS` + `SMELLS`. Proceed to Phase 3 only if needed (see below). Skip delegation.

**Delegate path** (any is true):
- Smell count ≥ 3
- A `god-module` smell is present
- Any smell has `crosscut_score > 0.1`

→ Spawn the **ix-architecture-auditor** agent. Pass `SUBSYSTEMS` and `SMELLS` directly in the agent prompt so it can skip its own Steps 1–4 (subsystem + smell collection). Include the scope from `$ARGUMENTS`. Relay the agent's complete output to the user, then skip to the **[Pro] Cross-reference decisions** step.

---

## Phase 3 — Hotspot ranking (inline path only)

Run `ix rank` only if at least one of the following is true:
- A `god-module` smell exists in `SMELLS` (even on the inline path)
- Any region in `SUBSYSTEMS` has `coupling > 0.5`

```bash
ix rank --by dependents --kind class --top 10 --exclude-path test --format json
```

Identify the top-ranked components that overlap with smell findings or high-coupling regions. Include these as hotspots in the inline report.

If neither condition is met, skip `ix rank` entirely.

---

## Inline report format

When taking the inline path, produce:

**Summary** — one sentence verdict on overall health.

**Subsystem overview** — table of regions with cohesion, coupling, crosscut_score.

**Smells** — list each smell with affected symbol and severity.

**Hotspots** — (if Phase 3 ran) top-ranked components that coincide with smells or high-coupling regions.

**Recommended action** — one concrete next step.

---

## [Pro] Cross-reference decisions

If Pro is available, after the report (inline or delegated) is complete:
```bash
ix decisions --format json
```
Append a **Recorded Decisions** section cross-referencing relevant design decisions against the findings — especially decisions that affect god-modules, high-coupling regions, or identified hotspots.

## Save step

**Only if `SAVE_PATH` is non-empty (i.e., `--save` was passed):**
- Write the full output above to `SAVE_PATH` using the Write tool.
- Confirm to the user: `Saved to <SAVE_PATH>`.
- Do not write the file if `--save` was not passed.
