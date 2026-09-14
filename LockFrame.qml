import QtQuick
import Quickshell
import Quickshell.Wayland
import "logic.js" as Logic

// Share-time reminder frame for ONE screen (docs/specs/2026-09-12-lock-design.md, addendum):
// four thin layer-shell strips at the monitor edges, shown while a share is running and the
// workspace that monitor is currently showing is armed. Round 4 replaced the window-border rules
// with this: Hyprland's Lua rule API can only set the ACTIVE border colour (LuaConfigGradient
// re-serialises any border_color string as one gradient, so parseBorderColorRule never sees the
// two-token form), and a border_size change relayouts the workspace on every toggle.
//
// The strips are OUR surfaces, so the install chunk's `no_screen_share` layer rule on the
// `omyview-lockframe` namespace blanks them in every capture: a viewer sees the plain black
// exclusion box, the red frame is purely local. They are click-through (an empty `mask` Region —
// the same trick the overview uses while closed), take no keyboard focus and reserve no space
// (`ExclusionMode.Ignore`), so nothing about the desktop layout changes when they appear.
//
// Existence is `visible:`, never create/destroy: mapping and unmapping a layer surface per share
// edge is what the hysteresis (LOCK_SHARE_GRACE_MS) exists to avoid in the first place.
//
// The left and right strips run the full height and the top/bottom ones are inset by that width,
// so every corner is painted exactly once (a doubled corner would read darker on a translucent
// colour).
Scope {
    id: frame
    objectName: "lockFrame"

    property var frameScreen: null       // the Quickshell ShellScreen this frame belongs to
    property var monitor: null           // the HyprlandMonitor for that screen
    property bool sharing: false         // locks.sharing — the debounced compositor signal
    property var armed: null             // locks.armed (null while the locks file is unresolved)
    property color frameColor: "#ff4444"
    property int thickness: 6            // config.lockBorderSize; 0 disables the cue

    // `lastIpcObject` is a SNAPSHOT, not a live view: Overview.qml asks for a fresh one
    // (`Hyprland.refreshMonitors()`) on the raw events that can change which workspace a monitor
    // shows (Logic.lockFrameRefreshEvent). It is a QML property, so replacing it re-evaluates
    // this binding — which is the whole update path for the frame.
    readonly property var monIpc: frame.monitor ? frame.monitor.lastIpcObject : null
    readonly property bool shown:
        frame.thickness > 0 && Logic.lockFrameVisible(frame.sharing, frame.armed, frame.monIpc)

    PanelWindow {
        objectName: "lockFrameTop"
        visible: frame.shown
        screen: frame.frameScreen
        color: "transparent"
        WlrLayershell.namespace: "omyview-lockframe"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
        exclusionMode: ExclusionMode.Ignore
        mask: emptyTop
        Region { id: emptyTop }
        anchors { top: true; left: true; right: true }
        margins { left: frame.thickness; right: frame.thickness }
        implicitHeight: frame.thickness
        Rectangle { objectName: "lockFrameFill"; anchors.fill: parent; color: frame.frameColor }
    }
    PanelWindow {
        objectName: "lockFrameBottom"
        visible: frame.shown
        screen: frame.frameScreen
        color: "transparent"
        WlrLayershell.namespace: "omyview-lockframe"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
        exclusionMode: ExclusionMode.Ignore
        mask: emptyBottom
        Region { id: emptyBottom }
        anchors { bottom: true; left: true; right: true }
        margins { left: frame.thickness; right: frame.thickness }
        implicitHeight: frame.thickness
        Rectangle { objectName: "lockFrameFill"; anchors.fill: parent; color: frame.frameColor }
    }
    PanelWindow {
        objectName: "lockFrameLeft"
        visible: frame.shown
        screen: frame.frameScreen
        color: "transparent"
        WlrLayershell.namespace: "omyview-lockframe"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
        exclusionMode: ExclusionMode.Ignore
        mask: emptyLeft
        Region { id: emptyLeft }
        anchors { top: true; bottom: true; left: true }
        implicitWidth: frame.thickness
        Rectangle { objectName: "lockFrameFill"; anchors.fill: parent; color: frame.frameColor }
    }
    PanelWindow {
        objectName: "lockFrameRight"
        visible: frame.shown
        screen: frame.frameScreen
        color: "transparent"
        WlrLayershell.namespace: "omyview-lockframe"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
        exclusionMode: ExclusionMode.Ignore
        mask: emptyRight
        Region { id: emptyRight }
        anchors { top: true; bottom: true; right: true }
        implicitWidth: frame.thickness
        Rectangle { objectName: "lockFrameFill"; anchors.fill: parent; color: frame.frameColor }
    }
}
