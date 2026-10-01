# Changelog

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
