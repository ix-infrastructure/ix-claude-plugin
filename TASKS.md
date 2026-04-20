# Implementation Task Breakdown

Derived from `deep-research-report.md`. Three phases: A (patch/stabilization), B (attribution + debounce), C (hardening + tests). Tasks are ordered by dependency — each task lists the files it touches, what to change, and a completion block for the agent to fill in.

---

## Legend

```
Status: [ ] pending  [~] in progress  [x] complete
```

Each task ends with an **Agent Log** section. When an agent works on a task it should:
1. Set the status marker to `[~]` when starting
2. Record **who** is making the change (agent name/model, or human username)
3. Record **when** (date started and date completed)
4. Write a brief **summary** of what was done — not just file names, but why the approach was taken and any non-obvious decisions
5. List every file changed and what specifically changed in each
6. Set the marker to `[x]` when done

---

---

# Phase A — Patch / Stabilization

> Goal: Fix correctness bugs, remove noisy token leakage, add map safety.  
> No new features. No behavior change unless env flags are set.

---

## A1 — Add portable `hash_string()` helper to `ix-lib.sh`

**Status:** `[x]`

**Why:** `md5sum` is not available on macOS by default (only on Linux/coreutils). Any cache key or fingerprint that uses it will silently fail or error on mac. All downstream tasks (A2, A3) depend on this helper existing first.

**Files:**
- `hooks/ix-lib.sh`

**What to do:**
1. Add a new `hash_string()` function near the top of `ix-lib.sh` (after the variable declarations, before `ix_health_check`).
2. The function takes a single string argument and writes a stable lowercase hex digest to stdout.
3. Try each implementation in order, use the first one that succeeds:
   - `md5sum` (Linux/coreutils)
   - `md5 -q` (macOS native)
   - `shasum -a 256` followed by cutting the first field
   - Python 3 fallback: `python3 -c "import hashlib,sys; print(hashlib.md5(sys.argv[1].encode()).hexdigest())" "$1"`
