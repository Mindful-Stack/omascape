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
//
// Each strip's SURFACE is one logical pixel thicker than its PAINT, and the paint occupies the
// FIRST `thickness` px of that surface — the spare pixel is always the last one. The blanking box
// a `no_screen_share` layer draws (ScreenshareFrame.cpp scales the layer's logical position and
// size by the monitor scale) is rasterised in whole DEVICE pixels with its origin floored and its
// size truncated: it covers [floor(start), floor(start) + floor(size)). So a surface's first device
// pixel is always blanked and its last one is not, whenever the device size is fractional — at
// scale 1.25 a thickness of 6 is 7.5 device px. Painting first-pixels-in therefore keeps every
// painted pixel inside the blanked box at any scale; painting to the far end is what leaked one
// device row/column in round 4 (inner edge, top band mean 0.0527) and again at the outer edge in
// round 4b's first measurement.
// For the top/left strips "first" IS the screen edge. The bottom/right surfaces run the other way,
// so their paint stops ONE LOGICAL PX SHORT of the physical edge — invisible in practice (that is
// where the bezel is) and the price of a capture that is black everywhere. Measured clean on all
// four edges at scale 1.25 with lockBorderSize 6 (2026-09-15).
// The thickness itself is NOT snapped to whole device pixels: `implicitHeight`/`implicitWidth` are
// logical ints, which cannot express e.g. 6.4, and rounding would silently change the configured
// size.

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
        implicitHeight: frame.thickness + 1
        Rectangle {
            objectName: "lockFrameFill"; color: frame.frameColor
            anchors { top: parent.top; left: parent.left; right: parent.right }
            height: frame.thickness
        }
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
        implicitHeight: frame.thickness + 1
        Rectangle {
            objectName: "lockFrameFill"; color: frame.frameColor
            anchors { top: parent.top; left: parent.left; right: parent.right }
            height: frame.thickness
        }
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
        implicitWidth: frame.thickness + 1
        Rectangle {
            objectName: "lockFrameFill"; color: frame.frameColor
            anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
            width: frame.thickness
        }
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
        implicitWidth: frame.thickness + 1
        Rectangle {
            objectName: "lockFrameFill"; color: frame.frameColor
            anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
            width: frame.thickness
        }
    }
}
