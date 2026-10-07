# Changelog

## Unreleased

Makes the hooks tell Claude what a grep or a fresh session cannot, instead of what it already has. Measured with ix-bench on SWE-PolyBench (Claude Code 2.1.290, Ix v0.12.1): the prompt briefing was empty on every run (it needs Ix Pro and a project with goals or decisions on record), the shell-grep hint fired on 2 of 11 searches and repeated the grep's own hits plus "prefer ix text", which no agent followed, and the edit hooks never fired, because agents edited through Bash. With Ix's tools available as MCP, agents called none of them in 90 runs.

- **A grep that names a definition gets its definition and callers.** `ix-bash.sh` and `ix-intercept.sh` (Grep) used to answer with the text hits the search was about to return anyway, a list of candidates, and a nudge to use `ix text`. When `ix locate` resolves one definition with confidence >= 0.6 they now inject where it is defined (file and line range) and who calls it, at the call site, nearest the definition first (`ix callers`, bounded by `IX_CALLERS_TIMEOUT`); otherwise they stay silent and the grep answers on its own. `ix-bash.sh` no longer runs `ix text` at all. `IX_BLOCK_ON_HIGH_CONFIDENCE=1` behaves as before.
- **New `ix-dependents.sh`: what depends on what an edit changed.** A `PostToolUse` hook on `Edit|MultiEdit|Write|Bash` that hands the hook input to `ix hook claude-post-edit` (Ix CLI 0.12.1+). Ix reads the working tree's `git diff`, so an edit made through a Bash script counts, and names each changed symbol's callers, importers and tests once per session. Silent with an older ix, an unmapped project, a backend that is down, or nothing to report. `IX_EDIT_DEPENDENTS=off` disables it.
- **The first prompt gets starting points.** On a session's first task-sized prompt (`IX_ISSUE_START_MIN_CHARS`, default 40), `ix-briefing.sh` runs `ix context --from-issue - --lean` on it and injects the files Ix trusts as starting points, or nothing when Ix trusts none. Once per session and project; bounded by `IX_ISSUE_START_TIMEOUT` (6s); the briefing hook's timeout goes from 10s to 15s to fit it. `IX_ISSUE_START=off` disables it.

In ix-bench, Ix delivered this way -- starting points beside the prompt and dependents after each edit, as a Claude Code mod -- was the best arm on 30 multi-file issues (17/90 solved vs 13/90 baseline, not significant; +8% cost).

Hook tests: 183 passing (151 in 3.2.0).

## 3.2.0

Makes the hooks cost what they are worth. Four changes, all measured against recorded Claude Code sessions on a real repo: the hooks were spending 1.8s median and 10s p90 per intercepted search, with 128 outright timeouts.

- **The Pro probe no longer stalls every prompt.** `ix_check_pro` wrote its cache timestamp only *after* `ix briefing` returned. The briefing hook has a 10s budget and the probe can use all of it, so a hook killed mid-probe left no record — and the next prompt probed again, and the one after that. The cache is now claimed before the probe runs, and the probe itself is bounded (`IX_PRO_PROBE_TIMEOUT`, default 5s, where the platform has `timeout`). A slow backend now costs one prompt instead of every prompt.
- **Shell `grep` gets the same intent filter that `Grep` has.** `ix-bash.sh` sent every extracted pattern to `ix text` + `ix locate`, including phrases, log prefixes and regexes — the exact patterns `ix-intercept.sh` has always skipped, because nothing in the graph is named `\w+\.ts$`. Two ix calls, guaranteed empty, in front of the shell command they were meant to save. An alternation (`a|b`) now counts as a regex for both hooks.
- **Attribution goes to the person, not into the model's context.** `IX_ANNOTATE_CHANNEL` defaulted to `both`, so — with 3.1.4 delivering hook context for real — the model would get a ~0.9 KB instruction on every prompt to write an attribution section describing work the person had just watched happen. The default is now `systemMessage`: the person still sees the summary. `IX_ANNOTATE_CHANNEL=both` (or `modelSuffix`) restores the model-facing half, the per-prompt instruction from `ix-briefing.sh`; the Stop-hook summary itself stays `systemMessage` whatever the channel (3.1.4).
- **A high-confidence match no longer denies the Grep.** `IX_BLOCK_ON_HIGH_CONFIDENCE` now defaults to 0, matching the Cursor plugin. Denying a tool call costs a whole turn — read the denial, decide, call again — against a ~30k-token turn floor, to save a single tool call. The graph answer is injected either way; set it to 1 for the old behavior.