4. Export or make available to sourcing scripts (it's a shell function, so sourcing is sufficient).

**Acceptance check:** `hash_string "hello"` produces the same hex string on both Linux and macOS.

---

### Agent Log — A1

```
Who:       Claude (claude-sonnet-4-6) — prior session
Started:   2026-04-13
Completed: 2026-04-13
Files changed:
  - hooks/ix-lib.sh — added hash_string() after IX_PRO_CACHE declaration

Summary: Added a portable hash helper to replace the Linux-only md5sum calls used
         for cache keys and fingerprints. Tries md5sum → md5 -q → shasum -a 256 →
         python3 fallback in order, so the first available tool wins. All variants
         produce lowercase hex. Being a shell function, it is automatically available
         to any script that sources ix-lib.sh.
```

---

## A2 — Replace `md5sum` in `ix-errors.sh` fingerprint function

**Status:** `[x]`  
**Depends on:** A1

**Files:**
- `hooks/ix-errors.sh`

**What to do:**
1. In `_ixe_fp()` (line ~42), replace the final pipe to `md5sum | cut -d' ' -f1` with a call to `hash_string "$norm"`.
2. `ix-errors.sh` sources nothing by default, so it needs to either: (a) be sourced after `ix-lib.sh` (already the case via `lib/index.sh`), or (b) include an inline `hash_string` definition. Since `lib/index.sh` sources both files and `ix-lib.sh` is sourced first, the function will be available — verify the source order in `hooks/lib/index.sh`.
3. Do not change any other behavior in the file.

**Acceptance check:** `_ixe_fp "ix" "ix-map" "map failed"` returns a non-empty hex string on macOS without coreutils installed.

---

### Agent Log — A2

```
Who:       Claude (claude-sonnet-4-6) — prior session
Started:   2026-04-13
Completed: 2026-04-13
Files changed:
  - hooks/ix-errors.sh — replaced `printf '%s' "$norm" | md5sum | cut -d' ' -f1`
    with `hash_string "$norm"` in _ixe_fp()

Summary: Swapped the md5sum pipe in the error fingerprint function for the portable
         hash_string() added in A1. Source order in lib/index.sh sources ix-errors.sh
         before ix-lib.sh, but hash_string is only called at runtime (not at source
         time), so the function is available when _ixe_fp() is actually invoked.
```

---

## A3 — Replace `md5sum` in `ix-read.sh` cache key

**Status:** `[x]`  
**Depends on:** A1

**Files:**
- `hooks/ix-read.sh`

**What to do:**
1. On line 53, replace:
   ```bash
   _file_key=$(printf '%s' "$FILE_PATH" | md5sum | cut -d' ' -f1)
   ```
   with:
   ```bash
   _file_key=$(hash_string "$FILE_PATH")
   ```
2. Ensure `hash_string` is available at the point of the call — it is, because `lib/index.sh` is sourced on line 45, which includes `ix-lib.sh`. Move the cache key computation to after the `source` call if needed (it already is on line 53 vs source on line 45 — verify ordering).

**Acceptance check:** Cache directory `$TMPDIR/ix-read-cache/` contains hex-named files after a Read intercept fires on macOS.

---

### Agent Log — A3

```
Who:       Claude (claude-sonnet-4-6) — 2026-04-15 session
Started:   2026-04-15
Completed: 2026-04-15
Files changed:
  - hooks/ix-read.sh — replaced `printf '%s' "$FILE_PATH" | md5sum | cut -d' ' -f1`
    with `hash_string "$FILE_PATH"` on line 53

Summary: Same md5sum → hash_string swap as A2, this time for the per-file read cache
         key. Verified source order: lib/index.sh (line 45) loads ix-lib.sh before the
         cache key is computed on line 53, so hash_string() is available at call time.
```

---

## A4 — Use repo-relative paths in `ix-read.sh`

**Status:** `[x]`

**Files:**
- `hooks/ix-read.sh`

**What to do:**

The hook currently passes only `basename "$FILE_PATH"` to `ix inventory`, `ix overview`, and `ix impact`. In repos with duplicate filenames this selects the wrong file.

1. After reading `FILE_PATH` from stdin JSON, also read `CWD` from the hook input:
   ```bash
   CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
   ```
2. Compute a repo-relative path. Strategy:
   - If `FILE_PATH` is absolute and `CWD` is set, strip the `CWD` prefix:
     ```bash
     REL_PATH="${FILE_PATH#$CWD/}"
     ```
   - If `FILE_PATH` is already relative, use it as-is.
   - Fall back to `basename "$FILE_PATH"` only if both of the above fail.
3. Replace all three `ix` command invocations on lines 73–80 to use `$REL_PATH` instead of `$FILENAME`:
   ```bash
   ix inventory --kind file --path "$REL_PATH" --format json > ...
   ix overview "$REL_PATH" --format json > ...
   ix impact "$REL_PATH" --format json > ...
   ```
4. Keep `$FILENAME` (basename) only for the display string in the injected `CONTEXT` line at line 135 — users see the short name, but ix gets the full relative path.

**Acceptance check:** In a repo with two files named `index.ts` in different directories, the hook injects context for the correct one.

---

### Agent Log — A4

```
Who:       Claude (claude-sonnet-4-6) — 2026-04-15 session
Started:   2026-04-15
Completed: 2026-04-15
Files changed:
  - hooks/ix-read.sh — read CWD from stdin JSON; added REL_PATH computation (strips
    CWD prefix from absolute paths, uses relative paths as-is, falls back to basename
    only when CWD is unavailable); switched all three ix calls (inventory, overview,
    impact) from $FILENAME to $REL_PATH; kept $FILENAME (basename) for the display
    string in the injected CONTEXT line.

Summary: Hooks were passing only basename to ix, which would select the wrong file in
         repos with duplicate filenames in different directories. Fixed by computing a
         repo-relative path from the absolute FILE_PATH and the CWD provided in the
         hook input. The fallback chain (relative → basename) ensures safe degradation
         when CWD is missing.
```

---

## A5 — Use repo-relative paths in `ix-pre-edit.sh`

**Status:** `[x]`

**Files:**
- `hooks/ix-pre-edit.sh`

**What to do:**

Same problem as A4 but in the pre-edit hook. Currently line 37 does:
```bash
FILENAME=$(basename "$FILE_PATH")
```
and then line 40 calls `ix impact "$FILENAME"`.

1. Read `CWD` from stdin JSON the same way as A4.
2. Compute `REL_PATH` with the same logic (strip `CWD` prefix, fall back to basename).
3. Pass `$REL_PATH` to `ix impact`:
   ```bash
   RAW=$(ix impact "$REL_PATH" --format json 2>"$_imp_err") || { ... }
   ```
4. Keep `$FILENAME` (basename) only for the human-readable `WARNING` string on line 79 — display uses short name, ix call uses relative path.

**Acceptance check:** Pre-edit warning correctly identifies a deeply-nested file's impact even when another file with the same basename exists.

---

### Agent Log — A5

```
Who:       Claude (claude-sonnet-4-6) — 2026-04-15 session
Started:   2026-04-15
Completed: 2026-04-15
Files changed:
  - hooks/ix-pre-edit.sh — read CWD from stdin JSON; added REL_PATH computation
    (strips CWD prefix from absolute paths, uses relative paths as-is, falls back
    to basename only when CWD is unavailable); switched ix impact call from $FILENAME
    to $REL_PATH (including the error capture args); kept $FILENAME (basename) for
    the human-readable WARNING string on line 90.

Summary: Same repo-relative path fix as A4, applied to the pre-edit hook. The hook
         was passing only basename to ix impact, risking the wrong file being selected
         in repos with duplicate filenames. CWD is now read from the hook input and
         used to strip the absolute path down to a repo-relative one.
```

---

## A6 — Fix and improve the advice string in `ix-read.sh`

**Status:** `[x]`

**Files:**
- `hooks/ix-read.sh`

**What to do:**

The report notes the string `Use ix read  to get...` (missing symbol) may appear when no key items exist. Current code on line 138:
```bash
CONTEXT="${CONTEXT} | Use ix read <symbol> to get just a symbol's source instead of the full file"
```
The `<symbol>` is a literal placeholder — not very useful. The hook has already computed `KEY_ITEMS` (the top 5 names from overview). Use that to give a concrete, actionable suggestion.

1. After building `KEY_ITEMS` and `ENTITY_PART`, construct a `READ_HINT`:
   - If `KEY_ITEMS` is non-empty, take the first item and use it: `"Use \`ix read ${first_item}\` to read a symbol instead of the full file"`
   - If `KEY_ITEMS` is empty, fall back to: `"Use \`ix read <symbol>\` to read a symbol instead of the full file"`
2. Replace the hardcoded string on line 138 with `$READ_HINT`.

**Acceptance check:** When `ix overview` returns a file with key items, the injected context shows a real symbol name in the hint (e.g., `Use \`ix read Config\` to read...`).

---

### Agent Log — A6

```
Who:       Claude (claude-sonnet-4-6) — 2026-04-15 session
Started:   2026-04-15
Completed: 2026-04-15
Files changed:
  - hooks/ix-read.sh — initialized KEY_ITEMS="" before OV_JSON block; added
    READ_HINT construction after block (first item of KEY_ITEMS if non-empty,
    <symbol> placeholder otherwise); replaced hardcoded hint string on line 149
    with $READ_HINT.

Summary: The old hint always showed the literal placeholder "<symbol>", which
         was useless. The hook already had KEY_ITEMS (top-5 names from overview)
         but didn't use it in the hint. Now takes the first item and produces
         a concrete suggestion like `Use \`ix read Config\` to read a symbol`.
         KEY_ITEMS was initialized to "" before the if block so it's accessible
         after the block closes without needing to restructure the flow.
```

---

## A7 — Silence ingest injection by default in `ix-ingest.sh`

**Status:** `[x]`

**Files:**
- `hooks/ix-ingest.sh`

**What to do:**

Currently lines 38–39 always inject `[ix] Graph updated — mapped: <path>` into Claude's context. This appears on every file save and is not useful to the model — it adds steady token waste.

1. Add an env check at the top of the script (after the `ix_health_check` call):
   ```bash
   IX_INGEST_INJECT="${IX_INGEST_INJECT:-off}"
   ```
2. After the successful `ix map` call, replace the unconditional `jq` output with a conditional:
   ```bash
   if [ "$IX_INGEST_INJECT" = "on" ]; then
     jq -n --arg fp "$FILE_PATH" \
       '{"additionalContext": ("[ix] Graph updated — mapped: " + $fp)}'
   elif [ "$IX_INGEST_INJECT" = "debug-only" ]; then
     # Write to local log only — no Claude context injection
     ix_capture_async "ix" "ix-ingest" "mapped: $FILE_PATH" "0" "ix map $FILE_PATH" ""
   fi
   # Default (off): silent success — no injection, no log
   ```
3. Default is `off` — zero tokens, zero noise.

**Acceptance check:** After editing a file with default settings, no `[ix] Graph updated` line appears in Claude's context.

---

### Agent Log — A7

```
Who:       Claude (claude-sonnet-4-6) — 2026-04-15 session
Started:   2026-04-15
Completed: 2026-04-15
Files changed:
  - hooks/ix-ingest.sh — added IX_INGEST_INJECT env check (default "off");
    replaced unconditional jq output with conditional block: "on" injects
    additionalContext, "debug-only" calls ix_capture_async, default ("off")
    exits silently.

Summary: The hook previously injected "[ix] Graph updated — mapped: <path>"
         on every file save, adding token cost with no value to the model.
         Now defaults to silent. Set IX_INGEST_INJECT=on to restore the old
         behavior, or debug-only to log without context injection.
```

---

## A8 — Add map debounce and flock lock to `ix-map.sh`

**Status:** `[x]`

**Files:**
- `hooks/ix-map.sh`

**What to do:**

Current script does `nohup ix map >/dev/null 2>&1 & disown`. The Stop hook is already configured as `async: true` in `hooks.json`, so the script itself doesn't need to background the process — Claude Code handles the async execution. Adding `nohup ... & disown` on top of that risks multiple concurrent full-graph maps.

1. Remove the `nohup ix map >/dev/null 2>&1 & disown` lines.

2. Add debounce — skip the map if one ran recently:
   ```bash
   IX_MAP_DEBOUNCE_SECONDS="${IX_MAP_DEBOUNCE_SECONDS:-300}"
   IX_MAP_DEBOUNCE_FILE="${TMPDIR:-/tmp}/ix-map-last"
   _now=$(date +%s)
   if [ -f "$IX_MAP_DEBOUNCE_FILE" ]; then
     _last=$(cat "$IX_MAP_DEBOUNCE_FILE" 2>/dev/null || echo 0)
     (( (_now - _last) < IX_MAP_DEBOUNCE_SECONDS )) && exit 0
   fi
   ```

3. Add flock lock — skip if another map is already running:
   ```bash
   IX_MAP_LOCK_PATH="${IX_MAP_LOCK_PATH:-${TMPDIR:-/tmp}/ix-map.lock}"
   exec 9>"$IX_MAP_LOCK_PATH"
   flock -n 9 || exit 0   # another map is running — skip
   ```

4. Run `ix map` directly (blocking, but Claude Code's async runner handles the timeout):
   ```bash
   echo "$_now" > "$IX_MAP_DEBOUNCE_FILE"
   ix map >/dev/null 2>&1 || ix_capture_async "ix" "ix-map" "full map failed" "$?" "ix map" ""
   ```

5. If `flock` is not available (some minimal envs), fall back gracefully:
   ```bash
   if ! command -v flock >/dev/null 2>&1; then
     # No flock — rely on debounce only
     :
   fi
   ```

**Acceptance check:** Rapid consecutive Claude responses (multiple Stop events) result in at most one `ix map` per debounce window, with no orphaned background processes.

---

### Agent Log — A8

```
Who:       Claude (claude-sonnet-4-6) — 2026-04-15 session
Started:   2026-04-15
Completed: 2026-04-15
Files changed:
  - hooks/ix-map.sh — removed nohup/disown double-background; added debounce
    (300s default via IX_MAP_DEBOUNCE_SECONDS, timestamp in $TMPDIR/ix-map-last);
    added flock lock (skips gracefully if flock not available); runs ix map
    directly, relying on the Stop hook's async: true for non-blocking execution.

Summary: The Stop hook is already async: true in hooks.json, so the old
         nohup...& disown was double-backgrounding and could stack up concurrent
         full-graph maps on rapid responses. Replaced with debounce (skip if ran
         in the last 5 min) + flock (skip if another is already running). flock
         check is guarded so it degrades gracefully on minimal environments.
```

---

---

# Phase B — Minor / Attribution + Quality

> Goal: Add attribution ledger, dual-channel annotation, improve confidence gating, fix locate classifier.  
> All new features are off by default (env flags).  
> **Depends on Phase A being complete.**

---

## B1 — Add shared env defaults to `hooks/lib/index.sh`

**Status:** `[x]`

**Files:**
- `hooks/lib/index.sh`

**What to do:**

`lib/index.sh` is the single sourced entry point for all hooks. It currently just sources `ix-errors.sh` and `ix-lib.sh`. Add canonical env defaults here so every hook reads them from one place.

1. After the existing `source` lines, add a section:
   ```bash
   # ── Plugin env defaults (override via shell env) ─────────────────────────────
   IX_ANNOTATE_MODE="${IX_ANNOTATE_MODE:-off}"          # off | brief | debug | verbose
   IX_ANNOTATE_CHANNEL="${IX_ANNOTATE_CHANNEL:-systemMessage}"  # systemMessage | modelSuffix | both
   IX_INGEST_INJECT="${IX_INGEST_INJECT:-off}"          # off | on | debug-only
   IX_MAP_DEBOUNCE_SECONDS="${IX_MAP_DEBOUNCE_SECONDS:-300}"
   IX_MAP_LOCK_PATH="${IX_MAP_LOCK_PATH:-${TMPDIR:-/tmp}/ix-map.lock}"
   IX_HOOK_OUTPUT_STYLE="${IX_HOOK_OUTPUT_STYLE:-legacy}"  # legacy | structured (Phase C)
   IX_SKIP_SECRET_PATTERNS="${IX_SKIP_SECRET_PATTERNS:-1}"  # Phase C
   ```
2. Do not remove any existing content.

**Acceptance check:** Any hook script can reference `$IX_ANNOTATE_MODE` after sourcing `lib/index.sh` without defining it themselves.

---

### Agent Log — B1

```
Who:       Claude (claude-sonnet-4-6) — 2026-04-15 session
Started:   2026-04-15
Completed: 2026-04-15
Files changed:
  - hooks/lib/index.sh — added 7 env defaults after existing source lines;
    updated header comment to document the new exports.

Summary: Centralizes all plugin env knobs in the single shared entry point so
         hooks don't need to redeclare them. IX_INGEST_INJECT was already set
         inline in ix-ingest.sh (A7) — the lib/index.sh default is consistent
         and hooks that source lib/index.sh will inherit it automatically.
```

---

## B2 — Create attribution ledger helper `hooks/ix-ledger.sh`

**Status:** `[x]`  
**Depends on:** B1

**Files:**
- `hooks/ix-ledger.sh` *(new file)*
- `hooks/lib/index.sh` *(add source line)*

**What to do:**

Create a new shared helper that all hooks can call to record what they injected, and that the Stop hook can read to produce a per-turn attribution summary.

1. Create `hooks/ix-ledger.sh` with two public functions:

   **`ix_ledger_append`** — called by each hook after building its context string:
   ```bash
   # Usage: ix_ledger_append <hook_event> <tool> <ctx_chars> <ix_cmds> <conf> <risk> <ms>
   # Appends one JSON record to the ledger for this turn.
   ```
   - Fields: `{ts, turn_id, hook_event, tool, ctx_chars, ix_cmds[], conf, risk, ms}`
   - `turn_id`: a per-turn identifier — use `$PPID` or a TTL-reset counter so all events in one Claude turn share the same ID
   - Store at: `~/.local/share/ix/plugin/ledger/ledger.jsonl`
   - Write with `jq -cn` + `>> ledger.jsonl` (same pattern as `ix-errors.sh`)

   **`ix_ledger_last_turn`** — called by Stop hook to read the current turn's records:
   ```bash
   # Usage: RECORDS=$(ix_ledger_last_turn)
   # Returns JSON array of all ledger records with the current turn_id.
   ```
   - Reads last N lines of ledger file, filters by matching `turn_id`
   - Returns empty string if no records

2. Add `source "${_HOOK_DIR}/ix-ledger.sh"` to `hooks/lib/index.sh` after the existing sources.

**Acceptance check:** After a Grep intercept fires, the ledger file contains a new JSON record with `hook_event: "PreToolUse"`, `tool: "Grep"`, and a non-zero `ctx_chars`.

---

### Agent Log — B2

```
Who:       Claude (claude-sonnet-4-6) — 2026-04-15 session
Started:   2026-04-15
Completed: 2026-04-15
Files changed:
  - hooks/ix-ledger.sh (new) — ix_ledger_append() writes one JSONL record
    async (fire-and-forget subshell + disown, same pattern as ix-errors.sh);
    ix_ledger_last_turn() tail-reads last 200 lines and jq-filters by turn_id.
  - hooks/lib/index.sh — added source line for ix-ledger.sh; updated header
    comment to document new exports.

Summary: turn_id uses $PPID (the Claude Code parent process), which is stable
         across all hook events within one Claude response turn. Records go to
         ~/.local/share/ix/plugin/ledger/ledger.jsonl. ix_ledger_mode=off skips
         all writes. ix_cmds is stored as a JSON array (split on comma).
         Guarded with || true in lib/index.sh so missing file never breaks hooks.
```

---

## B3 — Wire ledger writes into every PreToolUse hook

**Status:** `[x]`  
**Depends on:** B2

**Files:**
- `hooks/ix-intercept.sh`
- `hooks/ix-read.sh`
- `hooks/ix-pre-edit.sh`
- `hooks/ix-bash.sh`
- `hooks/ix-briefing.sh`

**What to do:**

In each hook, after the `CONTEXT` string is fully assembled and before the final `jq` output, call `ix_ledger_append` with the relevant metadata. Each hook passes what it knows:

**`ix-intercept.sh` (Grep path):**
```bash
ix_ledger_append "PreToolUse" "Grep" "${#CONTEXT}" "text,locate" "${_confidence:-1}" "" "$_elapsed_ms"
```

**`ix-intercept.sh` (Glob path):**
```bash
ix_ledger_append "PreToolUse" "Glob" "${#CONTEXT}" "inventory" "1" "" "$_elapsed_ms"
```

**`ix-read.sh`:**
```bash
ix_ledger_append "PreToolUse" "Read" "${#CONTEXT}" "inventory,overview,impact" "${_confidence:-1}" "${RISK_LEVEL:-}" "$_elapsed_ms"
```

**`ix-pre-edit.sh`:**
```bash
ix_ledger_append "PreToolUse" "Edit" "${#CONTEXT}" "impact" "1" "${RISK_LEVEL:-}" "$_elapsed_ms"
```

**`ix-briefing.sh`:**
```bash
ix_ledger_append "UserPromptSubmit" "Briefing" "${#CONTEXT}" "briefing" "1" "" "$_elapsed_ms"
```

For `_elapsed_ms`: add `_t0=$(date +%s%3N)` at the start of each hook (after the source line) and compute `_elapsed_ms=$(( $(date +%s%3N) - _t0 ))` before the ledger call. If `date +%s%3N` is not supported (some macOS), fall back to `0`.

**Acceptance check:** After a Read intercept + an Edit, the ledger contains two records for the same `turn_id`.

---

### Agent Log — B3

```
Who:       Claude (claude-sonnet-4-6) — 2026-04-15 session
Started:   2026-04-15
Completed: 2026-04-15
Files changed:
  - hooks/ix-intercept.sh — _t0 after health_check; ledger call in shared final
    block using $TOOL to branch Grep vs Glob args; ${_confidence:-1} safe with
    set -u since _confidence is only set in the Grep path.
  - hooks/ix-read.sh — _t0 after health_check; ledger call before final jq;
    uses ${_confidence:-1} and ${RISK_LEVEL:-} for safe unset handling.
  - hooks/ix-pre-edit.sh — _t0 after health_check; ledger call before final jq;
    ctx_chars uses ${#WARNING} (the variable the hook assembles).
  - hooks/ix-bash.sh — _t0 after health_check; ledger call before final jq.
  - hooks/ix-briefing.sh — _t0 after health_check (before ix_check_pro so timing
    includes pro check); ctx_chars uses ${#BRIEFING}; event is UserPromptSubmit.

Summary: Each hook records elapsed time (_t0 at start, subtraction before
         output), tool name, injected context size, and ix commands run. The
         elapsed computation degrades to 0 on macOS where date +%s%3N may not
         be available. All calls fire async (ix_ledger_append subshell + disown)
         so they never add latency to the hook's response.
```

---

## B4 — Add attribution summary output to Stop hook (`ix-map.sh`)

**Status:** `[x]`  
**Depends on:** B2, B3, B1

**Files:**
- `hooks/ix-map.sh`

**What to do:**

After the map completes (or is skipped by debounce/lock), read the current turn's ledger records and optionally emit a `systemMessage` or `additionalContext` attribution summary.

1. Read current turn records:
   ```bash
   _records=$(ix_ledger_last_turn)
   ```

2. If `IX_ANNOTATE_MODE=brief` and records exist, build the brief attribution string:
   - Walk records; for each `hook_event + tool` combo build a code:
     - Briefing → `B`
     - Grep/Glob → `G(hit=N,loc=N)` (values from ledger `ctx_chars` or add dedicated count fields in B3)
     - Read → `R(risk=H|M|C)` (from `risk` field)
     - Edit/Write → `E(risk=H|M|C)`
   - Assemble: `⟦ix+:G(hit=12,loc=1) R(risk=H)⟧`

3. Output based on `IX_ANNOTATE_CHANNEL`:
   - `systemMessage`: `jq -n --arg msg "$_attr" '{"systemMessage": $msg}'`
   - `additionalContext`: `jq -n --arg ctx "$_attr" '{"additionalContext": $ctx}'`
   - `both`: output both keys in one JSON object

4. If `IX_ANNOTATE_MODE=off` (default), skip this entirely and output nothing.

5. Map skip via lock should record `map_skipped_lock` in the ledger instead of silently exiting.

**Acceptance check:** With `IX_ANNOTATE_MODE=brief`, after a turn where both Grep and Read hooks fired, the UI (or context) shows `⟦ix+:G(...) R(...)⟧`.

---

### Agent Log — B4

```
Who:       Codex (GPT-5) — 2026-04-15 session
Started:   2026-04-15
Completed: 2026-04-15
Files changed:
  - hooks/ix-map.sh — kept Stop-hook execution alive through debounce/lock skips so
    attribution can still emit; added brief ledger summarization helpers and
    channel-aware JSON output (systemMessage/additionalContext/both); records
    map_skipped_lock in the ledger instead of exiting silently on lock contention.

Summary: The Stop hook now reads the current turn's ledger after any map run or
         skip and, when IX_ANNOTATE_MODE=brief, emits a compact attribution
         suffix like `⟦ix+:G(loc=1) R(risk=H)⟧` on the configured channel.
         Because B3's ledger records only store ctx_chars/conf/risk (not exact
         text-hit counts), the Grep/Glob code reports locate/confidence data
         when available and otherwise falls back to plain `G`.
```

---

## B5 — Extract shared confidence gating into `ix-lib.sh`

**Status:** `[x]`

**Files:**
- `hooks/ix-lib.sh`
- `hooks/ix-intercept.sh`
- `hooks/ix-read.sh`

**What to do:**

Both `ix-intercept.sh` and `ix-read.sh` implement the same `< 0.3 / < 0.6` confidence threshold logic with slightly different inline `awk` code. Centralize it.

1. Add `ix_confidence_gate()` to `ix-lib.sh`:
   ```bash
   # Usage: ix_confidence_gate <confidence_value>
   # Sets global: CONF_GATE ("drop" | "warn" | "ok") and CONF_WARN (string, empty if ok)
   ix_confidence_gate() {
     local _c="$1"
     CONF_GATE="ok"
     CONF_WARN=""
     if awk "BEGIN {c=${_c}+0; exit !(c < 0.3)}"; then
       CONF_GATE="drop"
     elif awk "BEGIN {c=${_c}+0; exit !(c < 0.6)}"; then
       CONF_GATE="warn"
       CONF_WARN="⚠ Graph confidence low (${_c}) — treat structural data as approximate"
     fi
   }
   ```

2. In `ix-intercept.sh`: replace the inline `awk` confidence block with:
   ```bash
   ix_confidence_gate "${_confidence:-1}"
   [ "$CONF_GATE" = "drop" ] && { LOC_PART=""; }
   ```

3. In `ix-read.sh`: replace both `awk` confidence blocks with:
   ```bash
   ix_confidence_gate "${_confidence:-1}"
   [ "$CONF_GATE" = "drop" ] && exit 0
   ```

**Acceptance check:** Both hooks produce identical behavior to before, but the awk logic lives in one place.

---

### Agent Log — B5

```
Who:       Claude (claude-sonnet-4-6) — 2026-04-15 session
Started:   2026-04-15
Completed: 2026-04-15
Files changed:
  - hooks/ix-lib.sh — added ix_confidence_gate() after ix_summarize_locate;
    updated header exports comment to document the new function and its globals
  - hooks/ix-intercept.sh — replaced 4-line awk confidence block (lines 51-55)
    with 2-line ix_confidence_gate call; CONF_WARN is now set by the function
  - hooks/ix-read.sh — replaced 4-line awk confidence block (lines 116-119)
    with 2-line ix_confidence_gate call; exit 0 on CONF_GATE="drop" unchanged

Summary: Both hooks had identical < 0.3 / < 0.6 awk threshold logic with slightly
         different inline implementations. Extracted into ix_confidence_gate() in
         ix-lib.sh which sets CONF_GATE (drop|warn|ok) and CONF_WARN globally so
         callers can handle each case with a single line. CONF_WARN="" inits before
         the function call blocks remain in each hook to guard the unset-variable
         case when ix_confidence_gate is never reached (empty OV_JSON / LOC_RAW).
```

---

## B6 — Fix `ix locate` suppression — improved symbol-likeness classifier

**Status:** `[x]`

**Files:**
- `hooks/ix-lib.sh` (`ix_run_text_locate` function)

**What to do:**

Current logic in `ix_run_text_locate` (lines 73–79) blocks `ix locate` for any pattern containing `.`, `*`, `+`, `?`, `^`, `$`, `|`, `\\`, `[`, `]`, `(`, `)`, `{`, `}`. This is too aggressive — `.` and `.` in `module.method` or `config.ts` are valid symbol name components, not regex.

1. Replace the two-pass grep heuristic with a tighter one:
   ```bash
   _is_plain=1
   # Block locate only for patterns that look like actual regex:
   # quantifiers: * + ? {N} followed by digit/comma
   # anchors used mid-pattern: ^ not at start, $ not at end
   # character classes: [ ]
   # groups: ( )
   # alternation when adjacent to non-word: |
   # escape sequences: \d \w \s etc.
   if printf '%s\n' "$_pattern" | grep -qE '[*+?]|[][()]|\\\w|\{[0-9]'; then
     _is_plain=0
   fi
   ```
   This allows `.`, `_`, `-`, `/`, `:` which are all valid in qualified symbol names.

2. Add a length guard: if pattern is fewer than 2 characters, skip locate regardless (too ambiguous).

3. Do not change any other behavior of `ix_run_text_locate`.

**Acceptance check:** A pattern like `AuthService.login` or `config.ts` triggers `ix locate`; a pattern like `\w+\.ts$` or `(foo|bar)` does not.

---

### Agent Log — B6

```
Who:       Claude (claude-sonnet-4-6) — 2026-04-15 session
Started:   2026-04-15
Completed: 2026-04-15
Files changed:
  - hooks/ix-lib.sh — replaced 2-pass grep heuristic in ix_run_text_locate with
    a tighter single-pass pattern; added length guard (< 2 chars → skip locate)

Summary: The old classifier blocked locate for any pattern containing `.`, `|`,
         `$`, or `^`, which ruled out legitimate qualified symbol names like
         `AuthService.login` or `config.ts`. The new pattern only blocks on true
         regex indicators: quantifiers (* + ?), character classes ([ ]), groups
         (( )), escape sequences (\w etc.), and quantifier braces ({N}). Dot,
         underscore, dash, slash, and colon are now allowed through. Length guard
         added so single-char patterns (too ambiguous) never hit locate.
```

---

---

# Phase C — Hardening / Structured Output / Tests

> Goal: Secret detection, structured hook output format, test harness, optional model-suffix annotation.  
> **Depends on Phase B being complete.**  
> Gate new output format behind `IX_HOOK_OUTPUT_STYLE=structured` (default remains `legacy`).

---

## C1 — Add `ix_looks_like_secret()` to `ix-lib.sh` and gate pattern injection

**Status:** `[x]`

**Files:**
- `hooks/ix-lib.sh`
- `hooks/ix-intercept.sh`
- `hooks/ix-bash.sh`

**What to do:**

Patterns passed to Grep or Bash hooks may accidentally be secrets (API keys, tokens, JWTs). Injecting them into Claude's context or logging them is a risk.

1. Add `ix_looks_like_secret()` to `ix-lib.sh`:
   ```bash
   # Usage: ix_looks_like_secret <pattern>
   # Returns 0 (true) if pattern looks like a secret, 1 otherwise.
   ix_looks_like_secret() {
     local _p="$1"
     # Known secret prefixes
     printf '%s\n' "$_p" | grep -qE '^(sk-|ghp_|ghs_|glpat-|Bearer |eyJ)' && return 0
     # Long high-entropy token (>= 32 chars, mostly base64/hex chars)
     local _len="${#_p}"
     if [ "$_len" -ge 32 ]; then
       local _alnum
       _alnum=$(printf '%s' "$_p" | tr -cd 'A-Za-z0-9+/=_-' | wc -c)
       # If >90% of chars are base64-alphabet chars, treat as secret
       awk "BEGIN { exit !($_alnum / $_len > 0.90) }" && return 0
     fi
     return 1
   }
   ```

2. In `ix-intercept.sh`, after extracting `PATTERN`, add:
   ```bash
   if [ "${IX_SKIP_SECRET_PATTERNS:-1}" = "1" ] && ix_looks_like_secret "$PATTERN"; then
     exit 0  # silently skip — do not log the pattern
   fi
   ```

3. In `ix-bash.sh`, same check after the pattern is extracted from the command.

**Acceptance check:** A pattern like `sk-abc123...` (32+ chars) causes the hook to exit 0 without injecting or logging the pattern.

---

### Agent Log — C1

```
Who:       Claude (claude-sonnet-4-6) — 2026-04-15 session
Started:   2026-04-15
Completed: 2026-04-15
Files changed:
  - hooks/ix-lib.sh — added ix_looks_like_secret() after ix_confidence_gate;
    checks known secret prefixes (sk-, ghp_, ghs_, glpat-, Bearer, eyJ) then
    falls back to a high-entropy length guard (>=32 chars, >90% base64 alphabet);
    updated header Exports comment
  - hooks/ix-intercept.sh — added secret gate after short-pattern guard in Grep
    section; exits 0 silently without logging the pattern
  - hooks/ix-bash.sh — same secret gate after short-pattern guard; exits 0
    silently without logging the pattern

Summary: Patterns passed to Grep/Bash hooks could accidentally be secrets (API
         keys, JWTs, tokens). The gate is behind IX_SKIP_SECRET_PATTERNS (default
         1=on) so it can be disabled if needed. Uses a two-pass check: known prefix
         match first (fast), then entropy ratio for unknown formats. Silent exit 0
         means the native tool still runs but ix doesn't log or inject the pattern.
         wc -c output trimmed with tr -d ' ' for portability (macOS adds spaces).
```

---

## C2 — Add one-per-session "ix unavailable" notification

**Status:** `[x]`

**Files:**
- `hooks/ix-lib.sh` (update `ix_health_check`)

**What to do:**

Currently every hook silently exits when `ix` is not in PATH. Users installing the plugin for the first time, or in environments where the `ix` binary isn't on PATH, get no feedback.

1. Modify `ix_health_check()` in `ix-lib.sh` to emit a `systemMessage` once per session when `ix` is missing:
   ```bash
   ix_health_check() {
     # ... existing TTL logic ...
     
     # If ix is not available, notify once per session
     if ! command -v ix >/dev/null 2>&1; then
       _IX_NOTIFY_FILE="${TMPDIR:-/tmp}/ix-unavailable-notified"
       if [ ! -f "$_IX_NOTIFY_FILE" ]; then
         touch "$_IX_NOTIFY_FILE"
         jq -cn '{"systemMessage": "ix not found — hooks are inactive. Install ix from https://ix.infrastructure or run: npm i -g @ix/cli"}'
       fi
       exit 0
     fi
   }
   ```
2. The notification file is per-session (in `/tmp`) — it resets on reboot/new session.
3. This uses `systemMessage` (shown to user, not model context) — no token cost.

**Acceptance check:** In an environment without `ix` installed, the first hook fire shows the notification message once. Subsequent hooks fire silently.

---

### Agent Log — C2

```
Who:       Codex (GPT-5) — 2026-04-15 session
Started:   2026-04-15
Completed: 2026-04-15
Files changed:
  - hooks/ix-lib.sh — ix_health_check() now emits a one-time systemMessage
    when ix is missing, then exits 0 before any hook-specific logic runs
  - hooks/ix-intercept.sh — removed the early PATH guard so the shared health
    check can surface the notification instead of failing silently
  - hooks/ix-read.sh — same: removed the early PATH guard so Read routes through
    ix_health_check() in missing-ix environments
  - hooks/ix-pre-edit.sh — same: removed the early PATH guard so Edit/Write
    hooks can show the one-time install hint
  - hooks/ix-bash.sh — same: removed the early PATH guard so Bash intercepts
    also use the shared notification path
  - hooks/ix-briefing.sh — same: removed the early PATH guard so briefing uses
    the shared notification behavior
  - hooks/ix-ingest.sh — same: removed the early PATH guard so PostToolUse hooks
    do not bypass the shared missing-ix handling
  - hooks/ix-map.sh — same: removed the early PATH guard so Stop uses the shared
    health check rather than exiting before it can notify

Summary: The repo had already added `command -v ix || exit 0` guards at the top
         of every hook, which made the planned ix_health_check() notification
         unreachable. C2 therefore needed both changes: ix_health_check() now
         emits a one-time `systemMessage` using a TMPDIR sentinel file, and the
         hook entrypoints now defer ix-availability handling to that shared
         function. Result: the first hook fire in a missing-ix environment shows
         the install hint once, and later hook fires stay silent.
```

---

## C3 — Switch PreToolUse hooks to `hookSpecificOutput` structured format (behind flag)

**Status:** `[x]`  
**Depends on:** B1

**Files:**
- `hooks/ix-intercept.sh`
- `hooks/ix-read.sh`
- `hooks/ix-pre-edit.sh`
- `hooks/ix-bash.sh`

**What to do:**

Claude Code's Hooks reference defines a `hookSpecificOutput` format for PreToolUse hooks that explicitly declares `permissionDecision` and `hookEventName`. Currently all hooks output the simpler top-level `{"additionalContext": "..."}` form.

Gate this behind `IX_HOOK_OUTPUT_STYLE` (set in `lib/index.sh`, default `legacy`).

1. In each of the four PreToolUse hooks, replace the final output:
   ```bash
   # OLD:
   jq -n --arg ctx "$CONTEXT" '{"additionalContext": $ctx}'
   
   # NEW:
   if [ "${IX_HOOK_OUTPUT_STYLE:-legacy}" = "structured" ]; then
     jq -n --arg ctx "$CONTEXT" '{
       "hookSpecificOutput": {
         "hookEventName": "PreToolUse",
         "permissionDecision": "allow",
         "additionalContext": $ctx
       }
     }'
   else
     jq -n --arg ctx "$CONTEXT" '{"additionalContext": $ctx}'
   fi
   ```

2. Verify that `ix-pre-edit.sh` uses the same pattern (it does the same `additionalContext` output).

3. Do not change any other logic in the hooks.

**Acceptance check:** With `IX_HOOK_OUTPUT_STYLE=structured`, hook output JSON contains the `hookSpecificOutput` wrapper. With default/`legacy`, it outputs the flat `additionalContext` form.

---

### Agent Log — C3

```
Who:       Claude (claude-sonnet-4-6) — 2026-04-15 session
Started:   2026-04-15
Completed: 2026-04-15
Files changed:
  - hooks/ix-intercept.sh — replaced final jq output with IX_HOOK_OUTPUT_STYLE
    conditional; structured path wraps additionalContext in hookSpecificOutput
  - hooks/ix-read.sh — same pattern
  - hooks/ix-pre-edit.sh — same pattern (uses $WARNING instead of $CONTEXT)
  - hooks/ix-bash.sh — same pattern

Summary: Gated behind IX_HOOK_OUTPUT_STYLE (default "legacy" set in lib/index.sh).
         When set to "structured", each hook emits the hookSpecificOutput wrapper
         with permissionDecision=allow and hookEventName=PreToolUse. Default behavior
         (flat additionalContext) is unchanged. The conditional is at the output site
         only — no other hook logic was modified.
```

---

## C4 — Build test harness

**Status:** `[x]`

**Files (new):**
- `tests/test_hooks.sh`
- `tests/mock-ix.sh`
- `tests/fixtures/hook_inputs/grep_plain.json`
- `tests/fixtures/hook_inputs/grep_regex.json`
- `tests/fixtures/hook_inputs/glob_path.json`
- `tests/fixtures/hook_inputs/read_normal.json`
- `tests/fixtures/hook_inputs/read_binary.json`
- `tests/fixtures/hook_inputs/read_test_file.json`
- `tests/fixtures/hook_inputs/edit_high_risk.json`
- `tests/fixtures/hook_inputs/edit_low_risk.json`
- `tests/fixtures/hook_inputs/write_new_file.json`
- `tests/fixtures/ix_outputs/text_results.json`
- `tests/fixtures/ix_outputs/locate_resolved.json`
- `tests/fixtures/ix_outputs/locate_candidates.json`
- `tests/fixtures/ix_outputs/locate_low_confidence.json`
- `tests/fixtures/ix_outputs/overview_normal.json`
- `tests/fixtures/ix_outputs/overview_empty.json`
- `tests/fixtures/ix_outputs/impact_high.json`
- `tests/fixtures/ix_outputs/impact_low.json`
- `tests/fixtures/ix_outputs/inventory_results.json`

**What to do:**

### `tests/mock-ix.sh`

A mock `ix` binary that intercepts calls and returns fixture JSON based on the subcommand:
- Reads `$1` (subcommand: `text`, `locate`, `overview`, `impact`, `inventory`, `map`, `briefing`)
- Returns the matching fixture from `tests/fixtures/ix_outputs/`
- Supports `--format json` flag (just passes through)
- For `ix map`: exits 0 silently
- For unknown commands: exits 1 with stderr message

### Fixture files

Each `hook_inputs/*.json` is a complete stdin payload matching what Claude Code sends to a hook:
```json
{
  "tool_name": "Grep",
  "tool_input": { "pattern": "AuthService", "path": "src/" },
  "cwd": "/home/user/myrepo",
  "session_id": "test-session-001"
}
```

Each `ix_outputs/*.json` is a realistic ix CLI response (array or object with realistic fields).

### `tests/test_hooks.sh`

For each hook × fixture combination:
1. Set `PATH` to include `tests/` so mock-ix is used
2. Feed the fixture file as stdin: `< fixture.json hooks/ix-intercept.sh`
3. Assert:
   - Exit code is `0`
   - Stdout is either empty or valid JSON (`jq -e . >/dev/null`)
   - If JSON, contains either `additionalContext` or `hookSpecificOutput` key
   - `additionalContext` value starts with `[ix]` or confidence warning prefix
   - Output does not exceed 10,000 characters (Claude Code's injection cap)
4. Test failure cases:
   - Hook receives empty stdin → exits 0, no output
   - `ix` returns error exit code → exits 0, no output (hook degrades gracefully)
   - `ix` returns empty string → exits 0, no output
5. Test secret suppression (C1): grep for a `sk-abc...` pattern → exits 0, no output

All test output should use `PASS`/`FAIL` labels. Test script exits non-zero if any test failed.

**Acceptance check:** `bash tests/test_hooks.sh` runs without errors on both Linux and macOS, all tests pass.

---

### Agent Log — C4

```
Who:       Claude (claude-sonnet-4-6) — 2026-04-15 session
Started:   2026-04-15
Completed: 2026-04-15
Files changed:
  - tests/mock-ix.sh (new) — fixture-driven mock; subcommand dispatch via env
    overrides (IX_MOCK_TEXT_FILE, IX_MOCK_LOCATE_FILE, etc.); IX_MOCK_FAIL=1
    mode for failure-degradation tests; handles briefing/status silently
  - tests/ix (new) — one-line wrapper so `PATH="tests:$PATH"` resolves `ix`
    to the mock without renaming mock-ix.sh
  - tests/fixtures/hook_inputs/*.json (9 files) — complete stdin payloads
    matching Claude Code's hook format; cover Grep/Glob/Read/Edit/Write tools
  - tests/fixtures/ix_outputs/*.json (9 files) — realistic ix CLI responses
    for text, locate (resolved/candidates/low-confidence), overview
    (normal/empty), impact (high/low), inventory
  - tests/test_hooks.sh (new) — 28 tests across all 4 PreToolUse hooks;
    covers golden-path, skip/filter cases, ix failure degradation, secret
    suppression, structured output mode, and the one-time unavailable notice

Summary: Per-run TMPDIR isolation prevents read-cache TTL bleed between tests.
         IX_LEDGER_MODE=off and IX_ERROR_MODE=off suppress async side-effects
         that would race against output capture. All 28 tests pass on Linux.
         Tests use inline temp-file fixtures for cases not in the fixture set
         (secret patterns, bash grep, bash ls, markdown edit).
```

---

## C5 — Optional model-suffix attribution channel

**Status:** `[x]`  
**Depends on:** B1, B2

**Files:**
- `hooks/ix-briefing.sh`

**What to do:**

When `IX_ANNOTATE_CHANNEL=modelSuffix` or `both`, inject a one-time session instruction telling Claude to append a brief attribution suffix to responses where it received `[ix]` context.

1. In `ix-briefing.sh`, after the main briefing context is assembled, check:
   ```bash
   _channel="${IX_ANNOTATE_CHANNEL:-systemMessage}"
   _mode="${IX_ANNOTATE_MODE:-off}"
   ```

2. If `_mode != off` and `_channel` is `modelSuffix` or `both`, and this is the first injection this session (use a TTL cache file `$TMPDIR/ix-model-suffix-instructed`):
   ```bash
   _SUFFIX_CACHE="${TMPDIR:-/tmp}/ix-model-suffix-instructed"
   if [ ! -f "$_SUFFIX_CACHE" ]; then
     touch "$_SUFFIX_CACHE"
     _suffix_instruction="[ix meta] Attribution: if you received any lines starting with [ix] since the last user message, end your response with ⟦ix+:<codes>⟧ where codes are: B=briefing, G=grep/glob, R=read, E=edit. Example: ⟦ix+:G R⟧"
     CONTEXT="${CONTEXT}
   ${_suffix_instruction}"
   fi
   ```

3. This is appended to the briefing `additionalContext`, so it lands in Claude's context once per session.

4. Only activate when `IX_ANNOTATE_MODE != off` and channel includes `modelSuffix`. Default behavior (all defaults) is unchanged.

**Acceptance check:** With `IX_ANNOTATE_MODE=brief IX_ANNOTATE_CHANNEL=modelSuffix`, Claude appends `⟦ix+:G⟧` to responses where a Grep intercept fired.

---

### Agent Log — C5

```
Who:       Claude (claude-sonnet-4-6) — 2026-04-15 session
Started:   2026-04-15
Completed: 2026-04-15
Files changed:
  - hooks/ix-briefing.sh — added model-suffix instruction block after elapsed_ms
    calculation; reads IX_ANNOTATE_CHANNEL and IX_ANNOTATE_MODE (both from
    lib/index.sh defaults); writes $TMPDIR/ix-model-suffix-instructed sentinel on
    first injection; appends _suffix_instruction to _context when active; moved
    ledger append after context assembly so ctx_chars reflects full injected size.

Summary: When IX_ANNOTATE_MODE != off and IX_ANNOTATE_CHANNEL is modelSuffix or
         both, the briefing injects a one-time session instruction telling Claude
         to append ⟦ix+:<codes>⟧ to responses where it received [ix] context.
         The sentinel file in TMPDIR ensures the instruction fires only once per
         session (resets on reboot). Default behavior (all env vars at default
         "off"/"systemMessage") is completely unchanged.
```

---

---

# Phase D — Skill Enhancements

> Goal: Add `--save` flag support to all skills so output can be persisted as Markdown files.  
> Skills are prompt files (SKILL.md), so this is implemented by adding argument-handling instructions to each skill's reasoning protocol.  
> No dependencies on Phases A–C.

---

## D1 — Add `--save [path]` argument to all skills

**Status:** `[x]`

**Why:** Users frequently want to keep skill output (architecture models, debug traces, impact reports, etc.) for later reference — in docs, handoffs, or planning files. Today the output only lives in the conversation. A `--save` flag lets them persist the result to a Markdown file without having to manually copy it.

**Files:**
- `skills/ix-understand/SKILL.md`
- `skills/ix-investigate/SKILL.md`
- `skills/ix-impact/SKILL.md`
- `skills/ix-plan/SKILL.md`
- `skills/ix-debug/SKILL.md`
- `skills/ix-architecture/SKILL.md`
- `skills/ix-docs/SKILL.md`

**What to do:**

1. In each skill's `argument-hint` frontmatter field, append `[--save [path]]` to the existing hint so it shows up in the argument placeholder UI.

2. At the top of each skill's reasoning protocol (before the first phase), add an argument-parsing block:

   ```
   **Argument parsing (do this first):**
   - Strip `--save` and any following path argument from `$ARGUMENTS` before processing the target.
   - If `--save` is present with a path (e.g. `--save docs/auth.md`), set SAVE_PATH to that path.
   - If `--save` is present without a path, auto-generate: `<skill-name>-<target-slug>.md` in the current working directory (where `<target-slug>` is the target with spaces and slashes replaced by `-`).
   - If `--save` is absent, SAVE_PATH is empty — do not write a file.
   ```

3. At the end of each skill's output section (after the final Summary/Next Step block), add a save step:

   ```
   **Save step (only if --save was passed):**
   - Write the full structured output above to SAVE_PATH using the Write tool.
   - Confirm to the user: `Saved to <SAVE_PATH>`.
   - Do not write the file if --save was not passed.
   ```

4. For `ix-docs`, this overlaps with the existing `--out <path>` flag. In `ix-docs/SKILL.md`:
   - `--save` is an alias for `--out` when no `--out` is given — if both are present, `--out` wins.
   - Do not duplicate the save logic; just note that `--save` maps to `--out` for this skill.

**Acceptance check:**
- `/ix-understand hooks --save` → produces structured output AND writes `ix-understand-hooks.md` in the working directory.
- `/ix-impact ix-read.sh --save docs/impact.md` → writes to `docs/impact.md`.
- `/ix-understand hooks` (no flag) → no file written, behavior unchanged.
- `/ix-docs hooks --save` → equivalent to `--out ix-docs-hooks.md`.

---

### Agent Log — D1

```
Who:       Claude (claude-sonnet-4-6) — 2026-04-15 session
Started:   2026-04-15
Completed: 2026-04-15
Files changed:
  - skills/ix-understand/SKILL.md — added --save to argument-hint; added --save
    bullet to existing Flag parsing section; added ## Save step at end
  - skills/ix-investigate/SKILL.md — added --save to argument-hint; added new
    ## Argument parsing section after command-v-ix check; added save step after
    confidence warning at end of Output
  - skills/ix-impact/SKILL.md — same pattern: argument-hint, new ## Argument
    parsing section, save step after "Never read source code" line
  - skills/ix-plan/SKILL.md — same pattern; slug uses first target or first
    three words of description
  - skills/ix-debug/SKILL.md — same pattern; slug uses first symbol or first
    three words of symptom; save step after closing ``` of Output block
  - skills/ix-architecture/SKILL.md — added ## Argument parsing section before
    ## Health gate (argument-hint has no arguments section); ## Save step added
    after ## [Pro] Cross-reference decisions
  - skills/ix-docs/SKILL.md — argument-hint updated; --save row added to Flags
    table as alias for --out (--out wins if both present); no separate save step
    needed since existing --out/Post-write confirmation handles file writing

Summary: For 6 non-docs skills: uniform pattern — strip --save + optional path
         from ARGUMENTS before any phase runs; auto-slug the filename if no path
         given; write to SAVE_PATH with Write tool at end if non-empty. For
         ix-docs: --save is just an alias for --out, so the existing file-writing
         logic in the skill handles it without a separate save step.
```

---

---

## Summary Table

| Task | Phase | Status | Primary File(s) | Description |
|------|-------|--------|-----------------|-------------|
| A1 | A | `[x]` | `hooks/ix-lib.sh` | Portable `hash_string()` helper |
| A2 | A | `[x]` | `hooks/ix-errors.sh` | Replace `md5sum` in fingerprint |
| A3 | A | `[x]` | `hooks/ix-read.sh` | Replace `md5sum` in cache key |
| A4 | A | `[x]` | `hooks/ix-read.sh` | Repo-relative paths for ix calls |
| A5 | A | `[x]` | `hooks/ix-pre-edit.sh` | Repo-relative paths for ix impact |
| A6 | A | `[x]` | `hooks/ix-read.sh` | Concrete symbol name in advice string |
| A7 | A | `[x]` | `hooks/ix-ingest.sh` | Gate ingest injection behind env flag |
| A8 | A | `[x]` | `hooks/ix-map.sh` | Map debounce + flock lock |
| B1 | B | `[x]` | `hooks/lib/index.sh` | Shared env defaults |
| B2 | B | `[x]` | `hooks/ix-ledger.sh` *(new)* | Attribution ledger helper |
| B3 | B | `[x]` | all PreToolUse hooks | Wire ledger writes |
| B4 | B | `[x]` | `hooks/ix-map.sh` | Attribution summary in Stop hook |
| B5 | B | `[x]` | `hooks/ix-lib.sh`, intercept, read | Shared confidence gate function |
| B6 | B | `[x]` | `hooks/ix-lib.sh` | Fix locate suppression classifier |
| C1 | C | `[x]` | `hooks/ix-lib.sh`, intercept, bash | Secret detection + pattern gating |
| C2 | C | `[x]` | `hooks/ix-lib.sh` | ix unavailable notification |
| C3 | C | `[x]` | all PreToolUse hooks | `hookSpecificOutput` format (behind flag) |
| C4 | C | `[x]` | `tests/` *(new)* | Full test harness |
| C5 | C | `[x]` | `hooks/ix-briefing.sh` | Model-suffix attribution channel |
| D1 | D | `[x]` | all `skills/*/SKILL.md` | Add `--save [path]` to all skills |
| E1 | E | `[x]` | `hooks/ix-lib.sh` | `ix_hook_decide()` output helper |
| E2 | E | `[x]` | `hooks/ix-intercept.sh` | Grep: query intent classifier |
| E3 | E | `[x]` | `hooks/ix-intercept.sh` | Grep: confidence-gated block/augment/allow |
| E4 | E | `[x]` | `hooks/ix-intercept.sh` | Glob: architectural mapping + blocking |
| E5 | E | `[x]` | `hooks/hooks.json`, `hooks/ix-read.sh` | Remove Read hook |
| E6 | E | `[x]` | `hooks/ix-lib.sh` | Fallback chain: block → augment → allow |
| E7 | E | `[x]` | `hooks/ix-annotate.sh` | Post-decision hook |

---

---

# Phase E — Hook System Redesign

> Goal: Implement the block/augment/allow decision model from the hook spec.
> Hooks must replace weak retrieval, not annotate it.
> Priority order: Grep blocking → Glob blocking → Remove Read hook → Fallback chain → Post-decision hook.
> **No dependencies on Phases A–D, but those must be complete first.**

---

## E1 — Add `ix_hook_decide()` output helper to `ix-lib.sh`

**Status:** `[x]`

**Why:** Every hook currently calls `jq` directly to emit `additionalContext`. When hooks gain block/augment/allow modes, they all need to translate the same internal decision to Claude Code's wire format. Centralizing this prevents drift and makes the structured-output flag apply consistently.

**Files:**
- `hooks/ix-lib.sh`

**What to do:**

Add `ix_hook_decide()` after `ix_confidence_gate`:

```bash
# Usage: ix_hook_decide <mode> <content>
#   mode    — "block" | "augment" | "allow"
#   content — reason string (block) or context string (augment); ignored for allow
# Emits the correct Claude Code JSON and exits.
ix_hook_decide() {
  local _mode="$1"
  local _content="$2"
  case "$_mode" in
    block)
      if [ "${IX_HOOK_OUTPUT_STYLE:-legacy}" = "structured" ]; then
        jq -cn --arg r "$_content" '{
          "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "block",
            "reason": $r
          }
        }'
      else
        jq -cn --arg r "$_content" '{"decision": "block", "reason": $r}'
      fi
      ;;
    augment)
      if [ "${IX_HOOK_OUTPUT_STYLE:-legacy}" = "structured" ]; then
        jq -cn --arg c "$_content" '{
          "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "allow",
            "additionalContext": $c
          }
        }'
      else
        jq -cn --arg c "$_content" '{"additionalContext": $c}'
      fi
      ;;
    allow|*)
      exit 0
      ;;
  esac
  exit 0
}
```

Also add `IX_BLOCK_ON_HIGH_CONFIDENCE` to `lib/index.sh` defaults:
```bash
IX_BLOCK_ON_HIGH_CONFIDENCE="${IX_BLOCK_ON_HIGH_CONFIDENCE:-1}"  # 1=on, 0=off
```

**Acceptance check:** Calling `ix_hook_decide block "test reason"` emits `{"decision": "block", "reason": "test reason"}` in legacy mode and the structured wrapper in structured mode.

---

### Agent Log — E1

```
Who:       Codex (GPT-5)
Started:   2026-04-17
Completed: 2026-04-17
Files changed:
  - hooks/ix-lib.sh — added ix_hook_decide() after ix_confidence_gate and documented
    it in the shared utility exports so later Phase E hooks can emit block/augment/
    allow decisions through one function.
  - hooks/lib/index.sh — added IX_BLOCK_ON_HIGH_CONFIDENCE default and updated the
    env-default docs to expose the new Phase E switch centrally.
  - tests/test_hooks.sh — added acceptance checks that call ix_hook_decide() directly
    and verify legacy block output plus structured block output.

