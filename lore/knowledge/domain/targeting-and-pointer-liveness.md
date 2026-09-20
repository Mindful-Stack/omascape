---
title: Targeting and pointer liveness — what an action acts on
description: One pure resolver decides the subject of every action; "no target" is terminal at each step and never falls through, pointer liveness arms only on a real move, and an action key reads liveness while every other key clears it before anything can resolve.
tags: [domain, architecture, javascript, qml, testing]
---

# Targeting and pointer liveness — what an action acts on

Every action in the overview — `Enter`, `Ctrl+W`, `Space`, the context menu, a drag — acts on
**the target**, and the target is decided in one pure function. This is the most cross-cutting
rule in the codebase and it appears in 14 of the 15 design specs. Measured 2026-09-20 against
`origin/main` (`7200771`).

`Logic.target(input)` (`logic.js:1345`) is the whole decision; `Overview.qml:554`'s
`resolveTarget()` only gathers its inputs.

## The order, and why each step is terminal

```js
function target(input) {
    if (!input.selectMode && input.pointerLive) {
        if (input.pointerTileAddress) return { kind: "window", address: … }
        if (hasWs(input.pointerWorkspaceId)) return { kind: "workspace", id: … }
        return null                                   // ← terminal
    }
    if (input.query && input.query.length)
        return input.matchAddress ? { kind: "window", address: … } : null   // ← terminal
    if (input.cursorAddress) return { kind: "window", address: … }
    if (hasWs(input.selectedId)) return { kind: "workspace", id: … }
    return null
}
```

**A step that has an answer returns it; a step that owns the question and has no answer returns
`null` rather than falling through.** Both terminal returns are deliberate and the source says
why:

- **A live pointer over empty canvas has no target.** Falling back to the keyboard "would make
  `Ctrl+W` close a window the user is not looking at".
- **A query with no match has no target.** Falling back "would jump to whatever workspace happens
  to be selected: worse than inert."

The query branch is written terminal even though `setQuery()` already clears the cursor, so the
two can never both be active — it is written that way "so a future refactor cannot reopen the
fall-through by 'simplifying' it back in". **Do not simplify either `return null` into a
fall-through.**

## Two activate policies

`config.activate` selects between them, and the difference is only whether the pointer is a
targeting device at all:

| Policy | Pointer | Rule |
|---|---|---|
| `enter` (default) | targets | most recent input device wins |
| `select` | highlights only — clicking selects | keyboard precedence is the whole rule, empty canvas included |

`resolveTarget()` short-circuits on `selectMode` before building the hit test, but that is **an
optimisation, not a second line of defence** — the rule itself lives in `Logic.target`, which is
handed the same flag. The Tier 1 suite asserts the pure one. Keep it that way: a rule enforced in
two places is a rule that can disagree with itself.

## Pointer liveness arms on a move, never on a position

`pointerLive` (`Overview.qml:507`) is false until `notePointerMove` (`:521`) sees the pointer
actually move. The first hover report of a summon is the surface mapping under wherever the
pointer already rests — a *position*, not a move — and admitting it meant "a keyboard summon
armed the pointer and `Ctrl+W` acted on whatever the resting cursor happened to cover."

Three mechanisms keep that out, and all three are load-bearing:

- **Same-position early return.** An identical coordinate marks the pointer primed and arms
  nothing.
- **`pointerPrimed` + the 300 ms `pointerPrime` window** (`:520`). Only the first report of a
  summon, and only while the surface is still mapping, is treated as a position. A real move emits
  a stream, so one made during that window still arms a pixel later.
- **`pointerSceneX/Y` survive the close** (`:1626`). They are deliberately *not* reset, so an
  unmoved pointer reports the same coordinates next summon and cannot spuriously re-arm.

Liveness is cleared on `open()`, when the hover leaves (`:2253`), and by every non-action key.

## Action keys read liveness; everything else clears it

```qml
// Action keys read pointer liveness; everything else is keyboard intent and
// clears it BEFORE any resolve below can see it.
if (!Logic.isActionKey(e.key, chord, Qt.ControlModifier)) root.pointerLive = false
```

`Overview.qml:2126`, and `Logic.isActionKey` (`logic.js:1518`) admits exactly three things:
**`Ctrl+W`, `Return`/`Enter`, and `Space`** (the peek). The doctrine in one line: an action key
means *"do this to what I am pointing at"*, not *"I am on the keyboard now"* — so a second
`Ctrl+W` cannot silently switch from the hovered window to the window cursor.

**A modifier pressed alone belongs to no class.** `Logic.isModifierKey` (`:1505`) exists because
`Ctrl` then `W` would otherwise dismiss the menu on the `Ctrl` and clear liveness before the `W`
arrived.

**Ordering inside the key handler is part of the rule.** The `Space`/peek branch sits *above* the
liveness clear so `resolveTarget()` sees liveness exactly as the pointer left it. `Space` being
an action key already guarantees that, and the source says so — the ordering is belt and braces
against a future reordering that would break pointer targeting silently.

**Adding a key means classifying it.** Decide whether it acts on the target or expresses keyboard
intent, and if it acts, add it to `isActionKey` in the same commit. A key that should read
liveness and does not will work perfectly on the keyboard path and be wrong under the pointer —
which no keyboard-only test will catch.

## Two rules about not widening `target()`

- **`loneWindow`** (`logic.js:1388`) gives `Ctrl+W` its one carve-out: a single-window workspace
  names that window unambiguously. It is deliberately **not** folded into `target()`, because
  widening the shared rule "would also change what `Enter` does on a one-window workspace".
- **The peek watches the model, not the resolver.** `Logic.target` falls *through* on
  disappearance rather than going null — a cleared cursor lands on the selected workspace,
  `cycleMatch` picks a successor — so "the binding went null" can never be a cancel mechanism.
  The peek remembers the identity it is showing (`peekedKey`) and watches that leave the model.

## The digit latch stores a key code, not a workspace

`Logic.digitActivate` (`logic.js:1545`) implements the `select` policy's two-press gesture, and
three orderings in it are rules rather than choices: the box lookup comes **before** the latch, so
a digit for a workspace with no box cannot arm it; the latch holds the **previous key code**, so
`2` then `3` selects 3 rather than entering it; and `autoRepeat` is checked first, so a held digit
changes nothing at all — including the latch.

## See Also

- [[domain/ubiquitous-language]] — what a target, a well, a cursor and a latch are.
- [[languages/javascript/code-style]] — why the decision is in `logic.js` and not a QML binding.
- [[general/architecture]] — the layering that puts every decision in the pure module.
- [[general/testing]] — the tier this is asserted in, and how a test states what it falsifies.
- [[frameworks/hyprland/compositor-state]] — the models the resolved target is looked up against.
