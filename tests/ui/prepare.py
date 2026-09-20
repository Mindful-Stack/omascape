"""Build an offscreen fixture from production QML; replace only shell/compositor adapters.
MouseArea events, ListModel, bindings, timers and reconciliation run unchanged in Qt.
"""
import struct
import zlib
from pathlib import Path
import json
import re
import sys
source, dest = map(Path, sys.argv[1:])


def replaced(text, old, new, what, count=1):
    """Substitute `old` exactly `count` times, failing loudly on any other number.

    Several of these substitutions stand in for the compositor (layer-shell anchors resolving to
    real geometry, Variants creating one delegate per screen). A silently missed replacement would
    leave the fixture with zero-sized or uninstantiated surfaces, which reads in the suite as
    "the feature is broken" — this says which line moved instead.

    The count is part of that guard, not decoration: there are now two per-screen `Variants` blocks
    (the lock frame and the click-catcher) and each is keyed on its own delegate type. Were a third
    one to be added, or a delegate renamed, matching "somewhere" is no longer enough — a block
    silently taking the other block's treatment is exactly the failure this catches.
    """
    hits = text.count(old)
    if hits != count:
        raise SystemExit('prepare.py: %s matches %d time(s), expected %d; update the fixture'
                         % (what, hits, count))
    return text.replace(old, new)


qml = (source / 'Overview.qml').read_text()
qml = re.sub(r'^import (Quickshell.*|qs\..*)\n', '', qml, flags=re.M)
qml = re.sub(r'Color\.menu\.\w+', '"#888888"', qml)
# Bar-mode paints Color.bar.background (Bar.qml:71), a different token from the menu one. Same
# treatment as Color.menu.*: there is no Color singleton here, and an unresolved reference does
# NOT fail to compile — it degrades SILENTLY, a QWARN ReferenceError at runtime with the suite
# still passing. Any future use of another Color.* namespace needs its own rewrite here, or
# nothing will catch it short of the guard below.
qml = re.sub(r'Color\.bar\.\w+', '"#777777"', qml)
# Loud-failure guard: an unresolved Color.* reference is a QWARN, not a compile error, so a
# missing rewrite above would otherwise let every suite pass green against a binding that is
# silently broken at runtime. Make that failure impossible to miss instead of merely documented.
leftover = re.findall(r'Color\.\w+(?:\.\w+)?', qml)
if leftover:
    raise SystemExit('prepare.py: unresolved Color reference(s) in the fixture: '
                     + ', '.join(sorted(set(leftover)))
                     + ' -- add a rewrite above, or the suites will pass while the '
                       'binding silently fails at runtime.')
qml = re.sub(r'Style\.\w+FillAlpha', '0.1', qml)
qml = re.sub(r'Style\.font\.\w*Family', '"sans-serif"', qml)
qml = re.sub(r'Style\.font\.\w+', '11', qml)
qml = re.sub(r'Style\.space\((\d+)\)', r'\1', qml)
qml = qml.replace('Hyprland.', 'compositor.').replace('target: Hyprland', 'target: compositor')
# The two per-screen instantiations — the share-time reminder frame and the click-catcher for the
# screens the overview is NOT on. Quickshell's `Variants` has no offscreen equivalent; `Repeater`
# creates one delegate per array entry with the same `modelData` injection, and the fixture root is
# an Item so both land under it. Each is keyed on its own delegate type, so a block that grew, moved
# or changed delegate fails here instead of silently taking the other block's treatment. Done BEFORE
# the generic `Quickshell.screens` substitution so both models are the test-controlled screen list.
qml = replaced(qml, '''    Variants {
        model: Quickshell.screens
        LockFrame {''', '''    Repeater {
        model: root.testScreens
        LockFrame {''', 'LockFrame Variants block')
