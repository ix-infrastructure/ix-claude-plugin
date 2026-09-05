# Changelog

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
