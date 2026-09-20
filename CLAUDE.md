# CLAUDE.md

Guidance for Claude Code working on Omascape — an Omarchy/Quickshell workspace overview plugin
(QML + a pure-JS `logic.js`, driving Hyprland through generated Lua).

This is a **single-repo household**: the `lore/` knowledge base is tracked inline, alongside the
code. There are no sibling repos, nothing is cloned in, and the workspace tooling's
sibling/repo-lifecycle targets (`make setup`, `make repos-*`, `make policy-*`) have nothing to
act on here.

## Commands — two different `test`s, don't confuse them

| Command | What it runs |
| --- | --- |
| `mise run test` | **The project suite.** Tier 1: `tests/run.sh` — logic suites, offscreen UI fixture, real-Lua parse and behaviour, dev-link stubs. This is what CI runs. |
| `mise run test-integration` | Tier 2: nested-Hyprland integration. Needs a real compositor, so it is not in CI. |
| `mise run link` / `unlink` | Point the live Omarchy plugin dir at this worktree, and back. |
| `make validate` | Knowledge-base validators (frontmatter, wikilinks, orphans, tag health). |
| `make doctor` | Full workspace + KB diagnostic. |
| `make test` | The **knowledge-base and workspace tooling's own** unit tests. Not Omascape's tests. |

`make test` passing says nothing about whether Omascape works. Use `mise run test`.

## Standing rules

These are the constraints that have cost the most time. Each links the record that explains why.

- **Qt 6.4 is the compatibility floor** (`lore/knowledge/adrs/0004-qt-compatibility-floor.md`). Local is 6.11,
  CI is 6.4, and in QML an unknown property is a *compile* error — so these pass locally and
  break the build:
  - Never use a legacy reserved word as an identifier: `long`, `short`, `int`, `char`, `float`,
    `double`, `byte`, `boolean`, `final`, `native`.
  - Never use a property newer than 6.4. Per-corner radius (`topLeftRadius`) is 6.7+, and 6.4 has
    no per-side borders either.
  - When CI fails on code that passed locally, suspect this first. `gh pr checks` is part of the
    loop, not an afterthought.
- **Compositor operations are atomic Lua chunks that must surface their errors**
  (`lore/knowledge/adrs/0002-compositor-dispatch-errors.md`). `hl.dispatch` never raises — a failed dispatcher
  returns `{ ok = false, error }` — and an unparseable chunk is dropped *silently* by the
  compositor. So every chunk defines `run()` before its first `pcall`, and every guarded `pcall`
  span dispatches through it. Only the best-effort focus/cursor restore may stay raw
  `hl.dispatch`. Adding a chunk means adding it to the dump fixture in `tests/lua-check.sh` and
  raising its count floor, or the guard silently stops covering it.
- **A `SKIP:` is not a pass** (`lore/knowledge/adrs/0003-test-tiers.md`). It is only enforced for
  `tests/lua-check.sh` (via `CI: "1"`); `tests/integration/` still exits 0 on every skip path, so
  read its output rather than its exit code.
- **Never run `omarchy restart shell` from a tool call** without establishing
  `HYPRLAND_INSTANCE_SIGNATURE` from `systemctl --user show-environment`
  (`lore/knowledge/learnings/omarchy-restart-shell-loses-the-bar.md`). A stale value kills the bar and fails the
  respawn into `/dev/null`.
- **Editing plugin source never hot reloads**
  (`lore/knowledge/learnings/plugin-hot-reload-serves-cached-source.md`). The reload fires and rebuilds the
  component from *cached* source, so it looks like it worked while serving old code. A restart is
  mandatory after every edit.
- **Verify the knowledge base with `make validate`, never the bare CLI.**
  `node lore/_tools/cli.js validate` from the repo root resolves to a nonexistent `./knowledge`,
  reads zero files and exits 0. The individual `lore/_tools/*.js` files are modules with no CLI
  entrypoint — running them directly is also a silent no-op.

## Where things live

```
Overview.qml, WindowTile.qml, PeekLayer.qml, …   the QML surface
logic.js                                         pure layout/reconcile/Lua-chunk logic, unit-tested
OmascapeLocks.qml                                persisted lock state
scripts/dev-link.sh                              the dev install (mise run link)
tests/                                           tst_*.qml (logic), ui/ (offscreen), lua/, integration/
docs/specs/                                      per-feature design docs — the evidence
docs/plans/                                      TDD implementation plans
lore/knowledge/adrs/                             architecture decision records (/lore:adr)
lore/knowledge/learnings/                        verified gotchas
lore/knowledge/general/                          standards
```

`DESIGN.md` is the architecture overview, `ROADMAP.md` what's next, `PLAN.md` the v1 build log,
`README.md` user-facing docs.

## Conventions

- **Decisions are recorded, not embedded.** A hard-to-reverse choice gets an ADR
  (`/lore:adr <title>`) that *cites* `docs/specs/` rather than duplicating it. The spec holds the
  design and evidence; the record holds the rule and its consequences.
- `logic.js` stays pure and unit-testable; `Overview.qml` wires Quickshell singletons to it.
  Layout maths belongs in `logic.js`, not in a QML binding.
- Frontmatter values in the KB must sit inline on one line. A block scalar (`>` or `|`) leaves the
  retrieval grep empty and drops the node out of search silently.