# The catcher's own stacking is fixture-only. In the shell each catcher is a separate layer surface
# on a separate monitor, so the overview's surface is never above it — that is the whole point. Here
# every window is a sibling Item under one root and the overview's panel is the LAST sibling, so
# without this z the panel's scrim would swallow a press aimed at another screen's catcher and the
# suite could not tell a working catcher from a missing one.
qml = replaced(qml, '''    Variants {
        model: Quickshell.screens
        PanelWindow {''', '''    Repeater {
        model: root.testScreens
        Item {
            z: 1000''', 'catcher Variants block')
# focusedScreen() resolves Hyprland's focused monitor to one of Quickshell's screens and hands the
# object back; `open()` stores it as `targetScreen`, which the catcher then compares delegates
# against BY IDENTITY. Pointing it at the same test-controlled list is what makes that identity real
# in the fixture (suites that leave `testScreens` empty keep the old behaviour: targetScreen null).
qml = replaced(qml, 'screens = Quickshell.screens || []', 'screens = root.testScreens || []',
               'focusedScreen screen list')
qml = qml.replace('Quickshell.screens', '[]').replace('ToplevelManager.toplevels', 'null')
qml = qml.replace('PanelWindow {', 'Item {')
qml = re.sub(r'^\s*(screen: root\.targetScreen|screen: modelData|WlrLayershell\..*|exclusionMode:.*|color: "transparent"|mask: .*|Region \{ id: emptyRegion \})\n', '\n', qml, flags=re.M)
qml = qml.replace('anchors { top: true; bottom: true; left: true; right: true }', 'width: 1200; height: 800')
qml = qml.replace('id: root', '''id: root
    property alias testModel: tilesModel
    property alias testFlick: flick
    property alias testCanvas: canvas
    property alias testDropWash: dropWash
    property alias testFrame: selectionFrame
    property alias testPanel: panel
    property alias testCard: card
    property alias testScrim: scrimRect
    property alias testShadow: cardShadow
    property alias testWallpaper: wallpaperBack
    property alias testHintGlass: bottomBarGlass
    property alias testConfig: config
    property alias testLocks: locks
    property alias testEnterAnim: enterAnim
    property alias testKeys: keyCatcher
    property alias testBar: findBar
    // Compile-time dependency on the `hintKeys` id in Overview.qml: renaming or removing that
    // id breaks every UI suite at once with "Invalid alias reference", not just Scratchpad's.
    property alias testHintModel: hintKeys.model
    property alias testHintRow: hint
    // Compile-time dependency on the `hintKeys2` id in Overview.qml: renaming or removing that
    // id breaks every UI suite at once with "Invalid alias reference", not just Lock's.
    property alias testHintModel2: hintKeys2.model
    // Compile-time dependency on the `peekLayer` id in Overview.qml: renaming or removing that
    // instance breaks every UI suite at once with "Invalid alias reference", not just Peek's.
    property alias testPeek: peekLayer
    property var testScreens: []
    property QtObject compositor: QtObject {
        property var monitors: ({values: []})
        property var workspaces: ({values: []})
        property var focusedMonitor: null
        property var focusedWorkspace: null
        property var commands: []
        signal rawEvent(var event)
        function dispatch(command) { commands = commands.concat([command]) }
        property int refreshes: 0
        function refreshToplevels() { refreshes++ }
        function refreshWorkspaces() {}
        // Counted, not a no-op: the share-time reminder frame reads a monitor SNAPSHOT
        // (lastIpcObject), so which raw events ask for a fresh one is behaviour under test.
        property int monitorRefreshes: 0
        function refreshMonitors() { monitorRefreshes++ }
        // Hyprland.monitorFor(ShellScreen) -> HyprlandMonitor. The fixture matches on name, which
        // is what the real one resolves through too.
        function monitorFor(s) {
            var ms = monitors ? monitors.values : []
            for (var i = 0; i < ms.length; i++) if (s && ms[i].name === s.name) return ms[i]
            return null
        }
    }
    // Lets the locks stub's persist() record how many commands the compositor has seen so far
    // (see the stub's `writeAt`), pinning that the sync always lands before the write.
    Binding { target: locks; property: "compositorRef"; value: compositor }
''', 1)
(dest / 'Overview.qml').write_text(qml)
# Keep the real tile hover, scale and stacking bindings; replace capture-only visuals.
tile = (source / 'WindowTile.qml').read_text()
tile = re.sub(r'^import Quickshell.*\n', '', tile, flags=re.M)
tile = re.sub(r'Quickshell.iconPath\(.*\)', '""', tile)
# ClippingRectangle (Quickshell.Widgets) has no offscreen equivalent; a plain Rectangle keeps
# every property used here (radius, border.*) valid, including `radius` itself — which the peek
# suite now reads back via testCornerRadius below, converting Task 5's own live-check-only item
# (the peek tile's corners matching the card's radius, not the grid's) into a real assertion.
# Losing the actual child-clipping is fine — nothing this tier asserts on depends on it.
tile = replaced(tile, '    ClippingRectangle {',
                       '    Rectangle {\n        id: capFrame',
                 'ClippingRectangle wrapper')
