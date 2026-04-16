# ix-claude-plugin — Complete Technical Reference

> Version 2.3.0 | Self-contained reference for AI assistants

---

## What Is It?

ix-claude-plugin is a plugin for Claude Code (Anthropic's CLI coding assistant)
that connects it to Ix Memory — a persistent code knowledge graph server. Together
they form a "graph-reasoning engineering agent."

The core idea: Claude queries a structured graph of your codebase first — functions,
classes, imports, call relationships, architectural regions — and only reads actual
source files as a last resort, at symbol level, never whole files. This minimizes
token usage while maximizing analysis accuracy.

---

## Three-Layer Architecture

```
Layer 1 — Ix Graph        structured memory: persistent knowledge graph of code
Layer 2 — Claude          reasoning engine: interprets, synthesizes, decides
Layer 3 — Skills/Agents   cognitive abstractions: multi-phase reasoning over the graph
```

The graph stores nodes (files, functions, classes, interfaces, modules, regions) and
edges (CALLS, IMPORTS, CONTAINS, EXTENDS, REFERENCES, DEPENDS_ON, IN_REGION). Claude
uses graph queries to understand structure and relationships without reading source.

---

## The ix CLI — What Each Command Does

These are the commands Claude (and the hooks/skills) use to query the graph. All
support `--format json` for machine-readable output.

### Discovery / Architecture

| Command | What it does |
|---------|-------------|
| `ix subsystems` | Returns all architectural regions with cohesion, coupling, confidence, crosscut_score, file count. This is the primary "shape of the codebase" command. Uses cached data — does not re-cluster. |
| `ix subsystems --list` | Same but returns just the health/score list per subsystem. |
| `ix subsystems <name> --explain` | Explains a specific subsystem's purpose and boundaries. |
| `ix stats` | Returns total node and edge counts broken down by kind (function, class, module, file, interface, etc.) and edge predicate (CALLS, IMPORTS, CONTAINS, etc.). Used to understand codebase scale. |
| `ix overview <name>` | High-level summary of a file or module: key entities it defines, child components, confidence score, and structural role. Does not read source. |
| `ix inventory` | Lists entities by kind and/or path. Options: `--kind <function|class|file|...>`, `--path <dir>`, `--limit N`. Used to enumerate what's in a directory or of a given type. |

### Symbol Operations

| Command | What it does |
|---------|-------------|
| `ix locate <symbol>` | Finds where a symbol is defined. Returns resolved target (name, kind, file path, confidence) or a list of candidates if ambiguous. Use `--kind`, `--path`, or `--pick N` to disambiguate. Falls back to text search if nothing found. |
| `ix explain <symbol>` | Returns the symbol's role in the graph: kind, importance tier, category, caller count (fan_in), callee count (fan_out), confidence, key relationships, subsystem. This is the primary "what is this?" command. |
| `ix read <symbol>` | Returns only that symbol's source code (not the whole file). Used as a last resort when graph data is insufficient. Symbol-level only — never file-level unless the file itself is the subject. |
| `ix contains <symbol>` | Lists members of a class or module (methods, fields, sub-components). |

### Call Graph

| Command | What it does |
|---------|-------------|
| `ix callers <symbol> --limit N` | Returns all symbols that call this one. Shows who depends on it. Cap at `--limit 15`. |
| `ix callees <symbol> --limit N` | Returns all symbols this one calls. Shows what it depends on. Cap at `--limit 15`. |
| `ix trace <symbol>` | Traces the call chain downstream or upstream. Options: `--downstream` (what it calls, transitively), `--upstream` (who calls it, transitively), `--to <symbol>` (path between two symbols), `--depth N`. Use `--depth 2` max unless deeper is explicitly needed. One trace per investigation. |
| `ix depends <symbol> --depth 2` | Returns the upstream dependency tree (what this symbol depends on, up to depth N). Similar to callees but includes transitive deps. |
| `ix imported-by <path>` | Returns all files that import a given path/module. Useful for blast radius analysis on modules, not just symbols. |
| `ix imports <symbol>` | Returns what a symbol or file imports. |

### Impact / Risk

| Command | What it does |
|---------|-------------|
| `ix impact <target>` | Blast radius analysis for a file or symbol. Returns: riskLevel (low/medium/high/critical), directDependents count, memberLevelCallers count, topImpactedMembers, riskSummary, atRiskBehavior, nextStep. The primary "is it safe to change this?" command. |

### Search

| Command | What it does |
|---------|-------------|
| `ix text <pattern> --limit N` | Full-text search across the codebase. Returns file paths and matched lines. Cap at `--limit 20`. Used when a symbol cannot be located by name, or to confirm where a string appears. |

### Health / Smells

| Command | What it does |
|---------|-------------|
| `ix smells` | Returns code smells detected in the graph: orphan (files with no connections), god-module (files with too many chunks or extreme fan-in/out), weak-component (loosely connected files). Always repo-wide — filter by path prefix after retrieval if you want a scoped view. |
| `ix rank --by <metric> --kind <kind> --top N --exclude-path test` | Ranks entities by a structural metric. `--by` options: dependents, callers, importers, members. `--kind` options: class, function, file, module, interface. Both flags are required — the command errors without them. Always use `--exclude-path test` to avoid test noise. Cap at `--top 10`. |

### Graph Management

| Command | What it does |
|---------|-------------|
| `ix map` | Builds or refreshes the full code graph by parsing the current working directory. Expensive — runs async after edits. Do not run for exploration; use `ix subsystems` instead (reads cached data). |
| `ix map <file>` | Updates the graph for a single file. Runs after Claude edits a file to keep the graph current. |
| `ix status` | Health check — returns whether the ix server is running and reachable. Slow (6s+) — hooks avoid it and instead rely on commands failing fast. |
| `ix connect` | Connects Claude Code to a running ix server. |

### Pro-Only Commands

These require Ix Pro. Skills check by running `ix briefing --format json` and looking
for a `revision` field. If absent, all Pro steps are skipped gracefully.

| Command | What it does |
|---------|-------------|
| `ix briefing --format json` | Returns session context: activeGoals, activePlans, openBugs, recentDecisions, recentChanges. Injected by ix-briefing.sh hook once per 10 minutes. |
| `ix decisions` | Returns recorded architectural decisions. Used by ix-investigate, ix-debug, ix-architecture to surface relevant past decisions. |
| `ix bugs` | Lists open bug records. Used by ix-debug and ix-impact to check if any known bugs touch the blast radius. |
| `ix bug create "<title>" --severity <level> --affects <symbol>` | Creates a new bug record. ix-debug suggests this at the end of an investigation for new bugs. |
| `ix plans` | Lists active implementation plans. Used by ix-plan and ix-safe-refactor-planner to avoid duplicate work. |
| `ix plan create "<title>" --goal <id>` | Creates a new plan to track a change set. |
| `ix goals` | Lists active development goals. Used by ix-plan to contextualize planned changes. |

---

## Component 1 — Hooks (Automatic, Invisible)

Hooks are bash scripts that fire on Claude Code lifecycle events via the Claude Code
hook system. They inject graph-aware context into Claude's context window **before**
operations run. Claude still performs the original operation — hooks only add context.

All hooks:
- Bail silently if `ix` is not in PATH or the server is unreachable
- Produce compact one-line summaries (never raw JSON dumps)
- Use TTL caches to avoid redundant queries
- Output `{"additionalContext": "..."}` to inject context, or nothing to no-op

Hook registry (`hooks/hooks.json`):
```
UserPromptSubmit            → ix-briefing.sh      (10s timeout)
PreToolUse(Grep|Glob)       → ix-intercept.sh     (10s timeout)
PreToolUse(Read)            → ix-read.sh          (8s timeout)
PreToolUse(Bash)            → ix-bash.sh          (10s timeout)
PreToolUse(Edit|Write|MultiEdit) → ix-pre-edit.sh (10s timeout)
PostToolUse(Edit|Write|MultiEdit|NotebookEdit) → ix-ingest.sh (async, 30s)
Stop                        → ix-map.sh           (async, 60s)
```

---

### ix-briefing.sh — UserPromptSubmit

Fires at the start of each user prompt. Requires Ix Pro — is a complete no-op
otherwise.

- 10-minute TTL cache (`/tmp/ix-briefing-cache`). Skips if briefing was injected
  within the last 10 minutes.
- Calls `ix briefing --format json`
- Injects: `[ix] Session briefing: <json>` containing activeGoals, activePlans,
  openBugs, recentDecisions
- Gives Claude standing context about what's being worked on before any reasoning
  begins

---

### ix-intercept.sh — PreToolUse(Grep|Glob)

Fires before any Grep or Glob tool call. Runs graph queries in parallel and injects
a one-line context summary so Claude has graph-aware knowledge before the native
tool runs. The native tool still runs afterward.

**Grep path:**
1. Extracts pattern from tool input. Skips if < 3 chars.
2. Runs `ix text <pattern> --limit 15` and `ix locate <pattern>` in parallel
   (background processes via `&`, then `wait`)
3. Graph confidence gate from locate result:
   - confidence < 0.3 → drops symbol data, keeps text hits only
   - confidence < 0.6 → prepends `⚠ Graph confidence low (N)` warning
4. Injects one-line summary:
   `[ix] 'pattern' — symbol: Name (kind, file.ts) | N text hits in a.ts, b.ts (+M more)`

**Glob path:**
1. Extracts path from tool input
2. Runs `ix inventory --format json --path <path>`
3. Injects: `[ix] glob 'pattern' in dir: N entities — Name1, Name2, ...`

---

### ix-read.sh — PreToolUse(Read)

Fires before Claude reads a file. Injects a summary of what's in the file and
whether it's risky to modify.

**Skips entirely for:**
- Binary/generated/vendor files (.png, .pdf, node_modules, dist, generated, __pycache__)
- Lock files (package-lock.json, yarn.lock, go.sum, Cargo.lock, pnpm-lock.yaml)

**Skips ix impact for:**
- Test/spec/mock files
- Config files (.yaml, .yml, .toml, .ini, .env, tsconfig, jsconfig)
- Files under 50 lines (impact meaningless at that scale)

**Per-file TTL cache (5 minutes):** Hashes the file path, stores timestamp in
`/tmp/ix-read-cache/<hash>`. Skips re-injection if the same file was processed
in the last 5 minutes.

**Runs in parallel:**
- `ix inventory --kind file --path <filename> --format json`
- `ix overview <filename> --format json`
- `ix impact <filename> --format json` (unless SKIP_IMPACT is set)

**Confidence gate (from ix overview):**
- confidence < 0.3 → exit 0, inject nothing
- confidence < 0.6 → prepend `⚠ Graph confidence low (N)` warning

**Injects:** `[ix] filename.ts — key: ClassA, fnB, fnC (2 methods, 1 class) | ⚠️ HIGH RISK: 47 dependents | Use ix read <symbol> for symbol source`

---

### ix-bash.sh — PreToolUse(Bash)

Fires before any Bash tool call. Only activates if the command starts with `grep`
or `rg`.

1. Extracts search pattern via sed (handles quoted strings, flags, bare patterns)
2. Skips if pattern < 3 chars
3. Runs `ix text + ix locate` in parallel (same logic as ix-intercept.sh)
4. Injects: `[ix] bash grep intercepted for 'pattern' — symbol: ... | N hits | Prefer: ix text 'pattern' or ix locate 'pattern' over shell grep`

---

### ix-pre-edit.sh — PreToolUse(Edit|Write|MultiEdit)

Fires before Claude edits or creates a file. Warns about blast radius.

**Skips for:** .md, .txt, .lock, binary files, compiled artifacts (.pyc, .class, .o)

1. Runs `ix impact <filename> --format json`
2. Uses whichever is higher: directDependents vs memberLevelCallers
3. Only warns when: risk level is medium/high/critical AND effective dependents ≥ 3
   (low risk and leaf files produce no noise)

**Warning format by risk level:**
```
critical → [ix] ⚠️ CRITICAL EDIT — file.ts has N dependents. <riskSummary>
            Hot spots: A, B, C. → <nextStep>
high     → [ix] ⚠️ HIGH-RISK EDIT — ...
medium   → [ix] NOTE — ...
```

The edit still proceeds. This is informational only.

---

### ix-ingest.sh — PostToolUse(Write|Edit|MultiEdit|NotebookEdit)

Fires after Claude modifies a file. Runs async (does not block Claude's response).

1. Runs `ix map <file_path>` with one automatic retry on failure
2. On success: injects `[ix] Graph updated — mapped: <path>`
3. Keeps the graph current so the next query reflects the changed file

---

### ix-map.sh — Stop hook

Fires after Claude finishes each response. Runs async via `nohup ... & disown`.

- Runs `ix map` (full graph refresh) in the background
- Ensures the next session or prompt starts with an up-to-date graph
- Does nothing visible — no additionalContext injected

---

### Shared Library (hooks/ix-lib.sh)

Sourced by all hooks via `hooks/lib/index.sh` (barrel file that sources both
ix-errors.sh and ix-lib.sh in one call, creating a single import hub for the graph).

**ix_health_check()**
- 300-second TTL cache in `/tmp/ix-healthy`
- Marks the last time ix was confirmed reachable
- Does NOT run `ix status` (which takes 6s+ and would reliably timeout 10s hooks)
- Relies on ix commands failing fast if the server is down

**ix_check_pro()**
- TTL tied to health check timestamp
- Caches pro availability in `/tmp/ix-pro`
- Exits the calling hook with 0 if Pro is not available
- Must be called after ix_health_check

**parse_json(raw)**
- Strips ix "Update available" header noise (anything before the first `[` or `{`)
- Extracts the first JSON array or object via `awk + jq`

**ix_run_text_locate(pattern, [path], [lang])**
- Runs `ix text` and `ix locate` in parallel (background processes)
- Sets globals `_TEXT_RAW` and `_LOC_RAW`
- Only runs `ix locate` for plain-string patterns (skips regex to avoid locate errors)
- Captures errors to ix_capture_async if either command fails

**ix_summarize_text(raw)**
- Parses text results, sets global `TEXT_PART`
- Format: "N text hits in a.ts, b.ts, c.ts (+M more)"

**ix_summarize_locate(raw)**
- Parses locate results, sets global `LOC_PART`
- Format if resolved: "symbol: Name (kind, file.ts)"
- Format if ambiguous: "candidates: A (fn), B (class), C (fn)"

---

### Error Logging (hooks/ix-errors.sh)

All hooks use `ix_capture_async` to log failures locally. No data is sent externally.

- Error store: `~/.local/share/ix/plugin/errors/errors.jsonl`
- Controlled by `IX_ERROR_MODE` env var: `local` (default) or `off`
- Errors are captured in a background subshell (fire-and-forget, never blocks hooks)
- Automatically redacts: Bearer tokens, GitHub tokens (ghp_), API keys (sk-...), TOKEN=, home directory path
- Normalizes errors to stable fingerprints (numbers → N, paths stripped) for deduplication
- View recent errors: `bash hooks/ix-report.sh`
- Each entry is a JSONL record: `{ts, fp, type, component, message, command, exit_code, stderr}`

---

## Component 2 — Skills (User-Invocable Slash Commands)

Skills are markdown "reasoning protocol" files. Each defines multi-phase reasoning
with explicit stop conditions, token budgets, and delegation logic. They are not
CLI aliases — they infer intent and stop as soon as the question is answered.

**Universal rules across all skills:**
1. Graph-first: `ix locate → ix explain → ix trace/callers/callees → ix impact → ix read`
2. Stop early: evaluate "can I answer now?" at each phase boundary
3. Scale depth with risk: low-risk targets get fewer queries
4. No raw JSON: produce ranked findings + reasoning + confidence + next step
5. Label every claim: `[graph]` = from graph query, `[inferred]` = Claude's synthesis
6. Symbol-level reads only: never read whole files
7. Fall back to Grep + Read if `ix` is unavailable

**Token budget (hard limits):**
```
Text search:       --limit 20
Symbol rank:       --top 10, always --exclude-path test
Callers/callees:   --limit 15
Dependency tree:   --depth 2 max
Traces:            1 per investigation, --depth 2 max
Code reads:        max 2 per task, symbol-level only
```

---

### /ix-understand [target] [--shallow|--medium|--deep]

**Purpose:** Build a mental model of a system or the whole repo.

**Argument:** Optional target (subsystem name, file path). Empty = whole repo.

**Phase 1 — Orient (always, run in parallel):**
```
ix subsystems --format json
ix subsystems --list --format json
ix rank --by dependents --kind class --top 15 --exclude-path test --format json
ix rank --by callers --kind function --top 15 --exclude-path test --format json
ix stats --format json
```
Extracts: all top-level systems with cohesion/coupling/confidence, top 10-15
structurally important classes and functions, codebase scale (files, nodes, edges).

Confidence check on subsystems results:
- confidence < 0.5 → add caveat to output header
- confidence < 0.3 → report fuzzy boundary as explicit finding, label all claims `[uncertain]`

**Depth routing:**

`--shallow` (default): Synthesize from Phase 1 data only. No agents. Produces a
subsystem map table, top classes/functions lists, and a 1-2 sentence health
assessment. Suggests `--medium` or `--deep` for more detail.

`--medium`: Launch a SINGLE `ix-system-explorer` agent regardless of system count.
Pass pre-computed Phase 1 results so the agent skips Step 1. Ask for breadth-first
coverage (one level per subsystem). Present agent output directly.

`--deep`:
- Phase 2: Count significant systems (file count ≥ 10 OR confidence ≥ 0.5)
  - ≤ 3 significant systems → single ix-system-explorer agent (Phase 3A)
  - > 3 significant systems → parallel agents, one per system (Phase 3B)
- Phase 3A (single agent): Full comprehensive architectural document, go wide AND deep.
  Covers subsystem internals, type system, data flows (ASCII), key components (up to 15),
  build/test infra, coupling, risks, navigation shortcuts.
- Phase 3B (parallel agents): ALL agents launched in a single message.
  Each per-system agent gets: purpose, internal structure table, key types, top 3-5
  components with `ix explain`, primary data flow (ASCII), external coupling, risks.
  Plus one additional cross-cutting agent for: shared types, cross-system flows,
  infrastructure services, god-modules, navigation shortcuts.
- Phase 4 (synthesis — main thread only): Assemble final document from all agent
  outputs. Do NOT proceed until all agents have returned. Merge: system map,
  per-subsystem sections, core abstractions, data flows, key components table (top 15),
  build infra, coupling, risk areas (security/complexity/data integrity), navigation
  shortcuts, where to go deeper, selective reference.

**Read budget:** 0 for skills — all reads delegated to agents (max 2 each).

---

### /ix-investigate <symbol>

**Purpose:** Deep dive into one symbol — what it is, how it connects, execution path.

**Phase 1 — Locate (always):**
`ix locate $ARGUMENTS --format json`
Resolve ambiguity with `--kind`, `--path`, or `--pick N`. Fall back to
`ix text $ARGUMENTS --limit 10` if locate returns nothing.

**Phase 2 — Explain (always):**
`ix explain <resolved-symbol> --format json`
Also run `ix overview <resolved-symbol>` if it's a class or module (reveals internal
structure without reading source).

Orphan check: if `fan_in = 0 AND fan_out = 0` → report graph orphan, suggest
`ix map <file>`, stop (skip phases 3-5).

Early stop: if explain answers the question, skip to output.

**Phase 3 — Connections (only if caller/callee detail needed):**
Run only the relevant direction:
```
ix callers <symbol> --limit 15 --format json   (if "who uses this" matters)
ix callees <symbol> --limit 15 --format json   (if "what does it call" matters)
```
Stop if you now know who uses it and what it depends on.

**Phase 4 — Trace (only if execution flow is still unclear):**
`ix trace <symbol> --format json`
One trace only. Pick the most relevant direction (--upstream or --downstream).

**Phase 5 — Code read (last resort only):**
`ix read <symbol> --format json`
Read the symbol only — never the full file. Hard limit: one `ix read` call.
If still unclear, surface ambiguity to user rather than reading more.

**Phase 6 — Design context [Pro]:**
If Pro available and `recentDecisions` is non-empty:
`ix decisions --topic <resolved-symbol> --format json`
Include relevant decisions in output under "Design context."

**Output:** What it is (kind, file, subsystem), role (orchestrator/boundary/helper/
utility), execution flow (downstream: what it calls, 2 levels; upstream: top 5 callers),
key connections (top 3 depends-on, top 3 used-by), design context (Pro), evidence
quality (strong/partial/uncertain), next step.

**Read budget:** 1 max.

---

### /ix-impact <target>

**Purpose:** Change risk analysis — blast radius, affected systems, what to test.

**Phase 1 — Risk score (always, run in parallel):**
```
ix impact  $ARGUMENTS --format json
ix explain $ARGUMENTS --format json
```
God-module check: if `fan_out > 20 AND fan_in < 2` → warn that blast-radius metrics
understate risk; check callers of key dependencies, not just direct dependents.

Risk classification → action:
- `low` + < 3 dependents → **STOP** — safe to proceed, report and suggest verification
- `medium` OR 3-10 dependents → Phase 2
- `high`/`critical` OR > 10 dependents → Phase 2 + 3

**Phase 2 — Callers and dependents (medium/high/critical, run in parallel):**
```
ix callers $ARGUMENTS --limit 20 --format json
ix depends $ARGUMENTS --depth 2 --format json
```
Extract direct callers by name and subsystem, transitive count.
Stop here if risk is `medium`.

**Phase 3 — Import chain and subsystem spread (high/critical only):**
`ix imported-by $ARGUMENTS --format json`
Cross-reference callers + dependents + importers to identify:
- Which subsystems are in the blast radius
- Whether the change crosses an architectural boundary
- Any tests that cover the affected paths

**Phase 4 — Known bugs [Pro]:**
If Pro available and `openBugs` non-empty:
`ix bugs --format json`
Cross-reference open bugs against direct callers/dependents. Any matching open bug
escalates the risk verdict.

**Output:** Risk level, verdict (SAFE/REVIEW CALLERS FIRST/NEEDS CHANGE PLAN),
blast radius (direct, transitive depth 2, subsystems), key callers (top 5 with
subsystem), at-risk behaviors, recommended action, known bugs (Pro).

**Read budget:** 0 — purely graph-based.

---

### /ix-plan <targets...>

**Purpose:** Risk-ordered implementation plan for a set of changes.

**Phase 1 — Scope (always):**
If `$ARGUMENTS` contains symbol names, proceed.
If it's a description, first run:
```
ix text "$ARGUMENTS" --limit 10 --format json
ix locate "$ARGUMENTS" --format json
```
Identify 1-4 most relevant symbols as targets.

**Phase 2 — Impact per target (parallel):**
For each target simultaneously:
```
ix impact  <target> --format json
ix callers <target> --limit 10 --format json
```
Rank targets: critical > high > medium > low.

Fast path: if ALL targets are low risk AND < 3 dependents → skip phases 3-5,
output "SAFE — all targets low risk."

Delegation gate: check for high complexity:
1. Any target has dependents > 20?
2. Any non-low-risk target's region has coupling > 5 (from `ix subsystems`)?
If either → spawn `ix-safe-refactor-planner` agent with TARGETS + RISK_TABLE +
SUBSYSTEMS pre-filled (agent skips its own Steps 1-3). Otherwise continue inline.

**Phase 3 — Data flow (only if 2+ targets AND at least one is medium/high/critical):**
`ix trace <highest-risk-target> --to <second-target> --format json`
Reveals whether targets form a pipeline (must change in order) or are independent.

**Phase 4 — Shared dependents (only if high/critical targets exist):**
`ix depends <highest-risk-target> --depth 2 --format json`
Identifies symbols that depend on multiple targets — highest testing priority.

**Phase 5 — Project context [Pro]:**
```
ix plans --format json
ix goals --format json
```
Cross-reference activePlans to avoid duplicate work. Note which activeGoal this serves.
Suggest `ix plan create "<title>"` if no existing plan covers this work.

**Output:** Targets & Risk table, Change Order (numbered sequence with reason for each
position), Data Flow, Shared Risk, Test Checkpoints (after each target: verify these
callers), Red Flags, Project context (Pro).

**Read budget:** 1 (only if a target's role is unclear after graph).

---

### /ix-debug <symptom>

**Purpose:** Root cause analysis — trace execution path to failure candidates.

**Pro check [Pro]:**
If Pro available and `openBugs` non-empty → scan for known bug matching this symptom
before proceeding. If found, surface it immediately.
If `recentDecisions` non-empty → scan for context that might explain the symptom.

**Phase 1 — Locate the entry point (always):**
`ix locate $ARGUMENTS --format json`
If $ARGUMENTS is a description rather than a symbol:
`ix text "$ARGUMENTS" --limit 10 --format json`
Identify the most likely entry point (where the failure originates or first manifests).

**Phase 2 — Explain (always):**
`ix explain <entry-point> --format json`
Classify the entity type:
- Boundary (API handler, event listener, input validator) → failure from unexpected input
- Orchestrator (service, coordinator, pipeline) → failure from wrong sequencing/state
- Utility/helper (pure function, transformer) → failure from wrong assumptions by caller

Stop if explanation makes the failure source obvious.

**Phase 3 — Decide: inline or delegate:**
- Inline path: single subsystem, confidence ≥ 0.7, entry point is NOT an orchestrator
  with more than 10 callees → continue to Phase 4.
- Delegate path: confidence < 0.7, OR cross-subsystem, OR orchestrator with > 10
  callees → spawn `ix-bug-investigator` agent with pre-computed Phase 1-2 context.

**Phase 4 — Trace (inline path):**
`ix trace <entry-point> --downstream --format json`
Walk downstream call chain. Flag: state validation/transformation nodes, cross-subsystem
calls (contract violation candidates), high-callee-count functions (god functions).
Narrow to 1-3 most suspicious nodes.
If trace crosses subsystem boundaries or fans out widely → delegate to agent (Phase 3 prompt).

**Phase 5 — Callers (inline path, if failure might come from upstream):**
`ix callers <entry-point> --limit 10 --format json`
Check whether the fault is in how this is called rather than its own logic.

**Phase 6 — Targeted code read (inline path, max 2 calls):**
`ix read <candidate-function> --format json`
Read the specific function only. Look for: edge cases, state assumption violations,
missing null/error checks, incorrect sequencing.
Hard limit: 2 reads. If still ambiguous, surface candidates and uncertainty to user.

**Phase 7 — Synthesize:**
If delegated: present agent result directly. Do not re-run locate/explain/trace.
If inline: use the output format below.
If Pro available and this is a new bug, append: `ix bug create "<title>" --severity N --affects <symbol>`

**Output:** Execution path (entry → step → step → suspect), Root cause candidates
(1-3 with hypothesis, evidence, confidence), What to verify next, Uncertainty.

**Read budget:** 2 max (only at suspected failure points).

---

### /ix-architecture [scope]

**Purpose:** Design health — coupling, cohesion, smells, hotspots. Never reads source.

**Health gate (first):**
Check `command -v ix` and `ix status`. If either fails, stop.
Then `ix subsystems --list --format json` — if empty, stop and say to run `ix map` first.

**Pro check:** Extract `recentDecisions` if Pro available.

**Phase 1 — Subsystem structure:**
`ix subsystems --format json`
Filter to `$ARGUMENTS` scope if provided. Store as SUBSYSTEMS.

Early-stop gate: if ALL regions have cohesion > 0.7, coupling < 0.4,
crosscut_score ≤ 0.1, confidence ≥ 0.6 → report "structurally healthy," list metrics, stop.

**Phase 2 — Smell analysis:**
`ix smells --format json`
Filter to scope. Store as SMELLS.

Health gate — choose path:
- Inline path (all must be true): smell count < 3, no god-module, no crosscut > 0.1
  → synthesize report inline using SUBSYSTEMS + SMELLS
- Delegate path (any is true): smell count ≥ 3, OR god-module present, OR crosscut > 0.1
  → spawn `ix-architecture-auditor` with SUBSYSTEMS + SMELLS pre-filled
    (agent skips its own Steps 1-4)

**Phase 3 — Hotspot ranking (inline path only, conditional):**
Run `ix rank` only if: a god-module smell exists, OR any region has coupling > 0.5.
```
ix rank --by dependents --kind class --top 10 --exclude-path test --format json
```
Skip entirely if neither condition is met.

**[Pro] Cross-reference decisions (after any path completes):**
`ix decisions --format json`
Append "Recorded Decisions" section cross-referencing design decisions against findings.

**Inline output:** Summary verdict, subsystem overview table (cohesion, coupling,
crosscut_score), smells list (each with affected symbol and severity), hotspots
(top-ranked components that coincide with smells or high-coupling regions),
recommended action.

**Read budget:** 0 — purely graph-based.

---

### /ix-docs <target> [--full] [--style narrative|reference|hybrid] [--split] [--single-doc] [--out <path>]

**Purpose:** Generate narrative-first, importance-weighted documentation to disk.

**Goal:** Help a new engineer understand the system quickly AND give an LLM strong
architectural context without drowning it in low-value detail.

**Flag parsing:**
- First non-flag token = TARGET (required — stops and asks if missing)
- `--full` → FULL=true (default: false)
- `--style narrative|reference|hybrid` → STYLE (default: narrative)
- `--split` → SPLIT=true (default: false)
- `--single-doc` → forces one file (overrides auto-split)
- `--out <path>` → OUT_PATH
- If FULL=true and repo has > 10 subsystems: auto-enables SPLIT

**Output path auto-detection:**
1. `docs/` exists at workspace root → `docs/<target>.md` or `docs/<target>/`
2. `doc/` exists → `doc/<target>.md` or `doc/<target>/`
3. Otherwise → `<target>.md` or `<target>/` at workspace root

**Style modes:**
- `narrative` (default): prose-first, compact reference layer
- `reference`: tighter docs-site structure, briefer narrative
- `hybrid`: full narrative + fuller reference — best with `--full`

**Two-layer output model:**
1. Narrative layer (always first): human-readable explanation, onboarding-focused,
   architecture, flow, usage, risks, navigation guidance
2. Reference layer (always present but selective): important modules/classes,
   short structured entries, no code dumping

**Non-negotiable rules:**
- Graph first: subsystems, overview, rank, explain before any ix read
- Importance-weighted: expand by centrality, risk, coupling, orchestration role — never treat all modules equally
- No raw dumps: never output raw JSON, command logs, full file inventories
- No redundancy: group repeated patterns, explain each entity once
- Code reads are rare: default mode max 2 `ix read` calls; full mode max 5
  (symbol-level only)

**Coverage policy — what to include:**
- Always: top-level architecture, all major subsystems in scope, most important modules
- Sometimes: important files, key classes/services, notable boundary functions
- Only in --full: selective method summaries for top classes, expanded per-subsystem coverage
- Never: exhaustive inventories, equal treatment for all modules, long method lists

**Phase 1 — Scope:**
```
ix stats --format json
ix subsystems --format json
ix subsystems --list --format json
ix briefing --format json 2>&1   (Pro check + activeGoals/recentDecisions)
```
If TARGET is not the whole repo: `ix locate "$TARGET" --format json`
Resolve target type: repo, top-level system, subsystem, module/file, class/symbol.

**Parallel agent dispatch (large/full-mode runs only):**
Triggers when: FULL=true AND target is repo or top-level system with > 5 subsystems.
Check if subsystem/rank data is already in context from a prior /ix-understand run
in this session — if so, skip those Phase 1 commands.

Step 1 — Per-system agents: from Phase 1 rank results, select top 5 systems by
importance. For each, spawn one `ix-system-explorer` agent asking for: internal
module structure and responsibilities, most important/coupled components, main
execution flows within the subsystem, outbound dependencies and shared interfaces.

Step 2 — Cross-cutting agent: spawn one `ix-system-explorer` agent for cross-system
concerns only — shared types, cross-system flows, infrastructure services, god-modules.
Explicitly told NOT to explore individual subsystems.

Do NOT wait for agents — continue running Phase 2 commands while they work.

Step 3 — Synthesis: per-system outputs → narrative sections and per-system files
(split mode); cross-cutting output → Section 5 and index.md cross-system sections;
graph data wins on conflict; failures noted in Coverage header, not retried.

**Phase 2 — Architecture:** `ix overview`, `ix rank --by dependents`, `ix rank --by callers`
**Phase 3 — Behavior:** `ix explain` for top 3-5 entities; one `ix trace` only if flow unclear
**Phase 4 — Relationships:** `ix callers`, `ix callees`, `ix depends --depth 2`
  (skip these at repo scope — not meaningful; run on top 3-5 boundary components instead)
**Phase 5 — Risk:** `ix impact` on target (skip at repo scope; run on top 3-5 high-centrality entities)
**Phase 6 — Health:** `ix smells`; [Pro] `ix decisions`
**Phase 7 — Optional reads:** `ix read <symbol>` only if graph left important behavior unclear

**Split output structure:**
```
<OUT_DIR>/
  index.md                    (overall overview, cross-system flows, links)
  <system-1>.md               (full narrative for that system)
  <system-2>.md
  <lower-ranked>-stub.md      (one-para overview, top 3 components, one risk note)
```

**Read budget:** 2 reads inline; each agent has its own budget of 2.

---

## Component 3 — Agents (Autonomous Sub-Agents)

Agents are spawned by skills for complex work that benefits from parallelism or
isolation. Key contracts:

- Only the main conversation thread may spawn agents — no agent-spawning-agents
- Always receive pre-computed orient data — never sent to repeat already-done work
- Max 2 `ix read` calls per agent
- Return structured summaries only, never raw data dumps
- Every claim labeled `[graph]` or `[inferred]`
- Include: ranked findings, reasoning, confidence, next step

---

### ix-system-explorer

**Purpose:** Builds a complete architectural mental model of a codebase or subsystem.
Comparable to what a senior engineer would produce after a day of exploration.

**Invocation modes:**
1. Full exploration (no orient data) — runs all steps from Step 1
2. Scoped exploration (orient data provided) — starts from Step 2, focuses on one subsystem

**Step 1 — Orient (skip if orient data provided, run in parallel):**
```
ix subsystems --format json
ix subsystems --list --format json
ix rank --by dependents --kind class --top 15 --exclude-path test --format json
ix rank --by callers --kind function --top 15 --exclude-path test --format json
ix stats --format json
```

**Step 2 — Major pillars (per system in scope):**
```
ix overview <system> --format json
ix contains <system> --format json
```
Run in parallel batches. Extracts what each system contains, its role, how it connects.

**Step 3 — Key components deep dive (top 3-10 most important):**
`ix explain <component> --format json` (run in parallel)
Extracts role, importance tier, caller/callee counts, architectural significance.

**Step 4 — Data flows and patterns:**
```
ix trace <entry-point> --downstream --depth 2 --format json
ix callers <critical-function> --limit 15 --format json
ix callees <critical-function> --limit 15 --format json
```
Reconstructs data flow diagrams.

**Step 5 — Infrastructure and development (whole-repo mode only):**
```
ix inventory --kind file --path test --limit 10 --format json
ix inventory --kind file --path cmd --limit 20 --format json
```

**Step 6 — Targeted reads (at most 2):**
`ix read <symbol> --format json` — for core type definitions, entry points, plugin
registration patterns where graph left patterns unclear.

**Output (whole-repo mode):** System overview, architecture system map (ALL top-level
systems table), per-pillar breakdowns, core abstractions/type system, data flows
(ASCII diagrams), key components table (10-15 entries), build & development infra,
dependencies & coupling, risk areas (security/complexity/data integrity), navigation
shortcuts table, where to go deeper, selective reference.

**Output (single subsystem mode):** Purpose, scale, internal structure table,
key components table, data flow (ASCII), external coupling (which systems this
connects to), risks with file paths.

---

### ix-bug-investigator

**Purpose:** Root cause analysis — traces execution paths from a symptom to 1-3
failure candidates with evidence.

**Step 0 — Context (only if subsystem is unfamiliar or bug crosses boundaries):**
```
ix subsystems --format json
ix locate "$SYMPTOM" --limit 5 --format json
```
Optionally: `ix overview <likely-subsystem>` to understand subsystem boundaries.

**Step 1 — Locate the entry point (run in parallel):**
```
ix locate "$SYMPTOM" --limit 5 --format json
ix text   "$SYMPTOM" --limit 10 --format json
```
Identify the most likely entry point. If ambiguous, prefer closest name/path match.

**Step 2 — Explain the entry point:**
`ix explain <entry-point> --format json`
Classify as Boundary, Orchestrator, or Utility/helper.
Stop if explanation makes failure source immediately obvious.

**Step 3 — Trace the execution path:**
`ix trace <entry-point> --downstream --format json`
Walk downstream. Flag: state validation/transformation nodes, cross-subsystem calls,
high-callee functions. Form hypothesis: which 1-3 nodes are most suspicious?

**Step 4 — Verify with callers (if failure might come from upstream):**
`ix callers <entry-point> --limit 15 --format json`
Is the entry point being called incorrectly (wrong args, wrong state, wrong sequence)?

**Step 5 — Targeted code read (at most 2 calls):**
`ix read <suspect-function> --format json`
Look for: missing null checks, wrong input format assumptions, incorrect state
transitions, unhandled edge cases.
Hard limit: 2 reads. Report candidates and uncertainty if still unclear.

**Step 6 — Check for related issues [Pro]:**
`ix bugs --status open --format json`
Are there existing bug reports related to this component?

**Stop conditions:** Stop as soon as you can state "the most likely cause is X in
[function/file] because [specific evidence]." Do not continue if you have 2 reads and
a plausible hypothesis, a clear trace bottleneck, or an obvious caller misuse pattern.

**Output:** Entry point (symbol, file, subsystem), entity type, execution path (→ chain
with ⚠ suspects), root cause candidates (1-3 each with hypothesis, evidence, confidence),
what to verify next, uncertainty.

---

### ix-architecture-auditor

**Purpose:** Full structural health audit. Identifies design issues, ranks them by
severity, produces actionable improvements — entirely graph-based, never reads source.
Every finding must be backed by a specific metric.

**Step 1 — System structure (run in parallel):**
```
ix subsystems --format json
ix subsystems --list --format json
```
Build region hierarchy. Flag immediately:
- `crosscut_score > 0.1` → cross-cutting concern
- `confidence < 0.6` → fuzzy boundary
- `external_coupling >> cohesion` → module calls out more than within
Sort regions: worst health first.

**Step 2 — Smell detection:**
`ix smells --format json`
Classify each smell: orphan (dead code), god-module (too much responsibility),
weak-component (loosely held together).

**Step 3 — Hotspot analysis (only if smells found or coupling is high):**
```
ix rank --by dependents --kind class    --top 10 --exclude-path test --format json
ix rank --by dependents --kind function --top 10 --exclude-path test --format json
```
Correlate: components that are both highly central AND in poorly-bounded subsystems
= highest-risk change targets.

**Step 4 — Deep dive on worst offender (optional, only one region):**
```
ix subsystems <region> --explain
ix smells --format json    (filter by path prefix after retrieval)
```
Hard limit: one region. Identify the worst and analyze that; do not audit every subsystem.

**Step 6 — Active plans cross-reference [Pro]:**
`ix briefing --format json`
Cross-reference activePlans against flagged regions, recentDecisions against high-risk
components. Output as "Cross-reference: Active Plans vs Audit Findings" table.

**Output:** System health overview table (cohesion, ext. coupling, smells, flag per
region), Critical Issues (issue + evidence + problem + suggestion), Moderate Issues,
Hotspots (central + poorly bounded components), What's Healthy, Priority Order
(1-2-3 fix sequence with reason), What would improve scores (specific reorganizations),
[Pro] Cross-reference table.

---

### ix-safe-refactor-planner

**Purpose:** Risk-ordered change plan with safe edit boundaries for multi-file
refactors. Never recommends a change without knowing its blast radius.

**Step 0 — Pro check:**
`ix briefing --format json` — extract activePlans and activeGoals.
If an existing plan already covers this refactor, align to it rather than duplicating.

**Step 1 — Identify all targets:**
Parse input as list of targets (files or symbols). If it's a description:
```
ix locate "$INPUT" --limit 5 --format json
ix text   "$INPUT" --limit 10 --format json
```
Identify 2-5 concrete symbols/files. If spanning unfamiliar subsystems:
```
ix subsystems --format json
ix overview <highest-risk-target> --format json
```

**Step 2 — Impact each target (in parallel):**
For every target simultaneously:
```
ix impact  <target> --format json
ix callers <target> --limit 15 --format json
```
Rank: critical > high > medium > low.
Decision gate: any critical target → tell user before continuing. All low → fast path.

**Step 3 — Data flow between targets (if 2+ targets):**
`ix trace <highest-risk> --to <second-target> --format json`
Reveals: pipeline (must change in order) vs independent (can parallelize).

**Step 4 — Shared dependents (if high/critical targets exist):**
`ix depends <highest-risk-target> --depth 2 --format json`
Find symbols that depend on multiple targets — compounded risk, test after every change.

**Step 5 — Subsystem boundary check:**
From impact + callers data: which subsystems are in blast radius, whether any change
crosses a subsystem boundary (highest risk), whether tests exist in caller list.

**Step 6 — Code read (only if target's role is unclear after graph):**
`ix read <unclear-target> --format json`

**Step 7 — Pro context [Pro]:**
```
ix decisions --format json
ix plans --format json
```
Surface decisions that constrain the refactor. Align to existing plans.

**Plan construction rules:**
- Order: most-depended-on first (stabilizes downstream), OR lowest-risk first if independent
- Never recommend editing a critical target without a test plan
- Flag any cross-subsystem edit as requiring integration testing
- Identify rollback points (where partial change leaves system in consistent state)

**Output:** Risk Summary table, Change Order (numbered with reason for each position,
affected callers, risk level), Data Flow, Shared Risk, Test Checkpoints table,
Red Flags, Safe Edit Boundaries, [Pro] Project context and Related Decisions.

---

### ix-explorer

**Purpose:** General-purpose graph exploration for open-ended questions about
unfamiliar code, tracing data flows, or understanding how components connect.

Always graph-first, never starts with Grep/Glob/Read. Stops when the question is
answered — token efficiency over completeness.

**Command routing table:**
```
"How does this system work?"    →  ix subsystems → ix rank
"What does X do?"               →  ix locate X → ix explain X
"Who calls X?"                  →  ix callers X --limit 15
"What does X call?"             →  ix callees X --limit 15
"How does A reach B?"           →  ix trace A --to B
"What depends on X?"            →  ix depends X --depth 2
"What's in this file?"          →  ix overview <file> → ix inventory --path <file>
"Find uses of X"                →  ix text X --limit 20 + ix locate X (parallel)
"What imports X?"               →  ix imported-by X
"Most important components"     →  ix rank --by dependents --kind class --top 10
```

**Reasoning flow:** Orient → Locate → Explain → (Trace or Read only if needed) → Stop.

**Rules:**
- Run independent queries in parallel via Bash background processes
- `ix rank` requires both `--by` and `--kind` (errors without them)
- Use `ix read <symbol>` not file reads — returns only that symbol's source
- Use `ix subsystems` (cached) not `ix map` (expensive re-cluster) for architecture
- When results are ambiguous: use `--pick N`, `--path <path>`, or `--kind <kind>` — never give up after first try
- Fall back to Grep/Glob/Read only when ix returns nothing after trying ix text + ix locate
- Never output raw JSON

---

## Pro Integration (Optional)

Skills check for Ix Pro at the start of each invocation:
```bash
ix briefing --format json 2>&1
```
If the response contains a `revision` field, Pro is available. All Pro steps are
optional — skills degrade gracefully when Pro is absent. ix-briefing.sh is a
complete no-op if Pro is not installed.

**Pro-only fields and who uses them:**

| Field | Used by |
|-------|---------|
| `openBugs` | ix-debug (check for matching known bug before investigating), ix-impact (escalate risk if bugs touch blast radius) |
| `recentDecisions` | ix-debug, ix-architecture, ix-investigate (surface relevant past decisions) |
| `activePlans` | ix-plan, ix-safe-refactor-planner (avoid duplicate work, align to in-progress changes) |
| `activeGoals` | ix-plan, ix-safe-refactor-planner (contextualize planned changes) |
| `recentChanges` | ix-docs (surface recent changes context in documentation) |

---

## End-to-End Flow (Example)

User types: "how does the auth middleware work?"

1. ix-briefing.sh fires (Pro, once/10 min) → injects activeGoals + openBugs + recentDecisions

2. Claude invokes Grep("auth middleware")
3. ix-intercept.sh fires BEFORE Grep:
   - runs ix text + ix locate in parallel
   - injects: `[ix] 'auth middleware' — symbol: AuthMiddleware (class, middleware/auth.ts) | 4 text hits in auth.ts, router.ts, app.ts`
   - Claude now knows the symbol location from graph before Grep even runs

4. Claude invokes Read("middleware/auth.ts")
5. ix-read.sh fires BEFORE Read:
   - runs ix inventory + ix overview + ix impact in parallel
   - injects: `[ix] auth.ts — key: AuthMiddleware, validateToken, refreshSession | ⚠️ HIGH RISK: 23 dependents | Use ix read <symbol> for symbol source`

6. Claude invokes Edit("middleware/auth.ts", ...)
7. ix-pre-edit.sh fires BEFORE Edit:
   - runs ix impact → finds 23 dependents, risk=high
   - injects: `[ix] ⚠️ HIGH-RISK EDIT — auth.ts has 23 dependents. Hot spots: validateToken, refreshSession, checkScope. → Run tests on all routes that import this middleware.`

8. Edit proceeds.
9. ix-ingest.sh fires AFTER Edit (async) → runs ix map middleware/auth.ts → graph updated
10. Claude finishes responding.
11. ix-map.sh fires (async, Stop) → runs ix map (full refresh) in background

---

## File Layout

```
hooks/
  lib/
    index.sh              Barrel: sources ix-errors.sh + ix-lib.sh in one call
                          Creates a single import hub so the graph sees all hooks
                          as a connected component (star topology)
  ix-lib.sh               Shared utilities: ix_health_check, ix_check_pro,
                          parse_json, ix_run_text_locate, ix_summarize_text,
                          ix_summarize_locate
  ix-errors.sh            Error capture + local JSONL logging with secret redaction
  ix-briefing.sh          UserPromptSubmit: inject session briefing (Pro only)
  ix-intercept.sh         PreToolUse(Grep|Glob): front-run with ix text + locate
  ix-read.sh              PreToolUse(Read): inject inventory + overview + impact
  ix-bash.sh              PreToolUse(Bash): intercept grep/rg commands
  ix-pre-edit.sh          PreToolUse(Edit|Write): blast-radius warning before edit
  ix-ingest.sh            PostToolUse(Edit|Write): async graph update for changed file
  ix-map.sh               Stop: async full graph refresh after each response
  ix-report.sh            CLI utility: show recent captured errors from JSONL log
  hooks.json              Hook event → script mapping (read by Claude Code at startup)

skills/
  shared.md               Shared cognitive model referenced by all skills
                          (creates graph connectivity between skill files)
  ix-understand/SKILL.md  Mental model skill — shallow/medium/deep modes
  ix-investigate/SKILL.md Symbol deep dive — graph-first, 1 read max
  ix-impact/SKILL.md      Blast radius — purely graph-based
  ix-plan/SKILL.md        Multi-target change plan — delegates to planner agent
  ix-debug/SKILL.md       Root cause analysis — delegates to investigator agent
  ix-architecture/SKILL.md Design health — delegates to auditor agent
  ix-docs/SKILL.md        Documentation generation — parallel agent dispatch

agents/
  ix-explorer.md              General-purpose exploration (spawned directly)
  ix-system-explorer.md       Architectural model (spawned by ix-understand, ix-docs)
  ix-bug-investigator.md      Root cause analysis (spawned by ix-debug)
  ix-safe-refactor-planner.md Refactor safety (spawned by ix-plan)
  ix-architecture-auditor.md  Structural audit (spawned by ix-architecture)

.claude-plugin/
  plugin.json             Plugin manifest: name=ix-memory, version=2.3.0
  marketplace.json        Marketplace listing for /plugin marketplace add

CLAUDE.md                 Behavioral rules injected into Claude's context window
DESIGN.md                 Architecture reference + delegation model
HANDOFF.md                Session handoff notes — updated after each work session
OPTIMIZATION.md           Change backlog and implementation priorities
ROADMAP.md                Full phase detail for planned improvements
test-local.sh             Local test runner for hook validation
```

---

## Graph Snapshot — `/ix-understand --shallow` (2026-04-15)

> Auto-generated from live graph. map\_rev 575.
> ⚠ Graph boundary confidence is low or zero for: Api Gateway, Base, Org Template, Org Provisioner, Staging, Dev, Prod — claims for those regions are `[uncertain]`.

**Scale:** 893 files · 402,466 nodes (388,696 config\_entries + 3,050 functions + 1,043 files + 678 classes) · 77,068 edges · 141 regions

### Subsystem Map

| Subsystem | Files | Health | Role |
|-----------|-------|--------|------|
| Cli | 74 | 0.55 | Primary CLI command layer — largest single system |
| Api | 22–39 | 0.58–0.61 | REST API surface (coupling 78.67 — central hub) |
| Commands | 30 | 0.54 | Command dispatch and handler routing |
| Ix Pro | 18 | 0.55 | Pro-tier gated features |
| Context | 15 | 0.55 | Session/request context management |
| Map | 10 | 0.57 | Graph mapping and indexing pipeline |
| Explain | 10 | 0.55 | Entity explanation engine |
| Tools | 10 | 0.53 | Tool adapters / integrations |
| Builder | 7 | 0.55 | Build pipeline |
| Impact | 6 | 0.56 | Blast-radius / impact analysis |
| Db | 6 | 0.54 | Database layer (ArangoDB) |
| Savings | 6 | 0.51 | Cost/savings tracking |
| Smell | 4 | 0.53 | Code smell detection |
| Github | 3 | 0.52 | GitHub integration |
| Register | 3 | 0.52 | Entity registration |
| Conflict | 3 | 0.54 | Conflict resolution |

### Top Classes (by dependents)

| Class | Dependents |
|-------|-----------|
| NodeId | 90 |
| IxClient | 78 |
| Rev | 66 |
| ArangoClient | 30 |
| Ok | 25 |

### Top Functions (by callers)

| Function | Callers |
|----------|---------|
| getEndpoint | 47 |
| stderr | 21 |
| handle | 21 |
| query | 20 |
| relativePath | 18 |
| execute | 16 |
| renderSection | 15 |
| deterministicId | 13 |

### Assessment

CLI → Commands → Api layering. `NodeId`, `IxClient`, `Rev` are the fundamental shared types. `IxClient` (78 dependents) is the structural center. The `Api` subsystem's coupling score (78.67) flags it as the highest-risk change target. config\_entry dominates node count (388K) — heavy infrastructure/k8s config is indexed alongside source code.
