# Omascape — in-picker settings panel (design)

Date: 2026-09-20 · Target: Omarchy Quattro, Hyprland 0.56.2 (Lua config mode), Quickshell 0.3.1
Status: **designed, not built.**

## Goal

Make omascape's settings discoverable and changeable from inside the picker, instead of only by
hand-editing `~/.config/omarchy/omascape.json`.

## The problem

There are eight settings. To change one today you must know the file exists, know its path, know
the key names, and know the valid values — none of which the picker tells you.

A typo used to revert *every* setting to its default in silence. `Logic.configParseError` now
reports that — but ✎ *(corrected after review, 2026-09-20)* it catches **syntax and root shape
only**. An invalid *value* still defaults silently: `{"anchor":"barr"}` parses cleanly,
`configParseError` returns `""`, and `parseConfig` hands back `"center"` with nothing said
(verified). So half the original problem is still live, and it is the half a panel actually
fixes — **you cannot typo a value you pick from a list.**

## What Omarchy does not offer

Checked in `/usr/share/omarchy/shell`, because it bounds every option:

| | |
|---|---|
| Plugin manifest schema v1 reads only `id`, `kinds`, `entryPoints`, `barWidget`, `schemaVersion`, `omarchy` | `services/PluginRegistry.qml:48` |
| `omarchy-plugin-add` runs **no install hooks** — nothing of ours can execute at install time | `/usr/share/omarchy/bin/omarchy-plugin-add` |
| No plugin-settings extension point; every panel under `plugins/panels/` is first-party | — |

So a settings surface has to be something omascape draws itself. That is also why shipping a
default `omascape.json` was rejected: nothing can install it, and a file pinning all eight
defaults would silently freeze them when a future version changes one.

## Scope

**In:** a keyboard-driven panel inside the picker; seven settings editable in place; atomic
persistence; the pure functions behind all of it.

**Out:** a colour picker; changing the config schema; any Omarchy-side integration; a CLI.

## Decisions

- **Its own component.** `SettingsPanel.qml`, sibling to `FindBar.qml`, `ContextMenu.qml` and
  `HintCap.qml`, taking colours, fonts and values as properties exactly as those do. It renders
  rows and emits a change request; it never reads config or touches a file. `Overview.qml` is
  ~2300 lines and the whole-branch review of the drop-down already noted it; this must not add
  to it.

- **`ctrl+,` opens it.** `ctrl+S`, `ctrl+L` and `ctrl+W` are taken (`Overview.qml:2145-2147`),
  and a bare `,` would be swallowed by find-as-you-type, which accepts printable characters.
  ✎ *(verified after review: the chord branch at `:2143` `return`s unconditionally, so `ctrl+,`
  is currently consumed and does nothing — free, and it never reaches the query.)*

- **It owns every key while open**, the way `menuOpen` already does — but ✎ *(expanded after
  review: "owns every key" does not specify the transitions, and four of them already have
  established handling elsewhere in this file)*:

  - **Opening it aborts a peek.** A modal and a peek are mutually exclusive; the menu already
    calls `peekAbort()` for this (`Overview.qml:967`).
  - **The menu and the confirmation dialog stay ahead of it** in the key routing
    (`Overview.qml:2092`). Inside the menu, `ctrl+,` dismisses the menu and is consumed — it does
    not also open settings.
  - **Space pressed while the panel is open must not start a peek on release.** The confirmation
    branch already tracks exactly this (`Overview.qml:2093`), and Space-release cleanup
    (`:2210`) must keep running even while the panel owns key *presses*.
  - **It does not open mid-search** (`!finding`). Find-as-you-type does not own the ctrl chords —
    the existing `ctrl+S`/`ctrl+L`/`ctrl+W` all fire during a query (`:2143-2147`) — so without an
    explicit guard the panel would open there by inheritance rather than by choice. ✎ *(decided
    while planning, 2026-09-20: it does not.* A query is a transient mode with its own Esc
    semantics, and a modal stacked on it gives Esc three meanings. Clear the query first.*)*

