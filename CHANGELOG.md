# Changelog

## 3.1.1

Hardening for the auto-ingestion hooks so background graph refresh is safe to run frequently.

- **Post-edit hook (`ix-ingest.sh`) no longer retries `ix map` itself.** The `ix` CLI now owns retry/backoff and a per-run wall-clock deadline and is single-flight per workspace, so a shell-level retry only amplified load against a slow backend.
- **Both refresh hooks (`ix-map.sh`, `ix-ingest.sh`) mark their map as automatic (`IX_AUTO_MAP=1`).** The CLI skips an automatic map when the active backend is remote, so background refresh stays a local convenience and remote ingestion is left to deliberate, manual `ix map`. Set `IX_AUTO_MAP_CLOUD=1` to opt back in to remote auto-refresh.

Pairs with the `ix` CLI single-flight + deadline support (Ix #290).

## 3.1.0

- Adopt `ix --format llm` across skills and agents.
- Add an `mkdir`-lock fallback to the Stop-time full-map hook so concurrent runs don't stack on systems without `flock`.
