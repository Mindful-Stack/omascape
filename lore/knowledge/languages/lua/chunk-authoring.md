---
title: Lua chunk authoring
description: Every compositor operation is a Lua chunk built by a `*Lua()` function in logic.js; chunks must parse standalone on one line, fragments are composed into them, and interpolated text is truncated before it is escaped.
tags: [languages, lua, compositor, hyprland]
---

# Lua chunk authoring

Omascape writes no `.lua` source for the compositor. Every compositor operation is a Lua string
built by a function in `logic.js` and handed to Hyprland. Counts below were taken 2026-09-20.

There are **20 `*Lua()` builders** in `logic.js` (of 82 top-level functions). The suffix is
exhaustive: every function that emits Lua is named `*Lua`, and no function that emits Lua is not.
Keep it that way — it is what makes the surface greppable.

## Chunks and fragments are different things

The 20 builders split cleanly in two, and the distinction decides every other rule:

- **14 chunks** are dumped standalone by `tests/lua-check.sh` and must parse **alone**:
  `tiledInsertLua`, `setFloatLua`, `setFullscreenLua`, `unfullscreenLua`, `regrabFocusLua`,
  `closeAllLua`, `floatingMoveLua`, `workspaceMoveLua`, `workspaceSwapLua`, `scratchpadShowLua`,
  `scratchpadFocusLua`, `lockInstallLua`, `lockSyncLua`, `notifyLua`.
- **6 fragments** are never dispatched on their own and only ever composed into a chunk:
  `dispatchGuardLua`, `reportLua`, `fullscreenBodyLua`, `captureFocusLua`, `restoreFocusLua`,
  `restoreCursorLua`.

## A chunk is one line

All 14 chunks are a single line. Thirteen build readable multi-line source and collapse it on the
way out:

```js
    ).replace(/\n\s*/g, ' ')
```

`unfullscreenLua` is the fourteenth: it is short enough to be one line already and needs no
collapse. Write the multi-line form and flatten — do not hand-write a long single line.

Fragments do **not** flatten. `reportLua` says so at `logic.js:500`: *"Returns newline-separated
statements; the outermost chunk builder must flatten to one line."* Flattening in a fragment would
work, but it puts the responsibility in the wrong place and hides whether the composed result is
one line.

## Every chunk guards its dispatches

`hl.dispatch` never raises. A failed dispatcher — even one that hit a Lua error internally —
returns `{ ok = false, error = "..." }` (Hyprland 0.56.2, `LuaBindingsToplevel.cpp hlDispatch`).
So every chunk defines `run()` before its first `pcall`, via `dispatchGuardLua()`:

```lua
local function run(d) local r = hl.dispatch(d) if r and r.ok == false then error(tostring(r.error), 0) end return r end
```

Inside a `local ok, err = pcall(function() … end)` span, dispatch through `run()` and never
through bare `hl.dispatch`. Only the best-effort focus and cursor restore may stay raw: those are
allowed to fail without failing the operation. `tests/tst_layout.qml` asserts this per span, per
chunk. The reasoning is [[adrs/0002-compositor-dispatch-errors]].

Raise with an explicit level 0 — `error(msg, 0)`. Lua's default level prepends a
`[string "..."]:N:` position to a string message, and these messages reach the compositor log
and an on-screen notification through `reportLua`, where that prefix is noise. All 13 `error()`
calls in `logic.js` use level 0.

## Interpolated text: truncate first, then escape

`notifyLua` is the pattern. Slice the **raw** text, then escape:

```js
    var cut = raw.length > 200
    if (cut) raw = raw.slice(0, 200) + "…"
    var t = raw
        .replace(/\\/g, "\\\\")
        .replace(/"/g, "\\\"")
        .replace(/[\n\r\t]+/g, " ")
```

Escaping before truncating can cut an escape sequence in half and leave a lone trailing
backslash, which escapes the chunk's own closing quote and makes the whole chunk unparseable —
and the compositor drops an unparseable chunk **silently**. Newlines and tabs collapse to a space
because a chunk is one line.

## Adding a chunk

1. Name it `*Lua`.
2. Compose `dispatchGuardLua()` in before the first `pcall`, and `reportLua(what)` for the
   failure path.
3. Build multi-line, flatten with `.replace(/\n\s*/g, ' ')`.
4. Add it to the dump fixture in `tests/lua-check.sh` **and raise the count floor**
   (`lua-check.sh:84`, currently at least 24, actual 24). Leaving the floor alone means the guard
   silently stops covering the new chunk while still passing.
5. Extend the mock — see [[languages/lua/testing]].

## Language level

`tests/lua-check.sh` parses with the first of `lua5.4`, `lua` or `luajit` that is installed; CI
installs `lua5.4`. Because a developer may be checking under LuaJIT's 5.1 dialect, stay within
syntax all three accept. No chunk uses 5.4-only syntax today — no integer division, bit
operators, `goto`, `<const>` or `<close>`; the only `~` in emitted Lua is `~=`.

## See Also

- [[adrs/0002-compositor-dispatch-errors]] — why chunks are atomic and why `run()` exists.
- [[languages/javascript/code-style]] — the dialect the builders themselves are written in.
- [[languages/lua/testing]] — the mock and the behaviour suite.
- [[adrs/0003-test-tiers]] — where the parse and behaviour suites run.
