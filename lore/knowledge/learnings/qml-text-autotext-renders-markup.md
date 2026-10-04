---
title: "QML Text defaults to AutoText, which renders markup an untrusted title can carry"
description: "Text.textFormat defaults to Text.AutoText, which renders markup like <img src=…> and fetches it; every Text/Label in a root .qml now declares textFormat: Text.PlainText, guarded by tests/plaintext.sh."
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

**Empirically confirmed**, offscreen (Qt 6.11.2, `QT_QPA_PLATFORM=offscreen`) against a local HTTP
listener standing in for the attacker's server: with `textFormat` left at `Text.AutoText`, or set
explicitly to `Text.StyledText` or `Text.RichText`, a title containing `<img src=…>` makes the
engine issue the request and the listener observes it; with `textFormat: Text.PlainText` the
listener sees nothing. `elide` and `wrapMode` make no difference either way — the fetch happens
during markup interpretation, before layout.

## Where untrusted or locally-sourced strings actually reach a Text today

Controller audit, 2026-10-04 (corrected 2026-10-04 after review found two of its claims wrong):

- `WindowTile.qml`'s title (`id: lbl`, `objectName: "tileTitle"`, ~`:275`) and the single-letter
  class-initial fallback (~`:255`) both carry window-manager-supplied strings — the directly
  untrusted case this finding is about.
- `Overview.qml`'s `wsLabel(id)` (~`:122`) feeds the `wsNumeral` and `wsBadgeText` elements. It
  returns only `"S"` (scratchpad), `"0"` (workspace 10) or `String(id)` for a small positive
  integer — **never a configured workspace name**; an earlier draft of this learning claimed
  otherwise and was wrong. The `lockGlyph` Text is a static Nerd Font glyph with no input at all.
  The one element in this file carrying a real external string is `monitorChip`, whose `text`
  includes `modelData.monitorName` — the Hyprland connector name (e.g. `DP-1`), local hardware
  information rather than a remote string, but still not a literal under this file's control.
- `ContextMenu.qml`'s labels are static verb strings from `Logic.menuItems` (`"Close"`, `"Float"`,
  `"Lock"`, …) **except** the `"Move to <monitor>"` / `"Swap with <monitor>"` rows, which splice in
  a monitor name — but `workspaceMenuRows` (`logic.js` ~`:1627`, `:1632`) only ever builds those
  rows from a name that has already passed `validMonitorName` (`logic.js` ~`:1599-1600`,
  `/^[A-Za-z0-9._-]+$/`), the same defence the move/swap Lua chunks require of it. No markup
  character survives that filter.
- `SettingsPanel.qml`'s rows show keys and values read back out of the user's own local config
  file (`OmascapeConfig.qml`), and the action row's path Text shows that file's own path
  (`panel.filePath`, ~`:114`) — local, user-controlled, not an untrusted remote input.

None of the above needed sanitizing; the rule below applies to them anyway because it does not
distinguish.

## The rule

**Every `Text`/`Label` in a shipped root `.qml` declares `textFormat: Text.PlainText`**, not only
the ones a current audit finds untrusted. "Every Text is plain" is mechanically checkable; "only
the untrusted ones" is a judgement a future label — added after the audit, reviewed by someone who
never read this file — can silently get wrong. `FindBar.qml`'s own query `Text` (`id: queryText`,
~`:38-39`; exercised by the UI suite's `tests/ui/find.qml`, which is a test file, not where the
element lives) already followed this rule before the audit, since the query is shown back to the
user who typed it — that was the one block of the 18 found that was already compliant.

## The guard

`tests/plaintext.sh`, wired into `tests/run.sh` right after `manifest.sh`. It strips `//` and
`/* */` comments and all string literals before scanning (so neither can forge a required line),
finds every `Text {` / `Label {` block **however it is introduced** — `delegate: Text {`, a
qualified `QQ.Text {`, several on one line, one nested inside another — by brace-depth rather than
by line-start position, and requires a `textFormat: Text.PlainText` line at that specific block's
own nesting level; a nested child's own `textFormat` never satisfies its parent's.

Independently, anywhere in the file: any `textFormat` write (`:` or `=`) whose value is not the
literal token `Text.PlainText` fails — numeric (`textFormat = 2`), parenthesised (`textFormat =
(Label.RichText)`), or any other shape, not only a near-miss enum name; any
`<ident>.(AutoText|StyledText|RichText|MarkdownText)` token fails, whatever its qualifier (not only
`Text`/`TextEdit`); any `createQmlObject` call fails outright, since a string it builds from could
contain a `Text` this scanner never sees inside; and the quoted string `"textFormat"` /
`'textFormat'` fails wherever it appears in the file's raw source, checked **before** comment/string
stripping specifically because stripping would hide it — `t["textFormat"] = 2` or a `Binding {
property: "textFormat"; … }` both reach the real property without ever writing the bare identifier
the checks above key on. It fails closed (a clear message, not a traceback) on a file with
unbalanced braces, an unterminated string, or an unterminated block comment.

**Known limit, accepted rather than fixed:** the stripper does not model JS regex literals, so a
`/"/`-shaped pair could in principle hide a `Text` the way a string does. Root `*.qml` contains no
regex literal today, and a regex belongs in `logic.js` by convention anyway
(`lore/knowledge/languages/javascript/tooling-dialect.md`), so this is a known gap in a static
scan, not a bug being tracked.

Its own correctness is guarded in turn by `tests/plaintext-selftest.sh` (also wired into
`tests/run.sh`), which feeds it one throwaway fixture file per known bypass across two rounds of
adversarial review — not-line-start openers, a qualified type name, a comment or string forging the
required line, a brace inside a string that must not shift the nesting count, a nested child
satisfying its parent, a near-miss enum name (`Text.PlainTextX`), an explicit non-`PlainText` value
via `:` or `=`, a bare banned token under an unrelated property name, a numeric or parenthesised
dynamic write, `textFormat` reached as a quoted property name (bracket access or a `Binding`), and a
bare `createQmlObject` call — and asserts the guard rejects every one, plus two shapes it must still
accept (an inline `delegate: Text { textFormat: Text.PlainText; … }`, and a parent and child Text
each carrying its own). 24 fixtures in total.

A companion UI test (`tests/ui/actions.qml`, `test_a_markup_title_renders_as_literal_text`) seeds a
window whose title is `<img src="http://127.0.0.1:1/x">`, finds the tile's title `Text` by its new
`objectName: "tileTitle"`, and asserts both `textFormat === Text.PlainText` and that the literal
markup string still reaches `text` unmodified — the fix must not sanitize or strip the title, only
stop the engine from interpreting it.

## What is deliberately out of scope

The bar button's glyph (`BarWidget.qml`, the host's `WidgetButton`) is rendered by Omarchy's own
`qs.Ui` component, not by a `Text` this repository owns, and its own label `Text` already declares
`textFormat: Text.PlainText` itself (`/usr/share/omarchy/shell/Ui/WidgetButton.qml` ~`:75-77`) — so
there is no exposure here regardless. Its text comes from the user's own `settings.icon` (`omarchy
bar set … icon <glyph>`) in any case, which is local configuration, not a remote string.

## See also

- [[frameworks/quickshell/component-patterns]] — the leaf-component conventions `Text` elements
  here otherwise follow.
