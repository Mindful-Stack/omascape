---
title: How a feature gets built here — spec, plan, branch, record
description: Every feature in this repository went brainstorm → a dated design spec → a numbered TDD plan → a branch named by the spec; specs are annotated in place rather than rewritten, plans carry a Conventions preamble of gotchas that have bitten before, and only hard-to-reverse decisions become ADRs.
tags: [dev-workflow, testing, adr, tooling]
---

# How a feature gets built here — spec, plan, branch, record

`CLAUDE.md` says decisions are recorded, not embedded. This is the pipeline that produces them.
It is not aspirational: **15 design specs and 12 implementation plans** in `docs/` were all
written this way, and the shape is consistent enough to describe as a standard. Measured
2026-09-20 against `origin/main` (`7200771`).

```
brainstorm  →  docs/specs/<date>-<feature>-design.md  →  docs/plans/<date>-<feature>.md
                          │                                        │
                          │                                        └─→ branch, tasks, PR
                          └─→ an ADR, but only if the decision is hard to reverse
```

## The spec

`docs/specs/YYYY-MM-DD-<feature>-design.md`, dated the day the design was settled — **the date
does not move when the spec is revised**.

The headings that recur: `## Goal` and `## Scope` (13 of 15 specs each), `## Tests` (12),
`## Decisions` (10), `## Edge cases` (8). A spec also **names its branch** — 10 of 15 open with
``Branch `peek` `` or similar, and the plan then tells you to create it.

Two habits do most of the work:

- **`## Decisions (brainstorm <date>)`** — the choices, each with the alternative it beat and the
  cost it accepts. `card-presence` states the cost in a table and then says plainly *"the author's
  own cells shrink 380 → 360"*. A decision with no stated cost has usually not been made yet.
- **Claims are separated from assumptions.** `## Feasibility (confirmed, not assumed)` in the
  drag-drop spec; `## Findings that shaped it (verified <date> against Omarchy 4.0.0.alpha)` in
  dev-link; `## Verified facts` in three others. Anything not verified is called a **risk** and
  handed to a spike, not to the reader.

## Specs are annotated, never rewritten

A revision is marked in place with `✎` and its date, and the superseded claim is left visible:

> **`Shift`+arrow is an ACTION key, and it CONSUMES the hover it read.** ✎ *(revised after review
> 2026-09-18 — the original "reads liveness and leaves it unchanged" was wrong, see below.)*

Four specs carry `✎` marks — dev-link and actions 42 each, shove 6, card-presence 2 — and three
record numbered review rounds ("review round 2, item 7"). **Do not quietly correct a spec.** The
wrong version is why the right one is shaped the way it is, and a reviewer who sees only the
conclusion cannot check the reasoning. The same rule applies to `DESIGN.md`, whose dated v1
sections stay put with corrections noted beside them.

## The plan

`docs/plans/YYYY-MM-DD-<feature>.md`, numbered `## Task N: <imperative>` sections, each a
TDD cycle. Before Task 1 comes a **`## Conventions (every task)`** preamble, and its most valuable
part is a `**Gotchas (each has bitten this repo before)**` list — the Qt 6.4 reserved words,
`Item` already owning `layer`, `ListModel` roles fixed at first `append`, `QtTest` being unable to
synthesise `isAutoRepeat`.

That list is why [[adrs/0004-qt-compatibility-floor]] and the standing rules in `CLAUDE.md` exist:
the gotchas were being retyped into every plan because nothing surfaced them at authoring time.
**When you find yourself writing a gotcha into a plan preamble, that is the signal it belongs in
the knowledge base instead.** The ones that list carried are now nodes:
[[learnings/item-owns-a-final-layer-property]],
[[learnings/listmodel-roles-are-fixed-at-first-append]] and
[[learnings/qttest-cannot-synthesise-isautorepeat]]; the reserved words are in
[[adrs/0004-qt-compatibility-floor]].

Plans also carry the real thing rather than a description of it — the peek plan's Task 10 contains
the Tier 2 shell script verbatim, comments included.

## Branch, commits, PR

- **Branch names come from the spec.** Mostly the bare feature name (`peek`, `dropdown`,
  `activate`, `dev-link`); a `test/` or `docs/` prefix when the work is only that.
- **Conventional Commits**, scoped to the feature. Across the last 120 commits on `main`:
  `docs` 32, `feat` 31, `test` 22, `fix` 17, `build` 4, with the scope naming the feature
  (`peek` 32, `dropdown` 27, `activate` 24, `dev-link` 13).
- **The body says why, not what.** The diff says what.
- Most commits carry a `Co-Authored-By` trailer naming the model that wrote it (102 of the last
  120 non-merge commits on `main`); the ones that do not are small manual fixes.
- **PR descriptions are long here on purpose** — what was measured, what was corrected, what was
  deliberately not done. Say which of `README.md` § Testing's manual checks you actually ran; see
  [[general/release-and-distribution]].

## When a decision becomes an ADR

Not every decision does. The triage the existing records use:

| | Where it goes |
|---|---|
| Hard to reverse — a format on disk, an invariant across the codebase, a protocol join, a lifecycle | an **ADR** in `lore/knowledge/adrs/` |
| Reversible at no real cost — a default with a config key, a formula, a threshold | a **standard** in `general/`, `languages/` or `frameworks/` |
| A verified surprise about a tool, compositor or host | a **learning** in `learnings/` |

Workspaces 1–10 is the worked example of the middle row: a UI default with a config key that
disables it, so it is [[general/workspace-grid-defaults]] and not an ADR.

**An ADR cites `docs/specs/` rather than absorbing it.** The spec holds the design and the
evidence; the record holds the rule, the alternatives, the consequences, and the triggers that
would invalidate it. Both exist because they answer different questions.

## The live loop

`mise run link` points the installed plugin at this worktree and restarts the shell; `mise run
unlink` puts the ordinary clone back — see [[adrs/0001-dev-install-path]]. **Plans written before
2026-09-19 tell you to `cp` files into the plugin directory and run `omarchy restart shell`.**
That predates `dev-link` and should not be copied out of them; the restart is still mandatory
either way, because editing plugin source does not hot reload
([[learnings/plugin-hot-reload-serves-cached-source]]).

QML errors land in `journalctl --user -t omarchy-shell`.

## See also

- [[general/testing]] — the tiers a plan's tasks are written against.
- [[adrs/0003-test-tiers]] — why there are two, and why the third was rejected.
- [[general/release-and-distribution]] — what merging to `main` actually does.
- [[adrs/0001-dev-install-path]] — the development install a plan's live loop uses.
- `CLAUDE.md` § Conventions; `ROADMAP.md` for what is next and what is parked.