Summary: Added a shared hook-output helper that centralizes Claude Code wire-format
         emission for block/augment/allow decisions, which prevents output drift as
         Phase E converts hooks from annotate-only behavior to decision-based gating.
         Kept the change non-invasive by introducing the helper first, exposing the
         high-confidence block flag centrally, and covering both legacy and structured
         block payloads in the shell test harness.
```

---

## E2 — Grep hook: query intent classifier

**Status:** `[x]`
**Depends on:** E1

**Why:** Not every Grep pattern is a symbol lookup. Blocking `grep TODO` or `grep "timeout exceeded"` with ix data would be wrong — those are literal string searches. The hook needs to classify intent before deciding whether to pursue blocking.

**Files:**
- `hooks/ix-lib.sh` (add `ix_query_intent()`)
- `hooks/ix-intercept.sh` (call classifier in Grep path)

**What to do:**

Add `ix_query_intent()` to `ix-lib.sh`:

```bash
# Usage: ix_query_intent <pattern>
# Sets global: QUERY_INTENT ("symbol" | "literal")
# "symbol" → pattern looks like a code symbol/system query → pursue ix lookup
# "literal" → pattern looks like a string/log/doc search → allow native tool
ix_query_intent() {
  local _p="$1"
  QUERY_INTENT="symbol"

  # Pure regex indicators → literal
  if printf '%s\n' "$_p" | grep -qE '[*+?]|[][()]|\\\w|\{[0-9]|\^[^^]|\$$'; then
    QUERY_INTENT="literal"; return
  fi

  # Common string/log/doc search patterns → literal
  if printf '%s\n' "$_p" | grep -qiE '^(TODO|FIXME|HACK|NOTE|XXX|DEPRECATED|error:|warn:|info:|debug:|fatal:)'; then
    QUERY_INTENT="literal"; return
  fi

  # Very long patterns (>60 chars) are likely log lines or prose → literal
  [ "${#_p}" -gt 60 ] && { QUERY_INTENT="literal"; return; }

  # Quoted strings (starts and ends with quote) → literal
  if printf '%s\n' "$_p" | grep -qE "^['\"].*['\"]$"; then
    QUERY_INTENT="literal"; return
  fi

  # Otherwise treat as potential symbol — let confidence gating decide
}
```

In `ix-intercept.sh`, in the Grep branch, after the secret check and before running ix commands:

```bash
ix_query_intent "$PATTERN"
if [ "$QUERY_INTENT" = "literal" ]; then
  exit 0  # allow native Grep — ix can't help with literal string searches