Hook tests: 151 passing (142 in 3.1.4), including new cases for a stalled probe and for both sides of each flipped default.

## 3.1.4

Makes the hooks speak Claude Code's hook protocol, so the context they compute actually reaches the model. Checked against Claude Code 2.1.287 (the hook-output zod schemas in its binary) and https://code.claude.com/docs/en/hooks.

- **Hook context was being thrown away.** Every "augment" path — the session briefing and attribution instruction (`ix-briefing.sh`), the shell-grep hint (`ix-bash.sh`), the edit blast-radius warning (`ix-pre-edit.sh`), the Grep/Glob hint (`ix-intercept.sh` via `ix_hook_decide`) — printed a top-level `{"additionalContext": ...}`. Claude Code reads hook context only from `hookSpecificOutput.additionalContext` with a `hookEventName` matching the firing event, and logs `Hook JSON output had unrecognized keys (ignored): additionalContext` for the old shape. All of them now go through `ix_emit_context <event> <text>`, which emits `{"hookSpecificOutput":{"hookEventName":"<event>","additionalContext":"..."}}` (`UserPromptSubmit` for the briefing, `PreToolUse` for the rest). Visible consequence: with the default `IX_ANNOTATE_CHANNEL=both`, the model now really receives the per-prompt `Ix` attribution instruction, and will add the `Ix` section it asks for.
- **The Stop hook no longer sends model context.** `ix-annotate.sh` also printed a top-level `additionalContext`, which was ignored. Its only valid model channel on Stop, `hookSpecificOutput.additionalContext`, makes Claude take another turn to act on it — not something an attribution note should cost. The summary now always goes out as `systemMessage`; `IX_ANNOTATE_CHANNEL=additionalContext|both` fall back to it.
- **`IX_HOOK_OUTPUT_STYLE=structured` no longer bypasses permission prompts.** It sent `permissionDecision: "allow"` with every context injection, which made Claude Code skip the user's permission prompt for the tool call: every Bash command containing `grep`, every Edit/Write the pre-edit hook warned about. Context-only output now carries no decision, in either style.
- **Structured block uses the real enum.** It sent `permissionDecision: "block"` with a `reason` key; the enum is `allow|deny|ask|defer` and the reason key is `permissionDecisionReason`, so the output failed validation. It is now `deny` + `permissionDecisionReason`. The default (`legacy`) block keeps the top-level `decision: "block"` + `reason`, which Claude Code still honours for PreToolUse as a deny.
- **A Glob denial carries the whole answer.** When the Glob hook denies the call, its reason is all the model receives in place of the Glob result, but it listed only the first 5 of up to 20 entities. It now lists every entity ix returned.
- Tests assert the real shape, and every hook output captured by the suite is checked against the 2.1.287 schema (top-level keys, `hookEventName` = firing event, per-event `hookSpecificOutput` keys, the `permissionDecision` enum), plus two plugin rules: never `allow`, never Stop `additionalContext`. A smoke run of `claude -p --plugin-dir` against the fake `ix` shows the "unrecognized keys" warning gone and the model quoting a marker that only the briefing contains.

Hook tests: 142 passing (108 before); the same suite fails 84 cases against 3.1.3's hooks.

