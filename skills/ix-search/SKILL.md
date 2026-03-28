---
name: ix-search
description: Search the codebase using Ix Memory graph-aware search combining text search and symbol location
argument-hint: <search term>
---

Run both of these in parallel using the Bash tool:
1. `ix text $ARGUMENTS --limit 20 --format json`
2. `ix locate $ARGUMENTS --limit 10 --format json`

Present the combined results. Lead with symbol matches from `ix locate` (exact definitions), then text matches from `ix text` (usages and references). Deduplicate where the same symbol appears in both.