fi
```

**Acceptance check:**
- `grep TODO` → exits 0 (native Grep runs)
- `grep "timeout exceeded"` → exits 0
- `grep AuthService` → proceeds to ix lookup
- `grep "auth_middleware.login"` → proceeds to ix lookup
- `grep '\w+\.ts$'` → exits 0 (regex)

---

### Agent Log — E2

```
Who:       Codex (GPT-5)
Started:   2026-04-17
Completed: 2026-04-17
Files changed:
  - hooks/ix-lib.sh — added ix_query_intent() to classify Grep patterns as symbol
    lookups or literal searches, including regex/TODO/phrase guards.
  - hooks/ix-intercept.sh — invoked ix_query_intent() in the Grep path after the
    secret check and exited early for literal searches so ix lookup is skipped.
  - tests/test_hooks.sh — added direct classifier checks plus Grep-hook coverage
    for TODO, prose phrase, dotted symbol, and regex inputs.

Summary: Added the Grep intent gate that distinguishes symbol-like lookups from
         literal string searches before any ix calls run. I included a whitespace
         heuristic because the hook receives the parsed pattern rather than the
         original shell quotes, so phrases like `timeout exceeded` must still be
         treated as literal searches to match the task’s acceptance criteria.
```

---

## E3 — Grep hook: confidence-gated block/augment/allow

**Status:** `[x]`
**Depends on:** E1, E2

**Why:** The highest-value change in the spec. Currently the Grep hook always augments — native Grep still runs and Claude gets both the ix result and the raw matches. When ix has a high-confidence answer, blocking native Grep saves a tool call and forces Claude to work from structured graph data.

**Files:**
- `hooks/ix-intercept.sh`

**What to do:**

After `ix_summarize_text` / `ix_summarize_locate` are called and confidence is gated, replace the current augment-only output with a three-way decision:

```bash
# Determine block vs augment vs allow
HOOK_MODE="augment"
if [ "${IX_BLOCK_ON_HIGH_CONFIDENCE:-1}" = "1" ] && [ "$QUERY_INTENT" = "symbol" ]; then
  # Block only when locate resolved an exact match with high confidence
  _loc_type=$(echo "$_LOC_JSON" | jq -r '.resolvedTarget.type // "unknown"' 2>/dev/null || echo "")
  _loc_name=$(echo "$_LOC_JSON" | jq -r '.resolvedTarget.name // ""' 2>/dev/null || echo "")
  _loc_path=$(echo "$_LOC_JSON" | jq -r '.resolvedTarget.path // ""' 2>/dev/null || echo "")
  if [ "$CONF_GATE" = "ok" ] && [ -n "$_loc_name" ] && [ -n "$_loc_path" ]; then
    HOOK_MODE="block"
  fi