# ScreencopyView (Quickshell.Wayland) can't run offscreen either, but unlike the wrapper above its
# own state is exactly what the icon-fallback and grace-period bindings that follow react to, so
# it is stubbed rather than deleted. Matched on only its 2-line header, NOT the whole body: the
# `visible`, `captureSource` and `live` lines below stay byte-for-byte production code, now
# assigning onto bare properties instead of the real type's. That is deliberately narrower than
# "every binding runs unmodified" might suggest — `captureSource` and `live` are declared with no
# behaviour behind them, so this stub cannot itself notice a bug in how the real ScreencopyView
# would REACT to them. What it does catch: a rename of `WindowTile.handle` or `capMode` still
# fails loudly (an undefined-property binding error), because `captureSource: tile.wantCapture ?
# tile.handle : null` — the one line standing between "icon" mode and a capture request reaching a
# locked workspace's window — is the literal expression still running here, not a paraphrase of
# it. `hasContent` is pinned to false: precisely what the real type would report offscreen anyway
# (no compositor, no captured frame, ever arrives).
tile = replaced(tile, '        ScreencopyView {\n            id: cap\n',
                       '''        Item {
            id: cap
            property bool hasContent: false
            property var captureSource
            property bool live
''', 'ScreencopyView capture stub')
# The icon-fallback Image carries no id in production (nothing there needs one) — the peek
# icon-flash suite (tests/ui/peek.qml) needs one to read `visible` back. There is only one Image
# in this file, so matching on its header plus the very next line is unambiguous.
tile = replaced(tile, '        Image {\n            anchors.centerIn: parent',
                       '        Image {\n            id: iconImg\n            anchors.centerIn: parent',
                 'icon Image id')
# The letter-fallback Text, same reasoning — but NOT matched the same way: this file has a SECOND
# Text (the title label, `id: lbl`) whose own `anchors.centerIn: parent` sits on the very same
# line as its id, purely because that one packs multiple bindings per line. Keying on "Text {" +
# next-line-anchors the way the Image match above does would be coincidentally unique only for as
# long as that formatting choice holds — two unrelated edits away from silently retargeting this
# id onto the title label instead, which would make testLetterVisible read a property that never
# changes and pass every assertion vacuously. Keying on the fallback's own unique `visible`
# expression instead ties this to what the element actually IS, not how it happens to be
# formatted today.
tile = replaced(tile, '''        Text {
            anchors.centerIn: parent
            visible: !cap.visible && tile.iconUrl.length === 0 && (!tile.graceActive || tile.graceElapsed)''',
                       '''        Text {
            id: letterFallback
            anchors.centerIn: parent
            visible: !cap.visible && tile.iconUrl.length === 0 && (!tile.graceActive || tile.graceElapsed)''',
                 'letter-fallback Text id')
