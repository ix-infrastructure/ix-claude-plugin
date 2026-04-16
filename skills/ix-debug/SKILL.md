---
name: ix-debug
description: Root cause analysis — trace execution path to a failure, narrow candidates, read minimal source only at suspected failure points.
argument-hint: <error message, symptom description, or name of failing function> [--save [path]]
---

> [ix-claude-plugin shared model](../shared.md)

Check `command -v ix` first. If unavailable, use Grep + Read as fallback.

## Argument parsing

Strip `--save` and any following path token from `$ARGUMENTS` before resolving the entry point.
- If `--save <path>` is present, set `SAVE_PATH` to that path.
- If `--save` is present without a path, auto-generate `ix-debug-<target-slug>.md` in cwd (target slug = the first symbol or first three words of the symptom with spaces and slashes replaced by `-`).
- If `--save` is absent, `SAVE_PATH` is empty — do not write a file.

## Pro check (optional)

Run once at the start:
```bash
ix briefing --format json 2>&1
```
If it returns JSON with a `revision` field, Pro is available. Extract `openBugs` and `recentDecisions` for use in Pro steps below. If it errors, skip all **[Pro]** labeled steps.

**[Pro]** If `openBugs` is non-empty, scan for a known bug matching this symptom before proceeding. If found, surface it immediately — an existing bug record may already have candidates or a fix.
**[Pro]** If `recentDecisions` is non-empty, scan for recent decisions or context that might explain the symptom or constrain the likely fix. Surface any relevant match before continuing.

## Goal

Answer: *where in the execution path is this likely failing, and why?* Stop once you have 1–3 root cause candidates with supporting evidence.

## Phase 1 — Locate the entry point (always)

```bash
ix locate $ARGUMENTS --format json
```

If `$ARGUMENTS` is a symptom description rather than a symbol name, also run:
```bash
ix text "$ARGUMENTS" --limit 10 --format json
```

Identify the most likely entry point (where the failure originates or first manifests).

## Phase 2 — Explain (always)

```bash
ix explain <entry-point> --format json
```

Extract: role, callers, callees, confidence. Identify whether this is:
- A **boundary** (external input, API, event) — failure likely from unexpected input
- An **orchestrator** — failure likely from wrong sequencing or state
- A **utility/helper** — failure likely from wrong assumptions by caller

**Stop if:** the explanation makes the failure source obvious → skip to Output.

## Phase 3 — Decide: inline or delegate

Use the Phase 1–2 results to choose the path:

- **Inline path (simple bug):** the likely failure is still within a single subsystem, confidence is `>= 0.7`, and the entry point is not an orchestrator with more than 10 callees → continue to Phase 4.
- **Delegate path (complex bug):** confidence is `< 0.7`, OR the entry point is an orchestrator with more than 10 callees → use the Agent tool with `subagent_type: "ix-memory:ix-bug-investigator"` and pass the pre-computed context below.

**You MUST pass pre-computed context so the agent skips redundant work.** Launch the agent with:

> Investigate: $ARGUMENTS
>
> **Pre-computed context (skip Steps 1–2):**
> Entry point: [symbol, subsystem, file — from Phase 1]
> Entity type: [boundary / orchestrator / utility — from Phase 2]
> Explain output: [paste `ix explain` result]
>
> Start from Step 3. The symptom is: [description]. The entry point classification suggests: [hint from Phase 2].

If the Agent tool is unavailable, continue inline through Phases 4–6, reduce breadth, preserve the 2-read cap, and surface uncertainty rather than over-reading.

## Phase 4 — Trace the execution path (inline path)

```bash
ix trace <entry-point> --downstream --format json
```

Walk the downstream path. At each step, look for:
- Functions that validate or transform state (potential incorrect assumptions)
- Cross-subsystem calls (where contracts might differ)
- Functions with high callee count (potential god functions, many failure points)

**Narrow:** Identify the 1–3 nodes most likely to contain the bug.

**Delegate if:** the trace crosses subsystem boundaries, reveals multiple plausible contract boundaries, or fans out widely enough that confidence drops below `0.7`. Use the Phase 3 delegation prompt and tell the agent to start from Step 3.

**Stop if:** trace reveals an obvious candidate on a mostly single-subsystem path → proceed to Phase 6.

## Phase 5 — Callers (inline path, if failure might come from upstream)

```bash
ix callers <entry-point> --limit 10 --format json
```

Check whether the fault is in how this is *called* rather than in its own logic.

## Phase 6 — Targeted code read (inline path, only at suspected failure points)

For each root cause candidate (max 2):
```bash
ix read <candidate-function> --format json
```

Read **the specific function only**. Look for:
- Edge cases in input handling
- Assumptions about state that might be violated
- Missing null/error checks
- Incorrect sequencing

**Hard limit:** 2 `ix read` calls maximum. If still ambiguous, surface the candidates and uncertainty to the user.

## Phase 7 — Synthesize

- If you delegated in Phase 3 or 4, present the agent's result directly. Do not re-run locate/explain/trace in the main thread.
- If you stayed inline, use the Output format below.
- If Pro is available and this is a new bug, append the bug-logging suggestion after the investigation output.

## Output

```
## Debug: [entry point]

**Execution path:**
[entry-point] → [step] → [step] → [suspected failure point]

**Root cause candidates:**
1. [function/file] — [reason: what assumption might be wrong]
2. [function/file] — [reason]

**Evidence:**
- [what graph data supports each candidate]
- [what code read revealed, if any]

**Confidence:** [high / medium / low] — [why]

**Next steps:**
- Add logging at [specific point] to confirm
- Check [specific edge case] in [function]
- Run `/ix-investigate <X>` to understand [unclear component] more deeply

**[Pro]** If this is a new bug, log it:
```
ix bug create "<symptom title>" --severity <low|medium|high|critical> --affects <entry-point>
```
(Omit if Pro unavailable or bug already tracked.)
```

**Save step (only if `SAVE_PATH` is non-empty):**
- Write the full output above to `SAVE_PATH` using the Write tool.
- Confirm to the user: `Saved to <SAVE_PATH>`.
- Do not write the file if `--save` was not passed.