fi
```

**Block reason format** (assembled into `REASON`):

```
[ix text + ix locate] '<PATTERN>'
Found: <name> (<type>) at <path>
<TEXT_PART if present>
Next: ix read <name> | ix explain <name>
```

**Augment format** (unchanged from current — `CONTEXT` string):
```
[ix text + ix locate] '<PATTERN>' — <LOC_PART> | <TEXT_PART> | Use ix explain/trace/impact...
```

Replace the final output block with:
```bash
if [ "$HOOK_MODE" = "block" ]; then
  REASON="[ix locate] '${PATTERN}' — ${_loc_name} (${_loc_type}) at ${_loc_path}"
  [ -n "$TEXT_PART" ] && REASON="${REASON} | ${TEXT_PART}"
  REASON="${REASON} | Next: ix read ${_loc_name}"
  ix_ledger_append "PreToolUse" "Grep" "${#REASON}" "text,locate" "${_confidence:-1}" "" "$_elapsed_ms"
  echo "ix locate '${PATTERN}' → ${_loc_name} at ${_loc_path} [BLOCKED]" >&2
  ix_hook_decide "block" "$REASON"
else
  # augment — current behavior
  ix_ledger_append "PreToolUse" "Grep" "${#CONTEXT}" "text,locate" "${_confidence:-1}" "" "$_elapsed_ms"
  echo "ix text + ix locate: '${PATTERN}' → ${LOC_PART:-no exact match} | ${TEXT_PART:-no text hits}" >&2
  ix_hook_decide "augment" "$CONTEXT"