tile = replaced(tile, '    id: tile\n',
                       '''    id: tile
    property alias testIconVisible: iconImg.visible
    property alias testLetterVisible: letterFallback.visible
    property alias testCornerRadius: capFrame.radius
''', 'tile id (test alias anchor)')
(dest / 'WindowTile.qml').write_text(tile)
(dest / 'logic.js').write_text((source / 'logic.js').read_text())
# Share-time reminder frame: the same treatment as Overview.qml's own PanelWindow — layer-shell
# properties dropped, the window itself an Item. The anchors are what the compositor resolves into
# a size, so the fixture resolves them itself, from the screen the strip was given: every strip
# spans its whole edge (the side strips the full height, the top/bottom ones the full width — it is
# their PAINT that is inset). The strip's thickness is NOT resolved here — the `implicit*` line and
# the painted `Rectangle` are carried through verbatim and Qt applies them to the Item, so the suite
# measures the real numbers, including the device-pixel snapping of `frame.surfaceSize`. Each
# replacement is keyed to the exact anchor set, to that `implicit*` line and to the paint's own
# anchors (which edge it hugs, and its margins), so changing any of them fails here rather than
# silently producing a strip the geometry tests would then "pass" on.
frame = (source / 'LockFrame.qml').read_text()
frame = re.sub(r'^import Quickshell.*\n', '', frame, flags=re.M)
frame = frame.replace('Scope {', 'Item {').replace('PanelWindow {', 'Item {')
frame = re.sub(r'^\s*(screen: frame\.frameScreen|WlrLayershell\..*|exclusionMode:.*|color: "transparent"'
               r'|mask: \w+|Region \{ id: \w+ \})\n', '', frame, flags=re.M)
def fill_h(edge):
    return '''        Rectangle {
            objectName: "lockFrameFill"; color: frame.frameColor
            anchors { %s: parent.%s; left: parent.left; right: parent.right
                      leftMargin: frame.thickness; rightMargin: frame.thickness }
            height: frame.thickness
        }
''' % (edge, edge)


def fill_v(edge):
    return '''        Rectangle {
            objectName: "lockFrameFill"; color: frame.frameColor
            anchors { %s: parent.%s; top: parent.top; bottom: parent.bottom }
            width: frame.thickness
        }
''' % (edge, edge)


for edge in ('top', 'bottom'):
    frame = replaced(frame, '''        anchors { %s: true; left: true; right: true }
        implicitHeight: frame.surfaceSize
''' % edge + fill_h(edge), '''        width: frame.frameScreen ? frame.frameScreen.width : 0
        implicitHeight: frame.surfaceSize
''' + fill_h(edge), 'LockFrame %s strip anchors + surface + paint' % edge)
for edge in ('left', 'right'):
    frame = replaced(frame, '''        anchors { top: true; bottom: true; %s: true }
        implicitWidth: frame.surfaceSize
''' % edge + fill_v(edge), '''        height: frame.frameScreen ? frame.frameScreen.height : 0
        implicitWidth: frame.surfaceSize
''' + fill_v(edge), 'LockFrame %s strip anchors + surface + paint' % edge)
(dest / 'LockFrame.qml').write_text(frame)
(dest / 'FindBar.qml').write_text((source / 'FindBar.qml').read_text())   # no shell imports: verbatim
(dest / 'HintCap.qml').write_text((source / 'HintCap.qml').read_text())   # no shell imports: verbatim
(dest / 'ContextMenu.qml').write_text((source / 'ContextMenu.qml').read_text())  # no shell imports: verbatim
(dest / 'SettingsPanel.qml').write_text((source / 'SettingsPanel.qml').read_text())  # no shell imports: verbatim
# No shell imports, so almost verbatim — except the window-peek's own WindowTile carries no id in
# production (nothing there needs one either), and the icon-flash grace suite (tests/ui/peek.qml)
# needs a way to reach it. Same test-only-plumbing pattern as the WindowTile.qml block above: give
# it an id and re-expose it as a plain alias on `peek`. The mini-map's own Repeater already has an
# id in production (`miniMap`, used by peek.fit above it) — re-exposed the same way, so the suite
# can reach a FRESHLY-created mini-map tile (one instantiated with no handle poked in at all,
# unlike the long-lived window-peek tile) via `testMiniMap.itemAt(i)`.
peeklayer = (source / 'PeekLayer.qml').read_text()
peeklayer = replaced(peeklayer, '''        WindowTile {
            anchors.fill: parent
            visible: peek.isWindow''', '''        WindowTile {
            id: peekWindowTile
            anchors.fill: parent
            visible: peek.isWindow''', 'window-peek WindowTile id')
