# Omascape — in-picker settings panel (design)

Date: 2026-09-20 · Target: Omarchy Quattro, Hyprland 0.56.2 (Lua config mode), Quickshell 0.3.1
Status: **designed, not built.**

## Goal

Make omascape's settings discoverable and changeable from inside the picker, instead of only by
hand-editing `~/.config/omarchy/omascape.json`.

## The problem

There are eight settings. To change one today you must know the file exists, know its path, know
the key names, and know the valid values — none of which the picker tells you. Until very
recently a typo also reverted *every* setting to its default in silence; that is now reported
(`Logic.configParseError`), but knowing a file is broken is not the same as knowing what belongs
in it.

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

- **It owns every key while open**, the way `menuOpen` already does. **Esc closes the panel, not
  the picker** — the single interaction detail most likely to be got wrong, and the one a test
  must pin.

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

- **The write preserves what it did not write.** `configWithKey(rawText, key, value)` parses the
  file's *existing text*, sets one key, and re-stringifies. JavaScript preserves insertion order
  for string keys, so hand-written ordering survives — and, more importantly, **any key the panel
  does not know about survives too**: an older panel must not silently delete a newer version's
  setting. Only the keys already present, plus the changed one, are written, so defaults are
  never pinned into the file.

- **The file is the single source of truth.** The write goes through `OmascapeConfig` with
  `FileView { atomicWrites: true }`, as `OmascapeLocks.qml` already does, and the existing
  watcher re-reads and applies it. No in-memory copy that can drift from the file. A failed
  write notifies, mirroring `onWriteFailed`.

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

**`OmascapeConfig.qml`** — `save(key, value)`, and a `writeFailed(why)` signal.

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

**UI suite (`tests/ui/settings.qml`, registered by hand in `tests/ui/run.sh`):**

- `ctrl+,` opens the panel; Esc closes the panel **and leaves the picker open** — with a
  companion asserting Esc still closes the picker when the panel is *not* open, so the fix
  cannot be "Esc never closes the picker".
- Arrows move the selection; left/right cycles the focused row's value.
- Changing a setting produces the expected write payload, recorded by a stub as the locks tests
  already do (`tests/ui/prepare.py`'s `writes: []`).
- The panel does not appear while the context menu or the find bar owns the keys.

**Live checks (not automatable here):** how the panel reads over the drop-down's wallpaper
backing, and that `ctrl+,` is not taken by anything in a real Hyprland session.