fi
```

**Acceptance check:**
- High-confidence symbol lookup (`AuthService`) → Grep is blocked, reason contains name + path + next action
- Medium-confidence fuzzy match → Grep runs, additionalContext injected
- Low-confidence / no match → Grep runs, no injection (allow)
- `IX_BLOCK_ON_HIGH_CONFIDENCE=0` → always augment (escape hatch)

---

### Agent Log — E3

```
Who:       Codex (GPT-5)
Started:   2026-04-17
Completed: 2026-04-17
Files changed:
  - hooks/ix-intercept.sh — added Grep-mode selection for block/augment/allow;
    exact high-confidence locate results now block, candidate-level results augment,
    and low-confidence/no-structural matches fall through silently to native Grep.
  - tests/test_hooks.sh — updated intercept expectations for block mode, added
    medium-confidence augment and low-confidence allow cases, added the blocking
    escape-hatch test, and aligned prefix assertions with current hook output.

Summary: Converted the Grep hook from unconditional annotation into a decision-based
         gate. High-confidence symbol lookups now stop native Grep with a concrete
         next-action reason, medium-confidence fuzzy results still augment with ix
         context, and low-confidence or text-only hits no longer inject redundant
         context because the native Grep result is the better source of truth.
```

---

## E4 — Glob hook: architectural mapping + conditional blocking

**Status:** `[x]`
**Depends on:** E1

**Why:** A glob like `hooks/**/*.sh` or `src/**/*.ts` is often asking "what's in this area of the codebase." The graph answers that better than a path list. When ix has a clear subsystem/inventory answer, blocking the native Glob avoids returning dozens of paths Claude doesn't need.

**Files:**
- `hooks/ix-intercept.sh` (Glob branch)

**What to do:**

**Intent classification** — before running ix:

```bash
GLOB_INTENT="architecture"  # default: assume architectural intent

