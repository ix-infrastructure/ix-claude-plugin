# ix-claude-plugin
> For the canonical Ix operating model (command taxonomy, routing, fallback behavior),
> see `skills/shared.md`. This file covers contributing to ix-claude-plugin specifically.

This repo is the Claude Code plugin for [Ix Memory](https://github.com/ix-infrastructure/Ix). When working in this repo, use `ix` commands to navigate it just like any other codebase.
This repo contains shipped skills, hook scripts, tests, and marketplace metadata.

## Cognitive Model
Claude + Ix operates as a three-layer system:
```text
Ix Graph        = structured memory
Claude          = reasoning engine
Skills / Agents = task abstractions over the graph
```
The plugin exists to make that model usable inside Claude Code through install-time
teaching, hook-driven context injection, and higher-level reasoning skills.

## Repo Structure
```text
skills/
  shared.md                  canonical install-time Ix model
  ix-help/                   router skill
  ix-understand/             architecture mental model
  ix-investigate/            symbol deep dive
  ix-impact/                 pre-edit blast radius
  ix-plan/                   risk-ordered change planning
  ix-debug/                  bug investigation
  ix-architecture/           design health audit
  ix-docs/                   narrative-first documentation
agents/
  ix-explorer.md
  ix-system-explorer.md
  ix-bug-investigator.md
  ix-safe-refactor-planner.md
  ix-architecture-auditor.md
hooks/
  hooks.json                 active Claude Code hook registry
  ix-briefing.sh             prompt-time session context
  ix-annotate.sh             visible attribution / briefing annotation
  ix-intercept.sh            Grep / Glob interception
  ix-bash.sh                 grep / rg detection inside Bash commands
  ix-pre-edit.sh             pre-edit impact warning
  ix-ingest.sh               post-edit single-file map
  ix-map.sh                  async Stop-time full map refresh
  ix-read.sh                 disabled placeholder; not registered
  ix-lib.sh, ix-errors.sh, ix-ledger.sh, ix-report.sh, lib/index.sh
tests/
  test_hooks.sh              integration harness
  mock-ix.sh                 ix CLI stub
  fixtures/                  hook inputs and expected outputs
.claude-plugin/
  plugin.json                plugin manifest
  marketplace.json           marketplace metadata
```
Active hooks are defined by `hooks/hooks.json`: briefing + annotate on prompt
submit, intercept for `Grep|Glob`, bash interception for `Bash`, pre-edit
warnings for edits, ingest on post-edit, and full map refresh on `Stop`.

## Skills
Each skill is a reasoning protocol, not a command alias. It should choose the
cheapest path that answers the user's question and stop once enough evidence exists.

Required frontmatter:
```markdown
---
name: ix-<name>
description: <one-line description>
argument-hint: <placeholder shown in slash-command UI>
---
```

Good skill properties:
- Phased workflow with explicit stop conditions
- Graph-first structure; source reads only as a late fallback
- Risk-scaled depth rather than fixed command sequences
- Structured output focused on findings, confidence, and next step
- Clear delegation rules when an agent is warranted

Avoid one-to-one CLI wrappers, default full-file reads, raw JSON dumps, and
exhaustive fixed query lists that ignore task complexity.

When adding or changing a skill:
1. Update the relevant `skills/ix-*/SKILL.md`.
2. Keep universal Ix doctrine in `skills/shared.md`, not here.
3. Add the skill to the `skills/shared.md` table if it is user-facing.
4. Check whether docs or marketplace metadata mention the skill.

## Agents
The repo ships these agent specs:
- `ix-explorer` — general open-ended exploration
- `ix-system-explorer` — architecture and subsystem mental models
- `ix-bug-investigator` — root-cause analysis from symptoms
- `ix-safe-refactor-planner` — safe sequencing for risky refactors
- `ix-architecture-auditor` — structural health analysis and improvements

Keep agent prompts complementary to the skills. Skills decide when to delegate;
agents do the heavier exploration or synthesis once invoked.

## Contributing Notes
Hook work:
- Start with `hooks/hooks.json` to verify which hooks are actually active.
- Put reusable logic in `hooks/ix-lib.sh` or `hooks/lib/index.sh`, not inline everywhere.
- Keep hook output short and attributable; these paths are latency-sensitive.
- If a hook is intentionally disabled, leave that explicit in the script header as with `hooks/ix-read.sh`.

Testing:
- Run `bash tests/test_hooks.sh` after hook changes.
- The harness uses `tests/mock-ix.sh` and fixture JSON to validate behavior without a live ix server.
- Prefer targeted fixture additions over broad test rewrites when adjusting one hook path.

Manual checks:
- Match the active path rather than a no-op path.
- Grep / Glob behavior lives in `ix-intercept.sh`; shell `grep` / `rg` behavior lives in `ix-bash.sh`.
- Stop-time behavior is split between `ix-map.sh` and `ix-annotate.sh`.

Docs and metadata:
- `skills/shared.md` is the portable user-facing mental model.
- `CLAUDE.md` is repo-local contributor guidance.
- `IX_CLAUDE_PLUGIN_OVERVIEW.md` may lag runtime behavior; verify against `hooks/hooks.json` and tests before copying from it.
- `.claude-plugin/plugin.json` carries plugin identity and version.
- `.claude-plugin/marketplace.json` carries marketplace-facing metadata.

## Practical Workflow
For most repo changes:
1. Confirm the active behavior in `hooks/hooks.json`, tests, and the relevant skill or hook file.
2. Make the smallest coherent edit in the shipped asset.
3. Run the narrowest useful verification, usually `bash tests/test_hooks.sh` for hook work.
4. Update nearby docs only where they describe the changed behavior.

If guidance here conflicts with `skills/shared.md`, treat `skills/shared.md` as
the canonical Ix usage model and keep this file focused on maintaining the plugin.