- **Esc is a sequence here, not a single action.** ✎ *(corrected after review.)* Today Esc clears
  the window cursor, then the query, and only then closes the picker (`Overview.qml:2150-2153`),
  and menus and the confirmation dialog intercept it earlier still. Panel-local Esc routes
  *before* that branch, and the companion test must therefore establish no cursor, no query, no
  menu and no confirmation dialog — otherwise it is asserting against a branch that never ran.
  The closing Esc also swallows its own auto-repeats until release, the way `menuDismissKey`
  does (`:996`), so holding Esc cannot dismiss the panel and the picker in one press.

- **Seven editable, one not.**

  | setting | control |
  |---|---|
  | `anchor` | centre ‹ › bar |
  | `activate` | enter ‹ › select |
  | `scrim` | on ‹ › off |
  | `hint` | on ‹ › off |
  | `motion` | auto ‹ full ‹ off |
  | `workspaces` | 0–20 stepper |
  | `lockBorderSize` | 0–20 stepper |

  `lockBorder` is an `rgb(hhhhhh)` / `rgba(hhhhhhhh)` string and needs a real colour picker to
  edit sanely. It is shown with its current value and the file path rather than pretended at.

  `workspaces` steps to 20 in the panel; `parseConfig` still accepts any non-negative number, so
  a larger value remains a file edit. The panel's range is a UI convenience, not a schema change.

- **The write requires an OBJECT root, not merely parseable text.** ✎ *(rewritten after review.)*
  An earlier draft rejected only text that fails to parse. That is not enough, and the failure is
  silent: `JSON.parse("[1,2]")` succeeds, setting a property on the array is dropped by
  `JSON.stringify`, and the user would press a key, see nothing change, and have their file
  rewritten without the setting. `null` is worse — assigning to it **throws**. Scalars drop the
  key the same way as arrays. All verified.

  `configWithKey` therefore returns `""` unless the parsed root is a non-null, non-array object.
  Whitespace-only text counts as `{}`, since that is a legitimate empty config.

- **What the write preserves, stated honestly.** ✎ *(narrowed after review.)* An earlier draft
  promised unknown keys survive "verbatim". Parse/stringify does not give that:

  | input | after a round trip |
  |---|---|
  | `{"future":9007199254740993}` | `9007199254740992` — precision lost |
  | `{"future":1e400}` | `null` — beyond double range |
  | `{"a":1,"a":2}` | `{"a":2}` — duplicates collapse |
  | `{"future":1.0}` | `1` — cosmetic |

  The real guarantee is narrower and still worth having: **unknown keys survive semantically**,
  and insertion order survives, so an older panel does not delete a newer version's setting. It
  is not a lossless editor, and this file realistically holds small numbers, short strings and
  booleans. A lossless JSON editor is not worth building for eight known keys; the limitation is
  documented instead of hidden.

  Only the keys already present, plus the changed one, are written, so defaults are never pinned
  into the file.

- **Optimistic in memory, then persisted.** ✎ *(rewritten after review — the earlier
  "watcher is the single source of truth" was wrong.)* If the displayed value only changed once
  the watcher had re-read the file, two quick presses would both compute their next value from
  the *stale* one: `workspaces` 10 → two Rights → both request 11, and one increment vanishes.
  `FileView.text()` is cached, so a read-modify-write can also clobber an external edit made
  between the cached read and the replacement. Atomic replacement prevents a torn file; it does
  nothing about a stale read.

  So the panel updates its own value immediately and then writes — which is what
  `OmascapeLocks.qml:52` already does, updating memory *before* persisting. The watcher's later
  reload reconciles. On a failed write the panel reverts to what the file still says and
  notifies.

  There is no feedback loop: `OmascapeConfig.qml`'s load path applies properties and never
  writes.

## Changes

