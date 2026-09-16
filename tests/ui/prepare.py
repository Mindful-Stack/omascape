"""Build an offscreen fixture from production QML; replace only shell/compositor adapters.
MouseArea events, ListModel, bindings, timers and reconciliation run unchanged in Qt.
"""
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
    property alias testConfig: config
    property alias testLocks: locks
    property alias testEnterAnim: enterAnim
    property alias testKeys: keyCatcher
    property alias testBar: findBar
    // Compile-time dependency on the `hintKeys` id in Overview.qml: renaming or removing that
    // id breaks every UI suite at once with "Invalid alias reference", not just Scratchpad's.
    property alias testHintModel: hintKeys.model
    property alias testHintRow: hint
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
start = tile.index('    ClippingRectangle {')
end = tile.index('    // title label', start)
tile = tile[:start] + '    Rectangle { anchors.fill: parent; color: tile.bg }\n\n' + tile[end:]
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
# Shell-only helpers: the config loader needs Quickshell.Io, the shadow a GPU shader.
# `motionEffective` is writable here so tests can flip the policy without a compositor.
# `workspaces` defaults to 0 (no padding) so the fixture shows exactly the compositor's
# workspaces; tests that cover padding switch it on themselves.
(dest / 'OmyviewConfig.qml').write_text(
    'import QtQuick\nQtObject { property bool scrim: true; property bool hint: true\n'
    '           property int workspaces: 0\n'
    '           property string motion: "auto"; property string motionEffective: "full"\n'
    '           property bool motionResolved: true\n'
    '           property string lockBorder: "rgb(ff4444)"; property int lockBorderSize: 6\n'
    '           function probeMotion() {} }\n')
# Lock state stub: the real OmyviewLocks.qml watches two files through Quickshell.Io. The stub
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
(dest / 'OmyviewLocks.qml').write_text(
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
(dest / 'SoftShadow.qml').write_text(
    'import QtQuick\nItem { property Item target: parent; property real radius: 0; property real blur: 0\n'
    '       property var offset: null; property color color: "black" }\n')
