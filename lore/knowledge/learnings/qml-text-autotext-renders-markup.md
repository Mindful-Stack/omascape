---
title: "QML Text defaults to AutoText, which renders markup an untrusted title can carry"
description: "Text.textFormat defaults to Text.AutoText, which renders rich text whenever Qt::mightBeRichText() thinks a string looks like markup — including <img src=…>, which the engine fetches; every Text/Label in a shipped root .qml now declares textFormat: Text.PlainText, guarded by tests/plaintext.sh."
tags: [frameworks, quickshell, qml]
confidence: verified
source: developer-input
date: 2026-10-04
---

# QML Text defaults to AutoText, which renders markup an untrusted title can carry

## The finding

marketplace#9564 (reviewer HANCORE-linux, 2026-10-02): `Overview.qml` passed untrusted
application/window titles unchanged to `WindowTile.qml`'s title `Text`, whose `textFormat` was
left at Qt's default, `Text.AutoText`. `Text.AutoText` renders rich text whenever
`Qt::mightBeRichText()` decides a string looks like markup — and a webpage can set its own window
title, so a title containing `<img src="http://attacker/x">` made the shell fetch an
attacker-chosen URL, exposing the host's network address to it.

## Where untrusted strings actually reach a Text today

Controller audit, 2026-10-04: `WindowTile.qml`'s title (`:255` letter fallback, `:273` the title
label) and its window class fallback both carry window-manager-supplied strings; `Overview.qml`'s
`wsLabel()`-produced workspace numerals and badges (`:2577`, `:2589`, `:2636`, `:2848`) carry
configured workspace names; `SettingsPanel.qml:103` renders the settings file path. None of these
are attacker-controlled in the same direct sense as a window title, but all of them originate
outside this component.

## The rule

**Every `Text`/`Label` in a shipped root `.qml` declares `textFormat: Text.PlainText`**, not only
the ones a current audit finds untrusted. "Every Text is plain" is mechanically checkable; "only
the untrusted ones" is a judgement a future label — added after the audit, reviewed by someone who
never read this file — can silently get wrong. `tests/ui/find.qml`'s own query `Text` already
followed this rule before the audit (`FindBar.qml:36`, matched literally since the query is shown
back to the user who typed it); that was the one block of the 18 found that was already compliant.

## The guard

`tests/plaintext.sh`, wired into `tests/run.sh` right after `manifest.sh`. It scans every root
`*.qml` (the published runtime set — not `tests/`), finds each `Text {` / `Label {` block, and
requires a `textFormat: Text.PlainText` line at that block's own nesting level; a nested child
`Text` must carry its own, so a delegate inside a `Repeater` is checked independently of its
parent. It failed first, naming exactly 17 offenders (`ContextMenu.qml` ×2, `FindBar.qml` ×2,
`HintCap.qml` ×2, `Overview.qml` ×4, `SettingsPanel.qml` ×5, `WindowTile.qml` ×2), before the fix.

A companion UI test (`tests/ui/actions.qml`, `test_a_markup_title_renders_as_literal_text`) seeds a
window whose title is `<img src="http://127.0.0.1:1/x">`, finds the tile's title `Text` by its new
`objectName: "tileTitle"`, and asserts both `textFormat === Text.PlainText` and that the literal
markup string still reaches `text` unmodified — the fix must not sanitize or strip the title, only
stop the engine from interpreting it.

## What is deliberately out of scope

The bar button's glyph (`BarWidget.qml`, the host's `WidgetButton`) is rendered by Omarchy's own
`qs.Ui` component, not by a `Text` this repository owns — its glyph comes from the user's own
`settings.icon` (`omarchy bar set … icon <glyph>`), which is local configuration, not an untrusted
remote string, and the component itself is outside Omascape's control to begin with.

`ContextMenu.qml`'s menu labels are static strings from `Logic.menuItems` (verb names like "Close",
"Float", "Lock"), never window-supplied text — they get `textFormat: Text.PlainText` anyway,
because the rule is "every Text", not "every Text that needed it this time".

## See also

- [[frameworks/quickshell/component-patterns]] — the leaf-component conventions `Text` elements
  here otherwise follow.
