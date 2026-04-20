# Ix — Shared Cognitive Model

*Canonical install-time reference for Claude + Ix. All skills reference this file.*
*For contributing to this plugin, see the repo's `CLAUDE.md`.*

---

## What Ix Is

Ix is a graph-backed reasoning system for codebases. It builds a persistent structural graph from your repo — tracking symbols, call chains, imports, dependencies, and file relationships — and exposes that graph through a CLI (`ix`).

Claude uses Ix as **memory**. Instead of reading files to figure out what code does, Claude queries the graph for facts (what calls this, what does this depend on, what is the blast radius of this edit) and then reasons over the results. The graph provides structure; Claude provides understanding.

The key difference: Ix answers structural questions in milliseconds without reading source. File reads are a last resort when implementation detail is genuinely needed.

Default posture: when a question is primarily structural, prefer Ix first. Reach for native Grep, Glob, Bash search, or source reads only when Ix cannot answer the question confidently or precisely enough.

---

## Command Taxonomy

Commands grouped by intent — use the cheapest group that answers the question.

| Group | Commands | Use when |
|---|---|---|
| **orient** | `ix subsystems`, `ix overview <name>`, `ix stats` | Starting a new task, getting your bearings |
| **locate** | `ix locate <symbol>`, `ix search <term>`, `ix text <pattern>`, `ix inventory --kind <k> --path <p>` | Finding where something lives |
| **explain** | `ix explain <symbol>` | Understanding what a symbol does and how it connects |
| **connections** | `ix callers <symbol>`, `ix callees <symbol>`, `ix imported-by <symbol>`, `ix imports <symbol>` | Who calls/uses this, what does this call/import |
| **inspect** | `ix read <symbol>` | Reading a symbol's source when structure alone is insufficient |
| **flow/risk** | `ix trace <symbol>`, `ix depends <symbol>`, `ix impact <target>` | Understanding call chains, dependency trees, blast radius |
| **history** | `ix history <file>`, `ix diff <from> <to>` | Churn signals, what changed across revisions |
| **maintenance** | `ix map` | Refreshing the graph after large changes |

**`ix locate` vs `ix search`:** `ix locate` does exact match (fast, use when the symbol name is known). `ix search` ranks by structural relevance (use when the name is fuzzy or you're not sure what you're looking for).

Required flags:
- `ix rank` always requires `--by <metric>` and `--kind <kind>`
- `ix inventory` requires `--kind <kind>`
- Always pass `--format json` for structured output

---

## Pro Commands

Pro features require an Ix Pro backend. Detect with: `ix briefing --format json 2>&1` — returns JSON with a `revision` field if Pro is active, errors otherwise.

| Tier | Commands |
|---|---|
| **Standard** | `subsystems`, `overview`, `locate`, `search`, `explain`, `read`, `trace`, `callers`, `callees`, `contains`, `depends`, `impact`, `inventory`, `text`, `smells`, `rank`, `stats`, `status`, `map`, `history`, `diff`, `imports`, `imported-by` |
| **Pro only** | `briefing`, `plans`, `plan`, `goals`, `goal`, `bugs`, `bug`, `decisions`, `decide`, `patches`, `tasks`, `task`, `truth`, `workflow`, `instance` |

`ix briefing` JSON shape: `{ revision, lastIngestAt, goalCount, activeGoals, activePlans, openBugs, recentDecisions, recentChanges }` — one call provides full project context for all Pro-aware steps.

---

## Routing Table

| What you want to do | Start with |
|---|---|
| Understand how a subsystem works | `/ix-understand <subsystem>` |
| Deep dive into a specific symbol | `/ix-investigate <symbol>` |
| Check risk before editing a file | `/ix-impact <file>` |
| Plan a multi-file refactor | `/ix-plan <target1> <target2> ...` |
| Debug unexpected behavior | `/ix-debug <symptom>` |
| Audit design health / smells | `/ix-architecture [scope]` |
| Write onboarding or reference docs | `/ix-docs <target>` |
| Find where a symbol is defined | `ix locate <symbol> --format json` |
| Search when symbol name is fuzzy | `ix search <term> --limit 10 --format json` |
| Find callers of a function | `ix callers <symbol> --limit 15 --format json` |
| Find what a function calls | `ix callees <symbol> --limit 15 --format json` |
| Find what imports a module | `ix imported-by <symbol> --format json` |
| Check what a file exports | `ix overview <path> --format json` |
| Not sure which to use | `/ix-help <task description>` |

---

## When to Use Each Layer

**Raw `ix` commands** — use directly for single-step structural lookups: "where is X defined?", "what calls X?", "what does X import?". Cheaper than invoking a skill.

**Skills** (`/ix-understand`, `/ix-investigate`, etc.) — use when the task has multiple phases or requires synthesis. Skills sequence queries, stop early, and produce structured output. Always prefer a skill over a chain of manual ix commands.

**Hooks** — automatic context injected at tool boundaries (Grep, Glob, Edit, Bash, Stop). You do not invoke hooks; they fire on their own. When a hook fires, it either blocks the native tool with an ix answer or injects context before the tool runs. Do not duplicate what hooks already do.