**`logic.js` — three pure functions:**

- `settingsRows(cfg)` → the rows to render: key, label, current value, the values it cycles
  through, and whether it is editable.
- `nextSettingValue(key, current, dir)` → the next value in a cycle, including the numeric
  clamps. Total: an unknown key or a non-finite current returns the current value unchanged.
- `configWithKey(rawText, key, value)` → the new file text. Returns `""` when the existing text
  cannot be parsed, so a broken file is never overwritten with a guess — the panel reports it
  instead of destroying whatever the user was in the middle of writing.

**`SettingsPanel.qml`** — rows, selection, and a `changeRequested(key, value)` signal.

**`OmascapeConfig.qml`** — `save(key, value)`, and a `writeFailed(why)` signal raised from `FileView`'s `onSaveFailed`. The save path must also distinguish *missing* from *failed to read*: the current loader collapses every load failure into defaults, which is fine for display but is not authorisation to replace a file with `{ changedKey: value }`. `OmascapeLocks.qml:72` already makes that distinction.

**`Overview.qml`** — `ctrl+,` opens, key routing while open, and the panel instance.

## Edge cases

- **A malformed config file.** `configWithKey` returns `""` and nothing is written; the panel
  says the file must be fixed first. Overwriting it would discard whatever the user was editing.
- **The file does not exist.** Writing creates it, containing only the changed key.
- **A key the panel does not know.** Preserved verbatim through the parse/stringify round trip.
- **A write failure** (read-only home, full disk). Notified, and the panel's displayed value
  falls back to what the file still says, because the file is the source of truth.
- **The config changes on disk while the panel is open.** The watcher applies it and the panel's
  rows follow, since they are bound to the config object rather than to a snapshot.

## Tests

**Tier 1 (`logic.js`, pure):**

- `settingsRows`: every key in `parseConfig`'s output appears exactly once — the assertion that
  fails when a future setting is added and the panel is not updated, which is the only way this
  silently rots.
- `nextSettingValue`: each enum cycles and wraps; the two steppers clamp at both ends; an
  unknown key and a non-finite current are returned unchanged.
- `configWithKey`: a key is set; **an unknown key survives**; key order survives; a file that
  does not parse yields `""`; an empty file yields a file with just that key.

**What the offscreen fixture CANNOT prove.** ✎ *(added after review.)* `tests/ui/prepare.py`
replaces `OmascapeConfig.qml` wholesale, so a stubbed `save()` can only show that `Overview`
*requested* the right change. It cannot show that production persistence preserves keys, handles
a failed write, or behaves under rapid edits — the locks fixture disclaims exactly this for the
same reason. Serialization is covered by the Tier 1 tests above; **the production write path is a
live check**, not something a green UI suite attests to. The new component must also be copied
into the fixture alongside the others, or the suite silently tests nothing.

**UI suite (`tests/ui/settings.qml`, registered by hand in `tests/ui/run.sh`):**

- `ctrl+,` opens the panel; Esc closes the panel **and leaves the picker open** — with a
  companion asserting Esc still closes the picker when the panel is *not* open, so the fix cannot
  be "Esc never closes the picker". That companion must first establish no cursor, no query, no
  menu and no confirmation dialog, or it asserts against a branch that never ran.
- Esc's existing sequence is intact: with a cursor set it clears the cursor; with a query and no
  cursor it clears the query; only then does it close.
- Opening the panel aborts an in-flight peek, and Space pressed while the panel is open does not
  start one on release.
- Arrows move the selection; left/right cycles the focused row's value.
- Changing a setting produces the expected write payload, recorded by a stub as the locks tests
  already do (`tests/ui/prepare.py`'s `writes: []`).
- The panel does not appear while the context menu or the find bar owns the keys.

**Live checks (not automatable here):** how the panel reads over the drop-down's wallpaper
backing, and that `ctrl+,` is not taken by anything in a real Hyprland session.
