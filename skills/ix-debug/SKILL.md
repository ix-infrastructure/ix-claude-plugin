---
name: ix-debug
description: Root cause analysis — trace execution path to a failure, narrow candidates, read minimal source only at suspected failure points.
argument-hint: <symptom, failing function, or suspected component>
---

Check `command -v ix` first. If unavailable, use Grep + Read as fallback.

## Goal

Answer: *where in the execution path is this likely failing, and why?* Stop once you have 1–3 root cause candidates with supporting evidence.

## Phase 1 — Locate the entry point (always)

```bash
ix locate $ARGUMENTS --limit 5 --format json
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

## Phase 3 — Trace the execution path

```bash
ix trace <entry-point> --downstream --format json
```

Walk the downstream path. At each step, look for:
- Functions that validate or transform state (potential incorrect assumptions)
- Cross-subsystem calls (where contracts might differ)
- Functions with high callee count (potential god functions, many failure points)

**Narrow:** Identify the 1–3 nodes most likely to contain the bug.

**Stop if:** trace reveals an obvious candidate → proceed to Phase 5.

## Phase 4 — Callers (if failure might come from upstream)

```bash
ix callers <entry-point> --limit 10 --format json
```

Check whether the fault is in how this is *called* rather than in its own logic.

## Phase 5 — Targeted code read (only at suspected failure points)

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
```