## 3.1.3

Stops the hooks running `ix map` calls that cannot work, and gates the automatic map that remains.

- **The post-edit hook no longer maps the edited file.** `ix-ingest.sh` ran `ix map <file>` on every edit, and `ix map` has rejected a file path ("Map path is not a directory") since Ix v0.10.6 — so every edit paid for a call that always failed. It now requests the guarded root map below, and only for files inside the project. The opt-in `IX_INGEST_INJECT` "Graph updated — mapped" message is gone with it: nothing is mapped per edit to report. `ix-investigate` no longer tells the model to run `ix map <file>`.
- **The Stop-hook map is guarded.** `ix-map.sh` ran a bare `ix map` from whatever directory the hook started in, behind a machine-wide `/tmp` debounce and lock, inside a 60s hook timeout — while the CLI's map deadline is far longer, so a slow map was killed after the debounce was already written. Both hooks now go through `ix_request_auto_map`, which maps only when the payload's `cwd` is in a git repo whose root is not `$HOME`, `ix status --root <root>` reports the graph complete (an automatic map never creates a workspace), and that root has not been tried within `IX_MAP_DEBOUNCE_SECONDS`. It runs `ix map <root> --silent` from the root with `IX_AUTO_MAP=1`, detached so the hook timeout cannot cut it short. Ix's per-workspace lock replaces the plugin's global one.
- **No hook state at fixed, shared `/tmp` names.** The health, Pro, unavailable-notice and briefing caches move to a per-user `0700` state dir (`$TMPDIR/ix-plugin-cache-<uid>`, falling back to `$XDG_STATE_HOME/ix-claude-plugin`). The briefing cache is keyed by project root, so one project's briefing is no longer served to another.
- The test `ix` mock is now as strict as the CLI: `ix map <file>` fails with "Map path is not a directory", and `ix locate --limit` / `ix smells --path` fail as unknown options.

Hook tests: 108 passing (91 before), including every guard branch of the automatic map.

## 3.1.2

Fixes two commands the skills told Claude to run that the `ix` CLI does not have.

- **`ix goals` does not exist — replaced with `ix goal list`.** The CLI's command is `goal` (singular); `goals` is only a help-topic alias that forwards to `goal`'s help, so `ix goals --format json` could never return data. `ix-plan` ran it directly, so the Pro branch of that skill silently produced no goal context.
- **`ix connect` does not exist and never has.** `ix-architecture` used it as the recovery instruction when the graph is unreachable, which sent users to a dead end at the exact moment something was already broken. It now says to run `ix docker start` and confirm with `ix status`, matching what the CLI itself prints for an unreachable backend.
- Corrected a stale plugin version in `IX_CLAUDE_PLUGIN_OVERVIEW.md` (said 2.3.0).

Every `ix` command referenced anywhere in the plugin was checked against the CLI's registered command list; these were the only two that did not resolve.

## 3.1.1

Hardening for the auto-ingestion hooks so background graph refresh is safe to run frequently.

- **Post-edit hook (`ix-ingest.sh`) no longer retries `ix map` itself.** The `ix` CLI now owns retry/backoff and a per-run wall-clock deadline and is single-flight per workspace, so a shell-level retry only amplified load against a slow backend.
- **Both refresh hooks (`ix-map.sh`, `ix-ingest.sh`) mark their map as automatic (`IX_AUTO_MAP=1`).** The CLI skips an automatic map when the active backend is remote, so background refresh stays a local convenience and remote ingestion is left to deliberate, manual `ix map`. Set `IX_AUTO_MAP_CLOUD=1` to opt back in to remote auto-refresh.

Pairs with the `ix` CLI single-flight + deadline support (Ix #290).

## 3.1.0

- Adopt `ix --format llm` across skills and agents.
- Add an `mkdir`-lock fallback to the Stop-time full-map hook so concurrent runs don't stack on systems without `flock`.
