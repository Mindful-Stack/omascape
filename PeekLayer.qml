import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Widgets
import "logic.js" as Logic

// The peek layer (docs/specs/2026-09-18-peek-design.md). Display only: it renders whatever
// target it is handed and owns no state of its own — no key handling, no target resolution, no
// snapshot. `shown` going false tears the captures down, which is the whole teardown story.
Item {
    id: peek
    anchors.fill: parent
    visible: shown

    property bool shown: false
    // { kind: "window", address } | { kind: "workspace", id } | null — Overview's resolveTarget().
    property var peekTarget: null
    property var windowByAddress: ({})
    property var handleByAddress: ({})
    property var monForTarget: null          // the target's monitor row
    property var workspaceWindows: []        // the target workspace's windows, when kind is workspace
    property var params: ({})
    property color background: "#1a1a1a"
    property color foreground: "#dddddd"
    property color hairline: "#888888"
    property color scrim: "#000000"
    property real cardRadius: 12
    property string fontFamily: ""
    property int captionSize: 10
    property bool darkTheme: false
    required property QtObject motion

    readonly property int boxW: Math.round(width * 0.6)
    readonly property int boxH: Math.round(height * 0.6)
    readonly property bool isWindow: !!peekTarget && peekTarget.kind === "window"
    readonly property var peekWindow: isWindow ? (windowByAddress[peekTarget.address] || null) : null

    // The aspect to fit: the window's own size, or the target monitor's logical size — the same
    // aspect cellHeightFor uses for a grid cell, so the peek and the cell can never disagree
    // about a monitor's shape.
    readonly property var fit: {
        if (isWindow) return peekWindow ? Logic.peekFit(peekWindow.sw, peekWindow.sh, boxW, boxH)
                                        : { w: 0, h: 0 }
        if (!monForTarget) return { w: 0, h: 0 }
        var s = monForTarget.scale > 0 ? monForTarget.scale : 1
        return Logic.peekFit(monForTarget.width / s, monForTarget.height / s, boxW, boxH)
    }

    // A step above the card's own scrim, so the grid reads as "behind" rather than as competing
    // content. Not a MouseArea: the peek is bound to the held key alone and swallows no click —
    // which is also why a right-click during a hold reaches the tile underneath (spec: the modal
    // opens and the peek yields).
    Rectangle { anchors.fill: parent; color: peek.scrim; opacity: 0.35 }

    // The card's own shadow treatment, so the peek reads as the same material as the picker
    // (spec: "The peek layer"). Same component and the same luminance-following alpha the card
    // uses — a peek with no shadow reads as a flat cut-out over the grid.
    SoftShadow { target: frame; opacity: frame.visible ? 1 : 0
                 color: Qt.rgba(0, 0, 0, peek.darkTheme ? 0.55 : 0.28) }

    Rectangle {
        id: frame
        anchors.centerIn: parent
        width: Math.max(1, peek.fit.w); height: Math.max(1, peek.fit.h)
        radius: peek.cardRadius
        color: peek.background
        // A zero fit means there is nothing honest to draw (a 0x0 monitor, a window that left the
        // model between the resolve and this binding). Draw nothing rather than a 1px artefact.
        visible: peek.fit.w > 0 && peek.fit.h > 0

        // Window target: one large live capture, with the same icon fallback the grid tile uses.
        WindowTile {
            anchors.fill: parent
            visible: peek.isWindow
            handle: peek.isWindow ? (peek.handleByAddress[peek.peekTarget.address] || null) : null
            cls: peek.peekWindow ? peek.peekWindow.cls : ""
            title: peek.peekWindow ? peek.peekWindow.title : ""
            capMode: peek.shown && peek.isWindow ? "live" : "icon"
            bg: peek.background; fg: peek.foreground; borderColor: peek.hairline
            fontFamily: peek.fontFamily; titleSize: peek.captionSize
            motion: peek.motion
            iconMax: 96
            decorated: false
        }

        // Workspace target: the grid's own placement at peek size, one capture per window.
        Repeater {
            id: miniMap
            model: peek.shown && !peek.isWindow && peek.monForTarget
                   ? Logic.peekTiles(peek.workspaceWindows, peek.monForTarget,
                                     frame.width, frame.height, peek.params)
                   : []
            WindowTile {
                required property var modelData
                x: modelData.x; y: modelData.y
                width: modelData.w; height: modelData.h
                handle: peek.handleByAddress[modelData.address] || null
                cls: (peek.windowByAddress[modelData.address] || {}).cls || ""
                title: (peek.windowByAddress[modelData.address] || {}).title || ""
                floating: modelData.layer === 2
                tileLayer: modelData.layer
                fullscreen: modelData.fullscreen
                capMode: peek.shown ? "live" : "icon"
                bg: peek.background; fg: peek.foreground; borderColor: peek.hairline
                fontFamily: peek.fontFamily; titleSize: peek.captionSize
                motion: peek.motion
                decorated: false
            }
        }
    }
}
