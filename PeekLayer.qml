import QtQuick
import "logic.js" as Logic

// The peek layer (docs/specs/2026-09-18-peek-design.md). Display only: it renders whatever
// target it is handed and owns no state of its own — no key handling, no target resolution, no
// snapshot. `shown` going false tears the captures down, which is the whole teardown story.
// No Quickshell import here: everything that touches a wl toplevel or a layer-shell surface is
// WindowTile's business, not this component's — it only arranges WindowTile instances and reads
// plain QML/JS values handed down as properties. `anchors.fill: parent` is deliberately NOT set
// here (unlike most root Items in this repo); the one caller (Overview.qml) owns that sizing so
// this component stays usable at whatever size a future caller gives it.
Item {
    id: peek
    visible: shown

    property bool shown: false
    // { kind: "window", address } | { kind: "workspace", id } | null — Overview's resolveTarget().
    property var peekTarget: null
    property var windowByAddress: ({})
    property var handleByAddress: ({})
    property var monForTarget: null          // the target's monitor row
    property var workspaceWindows: []        // the target workspace's windows, when kind is workspace
    // The target workspace is under a no_screen_share rule (lockSyncLua, logic.js). The compositor
    // denies capture either way, so there is no leak without this — but the grid's own delegate
    // gates capMode on the same condition (Overview.qml, boxArmed) rather than firing one denied
    // screencopy request per window every time the pointer holds over an armed workspace.
    property bool armed: false
    property var params: ({})
    property color background: "#1a1a1a"
    property color foreground: "#dddddd"
    property color hairline: "#888888"
    property color scrim: "#000000"
    // Whether the backdrop draws at all — follows config.scrim (Overview.qml's own scrimRect is
    // `visible: config.scrim`), plumbed in as a plain property rather than read from `config`
    // directly so this component stays display-only and takes everything as input. The frame
    // keeps its opaque background and SoftShadow either way, so the peek still reads as elevated
    // with the backdrop off.
    property bool scrimVisible: true
    property real cardRadius: 12
    // The WINDOW peek's radius, and deliberately not the card's. A workspace peek rounds a
    // backing PLATE — the mini-map's tiles sit inside it at their own small radius, so the card's
    // ~20 reads as a soft edge on empty background. A window peek has no plate: the capture fills
    // the frame, so the same 20 is a bite taken straight out of the screenshot, several times
    // rounder than the window looks on the desktop. The box's own radius instead, so a peeked
    // window reads like the workspace boxes it was summoned from.
    property real windowRadius: 8
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
    // opens and the peek yields). `visible: peek.scrimVisible` so a user who has turned the card's
    // own scrim off does not get one reintroduced just by holding Space.
    Rectangle { anchors.fill: parent; color: peek.scrim; opacity: 0.35; visible: peek.scrimVisible }

    // The card's own shadow treatment, so the peek reads as the same material as the picker
    // (spec: "The peek layer"). Same component and the same luminance-following alpha the card
    // uses — a peek with no shadow reads as a flat cut-out over the grid.
    SoftShadow { target: frame; opacity: frame.visible ? 1 : 0
                 color: Qt.rgba(0, 0, 0, peek.darkTheme ? 0.55 : 0.28) }

    Rectangle {
        id: frame
        anchors.centerIn: parent
        width: Math.max(1, peek.fit.w); height: Math.max(1, peek.fit.h)
        radius: peek.isWindow ? peek.windowRadius : peek.cardRadius
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
            // Fills `frame`, so its own corners must be drawn at the frame's radius — any other
            // value reads as a differently-shaped rectangle sitting inside the frame, with a
            // hairline the card never shows, and pokes past the SoftShadow at all four corners.
            // The frame is on `windowRadius` here (see its own comment), so this follows it.
            cornerRadius: peek.windowRadius
            // A fresh capture is created on every hold (see iconGraceMs's own comment in
            // WindowTile.qml), so unlike a grid tile this one races the icon against the first
            // frame every single time — the bug docs/specs/2026-09-18-peek-design.md's own
            // "honest rendering of no pixels" line does not cover, because a frame IS on the way.
            // 150ms: a wlroots screencopy round trip is normally one or two compositor frames
            // (~16-33ms at 60Hz), so this is roughly 5-10x that budget — enough headroom for a
            // slow first frame (a busy compositor, a cold GPU pipeline) to still land inside the
            // window and never show an icon at all, while staying well under "a few hundred ms"
            // for the genuine-denial case (a `no_screen_share` rule outside the armed-workspace
            // path), where the icon is now merely late by this much rather than flashing first.
            iconGraceMs: 150
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
                // Mirrors the grid's own gate (Overview.qml, boxArmed): an armed workspace's
                // windows are under a no_screen_share rule and the compositor denies the capture
                // either way, but the grid never fires the request in the first place.
                capMode: peek.shown && !peek.armed ? "live" : "icon"
                bg: peek.background; fg: peek.foreground; borderColor: peek.hairline
                fontFamily: peek.fontFamily; titleSize: peek.captionSize
                motion: peek.motion
                // Measured, not estimated (2026-09-18, under the 380-px cell cap that predates
                // proportional spacing; the grid cell is now 353 at 1920 logical, and peekTiles
                // sizes off frame.width, so the argument's SHAPE holds while its ratios have
                // moved): at a 1920×1080 panel on a 2560×1440 monitor, real
                // peekTiles output puts a mini-map tile at a uniform 3.09x its grid-cell
                // counterpart regardless of window count (n=2: 571px vs 185px; n=9: 380px vs
                // 123px) — the ratio holds because both scale off the same window geometry, just
                // at box sizes that differ by that constant factor. A smaller cap (64, 1.6x the
                // grid's 40) undershoots that: the icon's share of its own tile would HALVE
                // against the grid's (11% vs 22% at n=2), the opposite of what iconMax exists to
                // fix. Sharing 96 with the window peek is deliberate, not a coincidence: at n=1
                // the mini-map tile (1141px) is within 1% of the window peek's own frame
                // (1152px), so the two paths should — and here do — agree on one number; at the
                // busy end (n=12) 96 tracks the grid's own proportion (34% vs the grid's 33% at
                // n=9), and `Math.min(iconMax, parent.width * 0.5)` below already self-limits it
                // on a crowded workspace, so there is no overflow risk at that end either.
                iconMax: 96
                decorated: false
                // Same reasoning and number as the window peek's own iconGraceMs above: each
                // mini-map tile is a fresh per-window capture on every hold too, so it races the
                // icon against its first frame exactly the same way.
                iconGraceMs: 150
            }
        }
    }
}
