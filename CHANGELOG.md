# Changelog

## 3.2.0

Makes the hooks cost what they are worth. Four changes, all measured against recorded Claude Code sessions on a real repo: the hooks were spending 1.8s median and 10s p90 per intercepted search, with 128 outright timeouts.

- **The Pro probe no longer stalls every prompt.** `ix_check_pro` wrote its cache timestamp only *after* `ix briefing` returned. The briefing hook has a 10s budget and the probe can use all of it, so a hook killed mid-probe left no record — and the next prompt probed again, and the one after that. The cache is now claimed before the probe runs, and the probe itself is bounded (`IX_PRO_PROBE_TIMEOUT`, default 5s, where the platform has `timeout`). A slow backend now costs one prompt instead of every prompt.
- **Shell `grep` gets the same intent filter that `Grep` has.** `ix-bash.sh` sent every extracted pattern to `ix text` + `ix locate`, including phrases, log prefixes and regexes — the exact patterns `ix-intercept.sh` has always skipped, because nothing in the graph is named `\w+\.ts$`. Two ix calls, guaranteed empty, in front of the shell command they were meant to save. An alternation (`a|b`) now counts as a regex for both hooks.
- **Attribution goes to the person, not into the model's context.** `IX_ANNOTATE_CHANNEL` defaulted to `both`, so the model was sent a ~0.9 KB instruction per prompt to write an attribution section describing work the person had just watched happen. The default is now `systemMessage`: the person still sees the summary. `IX_ANNOTATE_CHANNEL=both` (or `modelSuffix`) restores the model-facing half.
- **A high-confidence match no longer denies the Grep.** `IX_BLOCK_ON_HIGH_CONFIDENCE` now defaults to 0, matching the Cursor plugin. Denying a tool call costs a whole turn — read the denial, decide, call again — against a ~30k-token turn floor, to save a single tool call. The graph answer is injected either way; set it to 1 for the old behavior.

Hook tests: 101 passing (91 before), including new cases for a stalled probe and for both sides of each flipped default.

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
