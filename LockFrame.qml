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
// The left and right strips run the full height, the top and bottom ones the full width, and it is
// the top/bottom PAINT that is inset by the side strips' thickness — so every corner is painted
// exactly once (a doubled corner would read darker on a translucent colour) while all four
// surfaces still start and end on a screen edge, which is what the snapping below relies on.
//
// The PAINT is flush against the screen edge on all four sides. What is bigger than the paint is
// the SURFACE: each strip maps `Logic.lockFrameSurfaceSize(thickness, monitorScale)` logical px —
// the smallest size above the paint whose DEVICE size is a whole number — and paints `thickness`
// of it against the outer edge.
// Why: the blanking box a `no_screen_share` layer draws (ScreenshareFrame.cpp scales the layer's
// logical position and size by the monitor scale) is rasterised with its origin floored and its
// size truncated — it covers [floor(start), floor(start) + floor(size)). A monitor's device size
// is a whole number and each strip starts at logical 0 or at (W or H) − s, so when s·scale is
// whole the box is EXACTLY the surface, and the paint — strictly inside the surface — cannot
// reach a device pixel the box misses. A surface whose device size is fractional always loses one
// device line, and whichever line that is carries the frame colour into the recording: round 4
// leaked the inner edge (6 logical px at scale 1.25 is 7.5 device px; top band mean 0.0527), and
// round 4b's first fix leaked the outer one instead.
// The PAINT is never snapped — `lockBorderSize` is what the user asked for. On an exotic scale
// where no whole-number surface exists within 12 px, `lockFrameSurfaceSize` falls back to
// `thickness + 1` and a one-device-pixel hairline of the frame colour can show in a capture; it
// discloses nothing (the audience learns a frame exists, never what is behind it).

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

    // The monitor's scale decides how many logical px a strip's surface needs to land on whole
    // device pixels (see the comment above). `HyprlandMonitor.scale` is a live property, so a
    // monitor rescaled at runtime re-snaps the surfaces; a monitor we do not have yet counts as
    // unscaled, which makes the surface the smallest it can be rather than guessing.
    readonly property real monitorScale:
        (frame.monitor && typeof frame.monitor.scale === "number" && frame.monitor.scale > 0)
            ? frame.monitor.scale : 1
    readonly property int surfaceSize: Logic.lockFrameSurfaceSize(frame.thickness, frame.monitorScale)

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
        implicitHeight: frame.surfaceSize
        Rectangle {
            objectName: "lockFrameFill"; color: frame.frameColor
            anchors { top: parent.top; left: parent.left; right: parent.right
                      leftMargin: frame.thickness; rightMargin: frame.thickness }
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
        implicitHeight: frame.surfaceSize
        Rectangle {
            objectName: "lockFrameFill"; color: frame.frameColor
            anchors { bottom: parent.bottom; left: parent.left; right: parent.right
                      leftMargin: frame.thickness; rightMargin: frame.thickness }
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
        implicitWidth: frame.surfaceSize
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
        implicitWidth: frame.surfaceSize
        Rectangle {
            objectName: "lockFrameFill"; color: frame.frameColor
            anchors { right: parent.right; top: parent.top; bottom: parent.bottom }
            width: frame.thickness
        }
    }
}