peeklayer = replaced(peeklayer, '    id: peek\n',
                                  '''    id: peek
    property alias testWindowTile: peekWindowTile
    property alias testMiniMap: miniMap
''', 'peek id (test alias anchor)')
(dest / 'PeekLayer.qml').write_text(peeklayer)
# Shell-only helpers: the config loader needs Quickshell.Io, the shadow a GPU shader.
# `motionEffective` is writable here so tests can flip the policy without a compositor.
# `workspaces` defaults to 0 (no padding) so the fixture shows exactly the compositor's
# workspaces; tests that cover padding switch it on themselves.
(dest / 'OmascapeConfig.qml').write_text(
    'import QtQuick\nQtObject { property bool scrim: true; property bool hint: true\n'
    '           property int workspaces: 0\n'
    '           property string activate: "enter"\n'
    '           property string motion: "auto"; property string motionEffective: "full"\n'
    '           property string anchor: "center"\n'
    '           property bool barTransparent: false\n'
    '           property string wallpaperUrl: ""\n'
    '           function probeWallpaper() {}\n'
    '           property bool motionResolved: true\n'
    '           property string lockBorder: "rgb(ff4444)"; property int lockBorderSize: 6\n'
    '           signal invalidFile(string why)\n'
    '           function emitInvalid(why) { invalidFile(why) }\n'
    '           function probeMotion() {}\n'
    '           property var writes: []\n'
    '           signal writeFailed(string why)\n'
    # SettingsPanel.filePath binds to config.path (Overview.qml) rather than a hardcoded
    # string, so it must exist here too or that binding evaluates to undefined.
    '           property string path: "~/.config/omarchy/omascape.json"\n'
    # Emits writeFailed asynchronously, standing in for a real save() that DISPATCHED
    # successfully (saveAll returns true) and then failed later, off the return value
    # applySettingChange actually checks. Only the signal can report that case.
    '           function emitWriteFailed(why) { writeFailed(why) }\n'
    # configChanged is emitted by the real apply() on every reload; Overview's settingsPending
    # watcher listens for it. This stub never reloads a file, so it is declared (Connections
    # would otherwise warn against a target with no such signal) but never emitted.
    '           signal configChanged()\n'
    # Records that a change was REQUESTED, and nothing more: the real saveAll() reads the file's
    # current text, applies every key through Logic.configWithKey and writes atomically, none of
    # which this wholesale-replaced stub can exercise. Preservation, atomicity and failure
    # handling are covered elsewhere (Task 3's Tier 1 tests for configWithKey; the write path
    # itself is a live check) -- same disclaimer as the OmascapeLocks stub above, same reason.
    #
    # Records the WHOLE map on each call, not one key=value pair: applySettingChange sends every
    # unconfirmed change on every save (a real second write cancels the first and would otherwise
    # lose it -- see Overview.qml's applySettingChange), so a test asserting on a single write's
    # content must see every key that call carried, not just the newest one.
    #
    # `failSaves` lets a test exercise the refusal branch of applySettingChange (a real refusal
    # is an unreadable/unparseable file, neither of which this stub can produce) while still
    # recording the attempt, so a test can assert BOTH that the write was requested and that it
    # was refused.
    '           property bool failSaves: false\n'
    '           function saveAll(values) {\n'
    '               var parts = []\n'
    '               for (var k in values) parts.push(k + "=" + values[k])\n'
    '               writes = writes.concat([parts.join(",")])\n'
    '               return !failSaves\n'
    '           }\n'
    '           }\n')
