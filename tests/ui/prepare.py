"""Build an offscreen fixture from production QML; replace only shell/compositor adapters.
MouseArea events, ListModel, bindings, timers and reconciliation run unchanged in Qt.
"""
from pathlib import Path
import json
import re
import sys
source, dest = map(Path, sys.argv[1:])


def replaced(text, old, new, what):
    """Substitute `old`, failing loudly when it is not there.

    Several of these substitutions stand in for the compositor (layer-shell anchors resolving to
    real geometry, Variants creating one delegate per screen). A silently missed replacement would
    leave the fixture with zero-sized or uninstantiated surfaces, which reads in the suite as
    "the feature is broken" — this says which line moved instead.
    """
    if old not in text:
        raise SystemExit('prepare.py: %s no longer matches the source; update the fixture' % what)
    return text.replace(old, new)


qml = (source / 'Overview.qml').read_text()
qml = re.sub(r'^import (Quickshell.*|qs\..*)\n', '', qml, flags=re.M)
qml = re.sub(r'Color\.menu\.\w+', '"#888888"', qml)
qml = re.sub(r'Style\.\w+FillAlpha', '0.1', qml)
qml = re.sub(r'Style\.font\.\w*Family', '"sans-serif"', qml)
qml = re.sub(r'Style\.font\.\w+', '11', qml)
qml = re.sub(r'Style\.space\((\d+)\)', r'\1', qml)
qml = qml.replace('Hyprland.', 'compositor.').replace('target: Hyprland', 'target: compositor')
# The share-time reminder frame's per-screen instantiation. Quickshell's `Variants` has no
# offscreen equivalent; `Repeater` creates one delegate per array entry with the same `modelData`
# injection, and the fixture root is an Item so the strips land under it. Done BEFORE the generic
# `Quickshell.screens` substitution so the frame's model is the test-controlled screen list while
# focusedScreen() keeps seeing an empty one.
qml = replaced(qml, '''    Variants {
        model: Quickshell.screens''', '''    Repeater {
        model: root.testScreens''', 'Variants block')
qml = qml.replace('Quickshell.screens', '[]').replace('ToplevelManager.toplevels', 'null')
qml = qml.replace('PanelWindow {', 'Item {')
qml = re.sub(r'^\s*(screen: root.targetScreen|WlrLayershell\..*|exclusionMode:.*|color: "transparent"|mask: .*|Region \{ id: emptyRegion \})\n', '\n', qml, flags=re.M)
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
# a size, so the fixture resolves them itself, from the screen the strip was given: the side strips
# span the full height, the top/bottom ones are inset by the side strips' width. The strip's own
# thickness is NOT resolved here — the `implicit*` line and the painted `Rectangle` are carried
# through verbatim and Qt applies them to the Item, so the suite measures the real numbers. Each
# replacement is keyed to the exact anchor set, to that `implicit*` line (the one-logical-pixel
# outset) and to the paint's own anchors (which END of the surface it sits at — the whole point of
# the outset, see LockFrame.qml), so changing any of the three fails here rather than silently
# producing a strip the geometry test would then "pass" on.
frame = (source / 'LockFrame.qml').read_text()
frame = re.sub(r'^import Quickshell.*\n', '', frame, flags=re.M)
frame = frame.replace('Scope {', 'Item {').replace('PanelWindow {', 'Item {')
frame = re.sub(r'^\s*(screen: frame\.frameScreen|WlrLayershell\..*|exclusionMode:.*|color: "transparent"'
               r'|mask: \w+|Region \{ id: \w+ \})\n', '', frame, flags=re.M)
FILL_H = '''        Rectangle {
            objectName: "lockFrameFill"; color: frame.frameColor
            anchors { top: parent.top; left: parent.left; right: parent.right }
            height: frame.thickness
        }
'''
FILL_V = '''        Rectangle {
            objectName: "lockFrameFill"; color: frame.frameColor
            anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
            width: frame.thickness
        }
'''
for edge in ('top', 'bottom'):
    frame = replaced(frame, '''        anchors { %s: true; left: true; right: true }
        margins { left: frame.thickness; right: frame.thickness }
        implicitHeight: frame.thickness + 1
''' % edge + FILL_H, '''        width: Math.max(0, (frame.frameScreen ? frame.frameScreen.width : 0) - 2 * frame.thickness)
        implicitHeight: frame.thickness + 1
''' + FILL_H, 'LockFrame %s strip anchors + outset + paint' % edge)
for edge in ('left', 'right'):
    frame = replaced(frame, '''        anchors { top: true; bottom: true; %s: true }
        implicitWidth: frame.thickness + 1
''' % edge + FILL_V, '''        height: frame.frameScreen ? frame.frameScreen.height : 0
        implicitWidth: frame.thickness + 1
''' + FILL_V, 'LockFrame %s strip anchors + outset + paint' % edge)
(dest / 'LockFrame.qml').write_text(frame)
(dest / 'FindBar.qml').write_text((source / 'FindBar.qml').read_text())   # no shell imports: verbatim
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