**Agents** (`ix-system-explorer`, `ix-bug-investigator`, etc.) — delegate only for large, delegatable work: full architecture exploration, autonomous multi-file bug investigation, large refactor planning. Too expensive for routine questions. Skills call agents automatically when depth warrants it.

---

## Graph-First Decision Rules

1. **Orient before diving.** Run `ix subsystems` or `ix overview` first to understand the shape before querying individual symbols.
2. **Locate before explaining.** Use `ix locate` to confirm a symbol exists and get its canonical name before calling `ix explain`.
3. **Explain before reading.** `ix explain` gives role, connections, and callers from the graph. Only call `ix read` when you need implementation detail the graph does not provide.
4. **Prefer ix over native search for structure.** If the question is "where is this defined", "what calls this", "what does this depend on", or "what will this edit affect", use Ix before Grep, Glob, or ad hoc Bash search.
5. **Do not duplicate successful hook work.** If a hook already surfaced a relevant `[ix]` answer or context, use it and continue rather than rerunning the native tool path reflexively.
6. **Stop when the question is answered.** Do not run the next phase if the current one was sufficient.
7. **Label your evidence.** Distinguish graph-backed facts (`ix explain` said X) from inferences (therefore Y).
8. **Max depth 2 for depends/trace.** Always pass `--depth 2` on `ix trace` and `ix depends` calls. Deeper traversals fan out quickly and exceed token budgets. Go deeper only when the user explicitly asks.

---

## Fallback Behavior

**When `ix` is unavailable (not in PATH):**
The hook system will surface a one-time notification. Proceed using native tools (Grep, Glob, Read). Note in your response that Ix is inactive and structural data is unavailable.

**When graph confidence is low (< 0.6):**
Treat structural results as approximate — useful for orientation but not authoritative. Add a warning: `⚠ Graph confidence low — treat structural data as approximate`. Do not block native tool use on low-confidence graph results.

**When results are empty:**
Do not assume the symbol does not exist. The graph may not cover it. Fall back to `ix text <pattern>` for a text search, then to native Grep if that also returns nothing.

**When the graph may be stale:**
If recent edits have not been mapped (e.g., new files added, large refactor), run `ix map --silent` before relying on structural data. Staleness is most likely after bulk file changes.

**When ix returns an error:**
Exit the Ix query path gracefully. Do not surface raw error JSON. Fall back to native tools and note that the ix query failed.

---

## Token Budget

| Operation | Cap | Reason |
|---|---|---|
| Text search | `--limit 20` | Prevents huge result sets |
| Symbol search | `--limit 10` | `ix search` returns ranked results; top 10 is sufficient |
| Symbol rank | `--top 10`, always `--exclude-path test` | Test fixtures inflate counts |
| Callers / callees | `--limit 15` | Default 50 is wasteful; 15 covers most cases |
| Dependency tree | `--depth 2` max | `ix depends --depth 3+` can explode on connected nodes |
| Traces | `--depth 2` max; one per investigation | `ix trace` without `--depth` fans out widely |
| Code reads | Symbol-level only, max 2 per task | Source reads are expensive — exhaust graph first |

---

## Concrete Examples

**"How does the briefing hook decide what to inject?"**
```
ix locate ix_briefing          # find the function
ix explain ix_briefing         # get its role and connections from graph
ix read ix_briefing            # read source only if explain wasn't enough
```
Stop after `ix explain` if the role is clear.

---

**"Will editing ix-lib.sh break anything?"**
```
/ix-impact hooks/ix-lib.sh
```
The skill runs `ix impact`, ranks dependents by severity, and tells you what to check before editing.

---

**"What calls parse_json across the whole codebase?"**
```
ix callers parse_json --limit 15 --format json
```
Direct command — single structural question, no skill needed.

---

**"I'm new to this codebase. Where do I start?"**
```
ix subsystems --format json    # get the top-level shape
/ix-understand <key subsystem> # build a mental model of the most relevant part
```

---

**"grep AuthService keeps returning too many results."**
The Grep hook may already have blocked or augmented this with an ix locate result. Check if `[ix locate]` context appeared before the search. If not, run:
```
ix locate AuthService --format json
ix explain AuthService --format json
```
Then use `ix read AuthService` only if the structural data is insufficient.

---

## Skills in This Plugin

| Skill | Purpose |
|---|---|
| [ix-understand](ix-understand/SKILL.md) | Mental model of a system or subsystem |
| [ix-investigate](ix-investigate/SKILL.md) | Deep dive into a specific symbol |
| [ix-impact](ix-impact/SKILL.md) | Blast radius before an edit |
| [ix-plan](ix-plan/SKILL.md) | Risk-ordered plan for multi-file changes |
| [ix-debug](ix-debug/SKILL.md) | Root cause analysis from a symptom |
| [ix-architecture](ix-architecture/SKILL.md) | Design health audit |
| [ix-docs](ix-docs/SKILL.md) | Narrative-first documentation from graph |
| [ix-help](ix-help/SKILL.md) | Route to the right skill or command |