# Lock state stub: the real OmascapeLocks.qml watches two files through Quickshell.Io. The stub
# keeps the one property later tests depend on — `armed` is null until a load resolves — and
# records writes instead of touching disk. Real file watching, atomic rename and load ordering
# are NOT reproduced here (live check); `refresh()` is a no-op for the same reason.
# `toggleInMemory()` and `loadArmed()` share Logic.toggleSelector/Logic.applyLocksTo with the
# real component, so both agree on when a toggle is refused and — via applyLocksTo's array
# comparison — on when a repeated load actually changed anything (an identical `loadArmed` must
# not re-fire `loadedArmed()`, or every reload echo would re-sync and re-rebuild for nothing).
# `compositorRef` (wired by a `Binding` where this stub is used) lets `persist()` record, per
# write, how many commands the compositor had already seen (`writeAt`) — pinning that the
# caller's sync always lands before the write, per the split `toggleInMemory`/`persist` ordering.
(dest / 'OmascapeLocks.qml').write_text(
    'import QtQuick\nimport "logic.js" as Logic\nQtObject {\n'
    '    property var armed: null\n'
    '    property bool sharing: false\n'
    '    property var writes: []\n'
    '    property var writeAt: []\n'
    '    property QtObject compositorRef: null\n'
    '    property bool failWrites: false\n'
    '    property int writeFailures: 0\n'
    '    signal loadedArmed()\n'
    '    signal writeFailed(string why)\n'
    '    signal invalidFile(string why)\n'
    '    function isArmed(sel) { return armed !== null && armed.indexOf(sel) >= 0 }\n'
    '    function placeholder(sel) { return isArmed(sel) && sharing }\n'
    '    function refresh() {}\n'
    '    function loadArmed(arr) {\n'
    '        var r = Logic.applyLocksTo(armed, JSON.stringify({ armed: arr }), "ok")\n'
    '        armed = r.armed\n'
    '        if (r.changed) loadedArmed()\n'
    '    }\n'
    '    function setSharing(on) { sharing = on }\n'
    '    function emitInvalid(why) { invalidFile(why) }\n'
    '    function toggleInMemory(sel) {\n'
    '        var next = Logic.toggleSelector(armed, sel)\n'
    '        if (next === null) return false\n'
    '        armed = next\n'
    '        return true\n'
    '    }\n'
    '    function persist() {\n'
    '        writeAt = writeAt.concat([compositorRef ? compositorRef.commands.length : -1])\n'
    '        if (failWrites) { writeFailures++; writeFailed("stub") }\n'
    '        else writes = writes.concat([JSON.stringify({ armed: armed })])\n'
    '    }\n'
    '}\n')
# Emulates shell.qml's manifest-driven Loader.active (shell.qml:623-626): a standalone fixture
# file so the shell-like Loader in tst_drag.qml can read keepLoaded without a circular reference
# through the Overview instance it is itself loading.
keep_loaded = json.loads((source / 'manifest.json').read_text()).get('keepLoaded') is True
(dest / 'Manifest.qml').write_text(
    'import QtQuick\nQtObject { readonly property bool keepLoaded: %s }\n'
    % ('true' if keep_loaded else 'false'))
# SoftShadow stub: the real one is a RectangularShadow (a shader item the offscreen platform
# has no use for), but its DEFAULTS are behaviour, not decoration -- the halo reaches
# `blur - offset.y` above its target, which is what decides whether the bar-mode card paints
# over the bar. A stub defaulting blur to 0 would make any test about that geometry reason
# about zeros and pass for the wrong reason, so these mirror SoftShadow.qml exactly. Keep them
# in step with it.
# A real, loadable 2x2 PNG in the fixture root. The wallpaper tests need an image that
# genuinely reaches Image.Ready: the card may only go transparent once one has LOADED, and a
# test pointing at a path that does not exist can only ever exercise the failure branch. Suites
# reach it as Qt.resolvedUrl("wallpaper-probe.png"), since the fixture root is their own dir.
def _probe_png(w=2, h=2):
    # Built here rather than embedded as base64: a pasted literal can carry a valid PNG header
    # with corrupt image data, which `file` reports as a PNG and Qt refuses with "Unable to read
    # image data" -- exactly what the first version of this did. Generating it means the CRCs
    # are right by construction.
    def chunk(tag, data):
        return (struct.pack('>I', len(data)) + tag + data
                + struct.pack('>I', zlib.crc32(tag + data) & 0xffffffff))
    ihdr = struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)          # 8-bit truecolour RGB
    raw = b''.join(b'\x00' + b'\x40\x30\x60' * w for _ in range(h))
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', ihdr)
            + chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b''))