# Literal extension glob (*.ts, *.py, *.sh) with no directory prefix → allow
# These are usually "list all files of type X" not "where does X live"
if printf '%s\n' "$PATTERN" | grep -qE '^\*\.[a-zA-Z0-9]+$'; then
  GLOB_INTENT="literal"
fi

# Very specific paths (no wildcards after a deep directory) → allow
if printf '%s\n' "$PATTERN" | grep -qE '^[^*]+/[^*]+$'; then
  GLOB_INTENT="literal"
fi

[ "$GLOB_INTENT" = "literal" ] && exit 0
```

**Block decision** — after ix inventory runs:

```bash
HOOK_MODE="augment"
if [ "${IX_BLOCK_ON_HIGH_CONFIDENCE:-1}" = "1" ] && [ "${TOTAL:-0}" -gt 0 ] && [ "${TOTAL:-0}" -le 20 ]; then
  # Block only when inventory returns a manageable, non-trivial result set
  HOOK_MODE="block"
fi
# If ix returns 0 results or too many (>20), fall through to allow
[ "${TOTAL:-0}" -eq 0 ] && exit 0
```

**Block reason format:**

```
[ix inventory] '<PATTERN>' in <PATH_ARG>: <TOTAL> entities
Key: <SAMPLE>
Next: ix overview <first_file> | ix read <symbol>
```

**Replace final output block:**

```bash
if [ "$HOOK_MODE" = "block" ]; then
  _first_sample=$(printf '%s' "$SAMPLE" | cut -d',' -f1 | tr -d ' ')
  REASON="[ix inventory] '${PATTERN}' in ${PATH_ARG}: ${TOTAL} entities — ${SAMPLE}"
  [ -n "$_first_sample" ] && REASON="${REASON} | Next: ix overview ${_first_sample}"
  ix_ledger_append "PreToolUse" "Glob" "${#REASON}" "inventory" "1" "" "$_elapsed_ms"
  echo "ix inventory: '${PATTERN}' in ${PATH_ARG} → ${TOTAL} entities [BLOCKED]" >&2
  ix_hook_decide "block" "$REASON"
