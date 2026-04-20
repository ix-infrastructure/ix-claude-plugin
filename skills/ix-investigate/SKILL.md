---
name: ix-investigate
description: Deep dive into a symbol, feature, or bug. Graph-first, minimal code reads, early stopping when sufficient evidence found.
argument-hint: <symbol, function name, or "how does X work?"> [--save [path]]
---

> [ix-claude-plugin shared model](../shared.md)

Check `command -v ix` first. If unavailable, use Grep + Read as fallback.

## Argument parsing

Strip `--save` and any following path token from `$ARGUMENTS` before resolving the target.
- If `--save <path>` is present, set `SAVE_PATH` to that path.
- If `--save` is present without a path, auto-generate `ix-investigate-<target-slug>.md` in cwd (target slug = the target with spaces and slashes replaced by `-`).
- If `--save` is absent, `SAVE_PATH` is empty — do not write a file.

## Pro check (optional)

Run once at the start:
```bash
ix briefing --format json 2>&1
```
If it returns JSON with a `revision` field, Pro is available. Extract `recentDecisions` and `openBugs` for use in Pro steps below. If it errors, skip all **[Pro]** labeled steps.

## Goal

Answer: *what is this, how does it connect, and what's the execution path?* Stop as soon as those three questions can be answered accurately.

## Phase 1 — Locate (always)

```bash
ix locate $ARGUMENTS --format json
```

If multiple matches: use `--kind`, `--path`, or `--pick N` to resolve. Do not proceed until the entity is unambiguous.

If `ix locate` returns nothing: try `ix text $ARGUMENTS --limit 10 --format json`.

## Phase 2 — Explain (always)

```bash
ix explain <resolved-symbol> --format json
```

Extract: role, importance, caller count, callee count, confidence score.

If the resolved entity is a **class or module**, also run:
```bash
ix overview <resolved-symbol> --format json
```
This reveals internal structure (members, sub-components) without reading source.

**Orphan check:** If `fan_in = 0` AND `fan_out = 0` in the `ix explain` output:
- Report: "Symbol is a graph orphan — no detected dependencies. Either the graph needs a refresh (`ix map`) or the file has no parseable import/call relationships."
- Suggest `ix map <file>` as first step.
- Stop here — skip Phases 3–5 unless the user specifically asks for source-level inspection.

**Evaluate:** Is the explanation sufficient to answer the question?

**Stop if:** explain gave clear role, purpose, and connection summary → skip to Output.

## Phase 3 — Connections (run only if caller/callee detail needed)

Run only the directions you need — not both by default:

```bash
# If "who uses this" matters:
ix callers <symbol> --limit 15 --format json

# If "what does this do internally" matters:
ix callees <symbol> --limit 15 --format json
```

**Stop if:** you now know who uses it and what it depends on.

## Phase 4 — Trace (run only if execution flow is unclear)

```bash
ix trace <symbol> --depth 2 --format json
```

One trace only. Pick the most representative direction (`--upstream` or `--downstream`) based on the question.

**Stop if:** execution path is now clear.

## Phase 5 — Code read (last resort only)

Only if the above steps leave a specific implementation question unanswered:
```bash
ix read <symbol> --format json
```

Read **the symbol only** — never the full file. If the symbol is a class, read the specific method suspected.

**Hard limit:** One `ix read` call maximum. If still unclear after reading, surface the ambiguity to the user rather than reading more.

## Phase 6 — Design context **[Pro]**

If Pro is available and `recentDecisions` from the briefing is non-empty, check for decisions affecting this symbol:
```bash
ix decisions --topic <resolved-symbol> --format json
```
Include any relevant decisions in the output under **Design context**.

## Output

```
## [Symbol] — Investigation

**What it is:** [kind, file, subsystem — from graph]
**Role:** [orchestrator / boundary / helper / utility / etc.]

**Execution flow:**
[downstream: what it calls → what those call, 2 levels max]
[upstream: who calls it, top 5]

**Key connections:**
- Depends on: [top 3 callees]
- Used by: [top 3 callers with their subsystem]

**Design context:** [Pro only — relevant recorded decisions, or omit section if none]

**Evidence quality:** [strong / partial / uncertain] — [one-line reason]

**Next step:**
- [most useful follow-up based on findings]
```

If confidence < 0.7 in ix output, label those claims as `[uncertain]` and recommend `ix map` to refresh.

**Save step (only if `SAVE_PATH` is non-empty):**
- Write the full output above to `SAVE_PATH` using the Write tool.
- Confirm to the user: `Saved to <SAVE_PATH>`.
- Do not write the file if `--save` was not passed.