(dest / 'wallpaper-probe.png').write_bytes(_probe_png())
(dest / 'SoftShadow.qml').write_text(
    'import QtQuick\nItem { property Item target: parent; property real radius: 0\n'
    '       property real blur: 28; property real spread: 0\n'
    '       property var offset: Qt.vector2d(0, 6); property color color: "black" }\n')
# Ui/ConfirmDialog stub: the real component (/usr/share/omarchy/shell/Ui/ConfirmDialog.qml) imports
# qs.Commons for its theme (Color/Style/Util), which the offscreen fixture has none of, so it needs
# the same "keep the behaviour, drop the shell wiring" treatment as OmascapeConfig/OmascapeLocks
# above. Reproduced FAITHFULLY: `opened`/`message`/`confirmText`/`cancelText`/`selectedIndex`, the
# `canceled()`/`confirmed()` signals, and `handleKey(event)` with the exact same key set and the
# same return value (true only when it actually consumed the key) — this plugin drives the dialog
# entirely through handleKey from its one key catcher, so a stub whose key handling diverges would
# let a UI test pass against behaviour the real dialog does not have. Also reproduced: the outer
# scrim's "click anywhere cancels" MouseArea, since it needs no theme and this plugin's own
# "press outside dismisses" convention (the context menu's catcher) makes the same shape worth
# covering here too. NOT reproduced: the real component's card layout (BorderSurface/SoftShadow),
# qs.Commons theme colours, or the two Cancel/Confirm buttons' own hover-to-select-index and
# click-to-confirm/cancel hit areas — nothing here needs to click a specific button by position,
# only handleKey and the scrim. The theme properties (background/foreground/etc.) are kept as
# inert properties only so a binding to them from Overview.qml does not fail to resolve.
(dest / 'ConfirmDialog.qml').write_text(
    'import QtQuick\n'
    'Item {\n'
    '    id: root\n'
    '    property bool opened: false\n'
    '    property string message: ""\n'
    '    property string cancelText: "Cancel"\n'
    '    property string confirmText: "Confirm"\n'
    '    property int selectedIndex: 1\n'
    '    property color background: "#222"\n'
    '    property color foreground: "#ddd"\n'
    '    property color scrim: "#000"\n'
    '    property color selectedBackground: "#444"\n'
    '    property color selectedText: "#fff"\n'
    '    property string fontFamily: ""\n'
    '    property int cornerRadius: 8\n'
    '    signal canceled()\n'
    '    signal confirmed()\n'
    '    function handleKey(event) {\n'
    '        if (!root.opened) return false\n'
    '        if (event.key === Qt.Key_Escape) { root.canceled(); return true }\n'
    '        else if (event.key === Qt.Key_Left || event.key === Qt.Key_Right ||\n'
    '                 event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {\n'
    '            root.selectedIndex = root.selectedIndex === 0 ? 1 : 0\n'
    '            return true\n'
    '        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {\n'
    '            if (root.selectedIndex === 0) root.canceled(); else root.confirmed()\n'
    '            return true\n'
    '        }\n'
    '        return false\n'
    '    }\n'
    '    visible: opened\n'
    '    MouseArea { anchors.fill: parent; enabled: root.opened; onClicked: root.canceled() }\n'
    '}\n')