else
  ix_ledger_append "PreToolUse" "Glob" "${#CONTEXT}" "inventory" "1" "" "$_elapsed_ms"
  echo "ix inventory: '${PATTERN}' in ${PATH_ARG} → ${TOTAL} entities" >&2
  ix_hook_decide "augment" "$CONTEXT"
fi
```

**Acceptance check:**
- `hooks/**/*.sh` → blocked, reason lists entities + next action
- `*.ts` (bare extension glob) → allowed, native Glob runs
- `hooks/ix-lib.sh` (specific file, no wildcards) → allowed
- ix returns 0 results → allowed
- `IX_BLOCK_ON_HIGH_CONFIDENCE=0` → always augment

---

### Agent Log — E4

```
Who:       Claude (claude-sonnet-4-6) — 2026-04-17
Started:   2026-04-17
Completed: 2026-04-17
Files changed:
  - hooks/ix-intercept.sh — added GLOB_INTENT classifier (literal: bare extension
    globs like *.ts, specific no-wildcard paths; architecture: everything else);
    added GLOB_HOOK_MODE decision (block when 0 < TOTAL <= 20 and
    IX_BLOCK_ON_HIGH_CONFIDENCE=1, augment otherwise); updated bottom else block
    to emit block reason (entity count + sample + next action) or augment context;
    moved >&2 echo for Glob to the output section (was inline before CONTEXT build).

Summary: Glob hook now classifies intent before running ix inventory. Bare extension
         globs (*.ts) and fully-specified paths with no wildcards pass through to
         native Glob immediately. For architectural globs (hooks/**/*.sh), inventory
         results with 1-20 entities trigger a block with a concrete next-action hint;
         >20 entities degrade to augment (too many to be actionable); 0 results allow
         natively. IX_BLOCK_ON_HIGH_CONFIDENCE=0 disables blocking as an escape hatch.
```

---

## E5 — Remove Read hook

**Status:** `[x]`

**Why:** The Read hook runs 3 ix commands before every file read but doesn't block the read. It's additive overhead: 3 ix calls + the full file read still happens. Per the spec: "A Read hook must save more tokens than it costs. If it does not, remove it." It does not.

**Files:**
- `hooks/hooks.json`
- `hooks/ix-read.sh` (archive, do not delete)

**What to do:**

1. In `hooks/hooks.json`, remove the Read matcher block:
   ```json
   {
     "matcher": "Read",
     "hooks": [
       {
         "type": "command",
         "command": "${CLAUDE_PLUGIN_ROOT}/hooks/ix-read.sh",
         "timeout": 8
       }
     ]
   }
   ```

2. Add a comment at the top of `ix-read.sh` marking it as disabled:
   ```bash
   # DISABLED — removed from hooks.json per Phase E spec.
   # The additive Read hook added 3 ix commands of overhead without preventing
   # the file read. Behavioral steering is handled by CLAUDE.md + briefing hook.
   # To re-enable: add Read matcher back to hooks.json.
   # Optional future use: fire only for files >300 lines with high graph coverage.
   ```

3. Update `hooks/lib/index.sh` exports comment to remove Read hook mention if present.

**Acceptance check:** After a `Read` tool call, no ix commands fire. The `ix-read.sh` file exists but is not registered in `hooks.json`.

---

### Agent Log — E5

```
Who:       Claude (claude-sonnet-4-6) — 2026-04-17
Started:   2026-04-17
Completed: 2026-04-17
Files changed:
  - hooks/hooks.json — removed the Read matcher block entirely
  - hooks/ix-read.sh — added DISABLED comment block at the top explaining why
    it was removed and how to re-enable it; file is archived, not deleted

Summary: The Read hook ran 3 ix commands (inventory + overview + impact) before
         every file read but could not block the read — it only added context.
         Net cost was always positive (3 ix calls + Read still happened). Per
         the Phase E spec: "if it does not save more tokens than it costs, remove
         it." Behavioral steering for reads is now handled by CLAUDE.md rules +
         the briefing hook. ix-read.sh is kept for potential future use (e.g.,
         gate on files >300 lines with high graph coverage).
```

---

## E6 — Implement fallback chain in `ix-lib.sh`

**Status:** `[x]`
**Depends on:** E1

**Why:** The spec's fallback policy is: if a hook tries to block but can't produce actionable results, it must degrade to augment, then allow. Without an explicit fallback path, a failed block leaves Claude with a blocked tool and no guidance — it stalls.

**Files:**
- `hooks/ix-lib.sh`

**What to do:**

Add `ix_hook_fallback()` to `ix-lib.sh`:

```bash
# Usage: ix_hook_fallback <intended_mode> <content> [<augment_fallback_content>]
#   intended_mode          — the mode the hook wanted ("block" | "augment")
#   content                — the primary content (reason for block, context for augment)
#   augment_fallback_content — optional: if block content is empty, use this for augment
#
# Fallback chain: block → augment → allow
# A hook calls ix_hook_fallback instead of ix_hook_decide when it might not
# have enough content to justify its intended mode.
ix_hook_fallback() {
  local _intended="$1"
  local _content="$2"
  local _aug_fallback="${3:-}"

  if [ "$_intended" = "block" ]; then
    if [ -n "$_content" ]; then
      ix_hook_decide "block" "$_content"
    elif [ -n "$_aug_fallback" ]; then
      # Degrade: block → augment
      ix_hook_decide "augment" "$_aug_fallback"
    else
      # Degrade: block → allow
      ix_hook_decide "allow" ""
    fi
  elif [ "$_intended" = "augment" ]; then
    if [ -n "$_content" ]; then
      ix_hook_decide "augment" "$_content"
    else
      # Degrade: augment → allow
      ix_hook_decide "allow" ""
    fi
  else
    ix_hook_decide "allow" ""
  fi
}
```

Update E3 and E4 to use `ix_hook_fallback` instead of direct `ix_hook_decide` calls at the output site, passing both the block reason and the augment context string as fallback.

**Acceptance check:** If `_loc_name` is empty in E3 but `TEXT_PART` is non-empty, hook degrades to augment instead of blocking with an empty reason.

---

### Agent Log — E6

```
Who:       Codex (GPT-5)
Started:   2026-04-17
Completed: 2026-04-17
Files changed:
  - hooks/ix-lib.sh — added ix_hook_fallback to centralize block → augment → allow
    degradation and documented it in the shared exports comment.
  - hooks/ix-intercept.sh — switched Grep and Glob output paths to use
    ix_hook_fallback so empty block content degrades cleanly to augment/allow
    instead of emitting a weak block.
  - tests/test_hooks.sh — added direct fallback helper coverage and aligned the
    Glob expectation with the current blocking behavior from E4.

Summary: Implemented the shared fallback chain required by the Phase E spec.
         Hooks that intend to block now degrade safely to augment or allow when
         they cannot produce actionable block content, and the hook test suite
         covers the helper behavior explicitly.
```

---

## E7 — Add post-decision hook

**Status:** `[x]`
**Depends on:** B2 (ledger)

**Why:** The spec calls for persisting decisions after non-trivial edits. The Stop hook fires at end of turn and has access to the ledger. If the current turn included Edit/Write events, Claude should be prompted to capture what changed and why — this compounds value across sessions.

**Files:**
- `hooks/ix-annotate.sh`

**What to do:**

**Implementation note:** Stop responsibilities are already split in the current codebase:
`ix-annotate.sh` emits synchronous Stop output and `ix-map.sh` handles the async
map refresh. The post-decision nudge belongs in `ix-annotate.sh`.

**Option: extend `ix-map.sh`** (original plan before Stop output moved)

After the map debounce/lock logic and before the attribution output, check if the current turn had edit events:

```bash
# Post-decision prompt — only when IX_ANNOTATE_MODE != off and turn had edits
if [ "${IX_ANNOTATE_MODE:-off}" != "off" ]; then
  _edit_count=$(echo "$_records" | jq '[.[] | select(.tool == "Edit" or .tool == "Write")] | length' 2>/dev/null || echo 0)
  if [ "${_edit_count:-0}" -gt 0 ]; then
    _decide_msg="[ix decide] This turn included ${_edit_count} edit(s). Consider noting: what changed, why, and what else may need updating. Use ix impact to check blast radius if not already done."
    # Append to whatever output channel is configured
    if [ "${IX_ANNOTATE_CHANNEL:-systemMessage}" = "systemMessage" ] || [ "${IX_ANNOTATE_CHANNEL}" = "both" ]; then
      _sys_msg="${_sys_msg:+${_sys_msg} | }${_decide_msg}"
    fi
  fi
fi
```

**Token budget:** ≤ 100 tokens. This is a nudge, not a dump.

**Gate:** Only fires when `IX_ANNOTATE_MODE != off`. Default is off so existing behavior is unchanged.

**Acceptance check:** With `IX_ANNOTATE_MODE=brief`, after a turn with an Edit event, the Stop hook output includes the post-decision nudge. With default settings (mode=off), nothing changes.

---

### Agent Log — E7

```
Who:       Codex (GPT-5)
Started:   2026-04-17
Completed: 2026-04-17
Files changed:
  - hooks/ix-annotate.sh — appended a short post-decision nudge when the current
    turn includes Edit/Write/MultiEdit activity, keeping the message within the
    existing Stop-hook systemMessage flow and leaving IX_ANNOTATE_MODE=off behavior unchanged.
  - tests/test_hooks.sh — seeded the ledger with a pre-edit event and added a
    Stop-hook assertion that the nudge appears in brief system-message mode.

Summary: Implemented the Phase E post-decision reminder in the synchronous Stop
         annotation hook that already owns user-visible Stop output. After edit
         turns, brief system-message annotation now nudges Claude to record what
         changed, why, and any follow-ups, with a reminder to check ix impact when
         blast radius is unclear.
```
