"""Build an offscreen fixture from production QML; replace only shell/compositor adapters.
MouseArea events, ListModel, bindings, timers and reconciliation run unchanged in Qt.
"""
from pathlib import Path
import json
import re
import sys
source, dest = map(Path, sys.argv[1:])
qml = (source / 'Overview.qml').read_text()
qml = re.sub(r'^import (Quickshell.*|qs\..*)\n', '', qml, flags=re.M)
qml = re.sub(r'Color\.menu\.\w+', '"#888888"', qml)
qml = re.sub(r'Style\.\w+FillAlpha', '0.1', qml)
qml = re.sub(r'Style\.font\.\w*Family', '"sans-serif"', qml)
qml = re.sub(r'Style\.font\.\w+', '11', qml)
qml = re.sub(r'Style\.space\((\d+)\)', r'\1', qml)
qml = qml.replace('Hyprland.', 'compositor.').replace('target: Hyprland', 'target: compositor')
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
    property alias testEnterAnim: enterAnim
    property alias testKeys: keyCatcher
    property alias testBar: findBar
    // Compile-time dependency on the `hintKeys` id in Overview.qml: renaming or removing that
    // id breaks every UI suite at once with "Invalid alias reference", not just Scratchpad's.
    property alias testHintModel: hintKeys.model
    property alias testHintRow: hint
    property QtObject compositor: QtObject {
        property var monitors: ({values: []})
        property var workspaces: ({values: []})
        property var focusedMonitor: null
        property var focusedWorkspace: null
        property var commands: []
        signal rawEvent()
        function dispatch(command) { commands = commands.concat([command]) }
        property int refreshes: 0
        function refreshToplevels() { refreshes++ }
        function refreshWorkspaces() {}
        function refreshMonitors() {}
    }
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
    '           function probeMotion() {} }\n')
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
