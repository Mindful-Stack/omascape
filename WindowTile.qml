import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Widgets

Item {
    id: tile
    // set by the caller:
    property var handle: null            // wl Toplevel, or null
    property string cls: ""
    property string capMode: "live"      // "live" | "snapshot" | "icon"
    property color borderColor: "#888"
    property color bg: "#1a1a1a"
    property color fg: "#ddd"
    property string title: ""
    property bool dragging: false        // set by Overview during a drag to suppress hover-zoom
    property bool floating: false        // floating windows get a soft shadow, like on the desktop
    property string fontFamily: ""
    property int titleSize: 10
    // Named tileLayer, not layer: Item already has a FINAL "layer" property group (layer.effect
    // etc.) that QML refuses to shadow.
    property int tileLayer: 1            // 0 backdrop | 1 tiled | 2 floating — stacking inside the cell
    property int fullscreen: 0           // Hyprland mode: 0 none, 1 maximized, 2 fullscreen
    property bool fullscreenPending: false   // un-fullscreen dispatched; badge hidden until confirmed
    signal unfullscreenRequested()

    // Find: `matched` and `selectedMatch` mirror the tile-model roles; `dimmed` is "a query is
    // active and this tile does not match". The outline needs its own `accent` input rather
    // than reusing `borderColor`: at rest `borderColor` is the near-invisible hairline, so a
    // ring bound to it would draw nothing. (Not because the two need to differ while both are
    // showing — the drop border and the match ring never co-exist on one tile: a drop target
    // is excluded from dimming and the ring hides itself while `dropTarget` is true.)
    property bool matched: false
    property bool selectedMatch: false
    property bool dimmed: false
    property color accent: "#88f"

    // Tab cursor (docs/specs/2026-09-15-actions-design.md): the keyboard's window target. It
    // reuses the find ring rather than adding a second outline — the two can never be shown at
    // once (a query clears the cursor), so one ring always means "this is the keyboard's window".
    property bool cursorTarget: false

    // A close was requested and the compositor still reports the window: the app may be prompting
    // about unsaved work, or may refuse. Dimmed like a non-match so the request is visible,
    // and skipped by the Tab cycle so a repeated Ctrl+W walks forward.
    property bool closing: false

    // Motion vocabulary handed down by Overview: durations (ms) and easings. Tiles never own
    // a duration of their own.
    required property QtObject motion

    property bool dropTarget: false
    // "left"|"right"|"top"|"bottom": which half a dragged tiled window would take here
    property string dropSide: ""
    // The last non-empty side: the insertion half keeps it while fading out, so it never
    // jumps to another edge on the way to transparent.
    property string shownSide: ""
    onDropSideChanged: if (dropSide.length) shownSide = dropSide

    readonly property bool wantCapture: handle !== null && capMode !== "icon"
    readonly property string iconUrl: Quickshell.iconPath(String(cls).toLowerCase(), true)

    // Peek reuses this delegate at ~3x grid size (docs/specs/2026-09-18-peek-design.md). Two
    // grid-only affordances are opted out of there rather than forked into a second delegate:
    // the icon fallback's 40px cap, which reads as a postage stamp in a 60% box, and hover
    // itself. `decorated: false` gates the whole response at the HoverHandler rather than
    // per-consumer, so it drops the title chip, the 1.03 lift and the in-layer z raise
    // together — a peek is not a click target, so none of the three apply to it. It also now
    // gates the fullscreen badge's own MouseArea (review find, round 2): PeekLayer's mini-map
    // passes `fullscreen` through so a recovered-slot window's badge is still visible there
    // (the badge is the only sign of that state once the window isn't filling the workspace —
    // see the badge's own comment), but with no `unfullscreenRequested` handler wired up on
    // that path, the badge's click target had nothing to do except swallow the click and fire a
    // signal into the void. Gating on `decorated` reuses the exact same "is this a live click
    // target" signal the HoverHandler already reads, rather than adding a second flag that could
    // drift from it. Only ever set this false on a non-interactive instance: on a grid tile it
    // would also shrink that tile's action hit-test rect, which is read off the *painted*
    // scale/z (Overview.tileCandidates), back to bare model geometry, AND disable its badge's
    // click target — a grid tile's fullscreen badge is meant to be clickable.
    property int iconMax: 40
    property bool decorated: true
    // Same opt-in as iconMax/decorated, for the same reason: the grid's r5 (box radius 8 minus
    // the cell inset 3, concentric with the well) is wrong at peek size, where the frame around
    // this tile carries the card's own cardRadius (~20). Left at the grid default everywhere
    // except the window peek, which passes cardRadius so its capture's corners — and the
    // hairline right at its edge — read as the SAME shape the frame and its SoftShadow are
    // drawn at, instead of a smaller rectangle poking past the shadow at all four corners.
    property int cornerRadius: 5

    // Peek's own opt-in, for a different reason than the three above: the grid's ScreencopyView
    // is created once per summon and its first frame typically lands during appear()'s fade-in,
    // so the icon-then-capture race there is over before a user's eye gets to the tile. The peek
    // instead creates a FRESH capture on every hold, at ~3x the grid's size, so that race runs on
    // every single Space press — the icon wins for a frame or two, then gets yanked out from
    // under a box covering 60% of the screen. Zero (the grid default) reproduces today's
    // behaviour exactly: the icon is the honest "no pixels to show" render, and appears the
    // instant there is nothing to show. Above zero, the icon is held off for this many ms while a
    // capture is genuinely in flight (`wantCapture` true, `cap.hasContent` still false) rather
    // than flashing in ahead of frame 0. If the grace elapses with still nothing — a capture the
    // compositor denies outright, e.g. the user's own `no_screen_share` window rule outside the
    // armed-workspace path this file already gates on via `capMode: "icon"` — the icon appears
    // exactly as it does today, just late by this much, rather than leaving a blank frame
    // forever. `wantCapture` being false (no handle, or a tile explicitly parked in icon mode) is
    // never gated: nothing is expected there, so the icon still shows immediately, with no delay.
    property int iconGraceMs: 0
    readonly property bool graceActive: iconGraceMs > 0 && wantCapture && !cap.hasContent
    property bool graceElapsed: false
    // If `graceActive` oscillates faster than the grace itself — `handle` going null and then
    // non-null again mid-hold, e.g. toplevel churn racing the compositor — `onRunningChanged`
    // below resets and restarts the clock on every flip, which can suppress the icon
    // indefinitely and leave nothing but bare `bg` on screen. That is benign (a blank box beats
    // a flash) and hard to actually trigger: a handle that is merely EQUAL to its old value, not
    // a genuinely new object, leaves `wantCapture` and this whole expression unchanged, so only
    // a real address-losing-and-regaining-its-handle churn would do it. Noted so the next reader
    // is not puzzled by a peek that goes quiet instead of falling back.
    Timer {
        interval: tile.iconGraceMs
        // Bound to the real Timer.running property rather than driven off an onGraceActiveChanged
        // handler on our own QML-declared property: a tile can be BORN already needing the grace
        // (capture requested from its very first paint, e.g. the peek's fresh-per-hold capture),
        // and a plain on*Changed handler on a QML property only fires on a later change — not on
        // the value the property is born with. Timer.running is a real C++-backed property, so
        // assigning it true for the first time still runs through its setter and starts the
        // clock, regardless of whether this is the tile's first binding evaluation or its tenth.
        running: tile.graceActive
        onRunningChanged: if (running) tile.graceElapsed = false
        onTriggered: tile.graceElapsed = true
    }

    // Drag ghost: while in transit the tile shrinks around the grabbed point (so that point stays
    // under the pointer and the ghost never hides the drop highlight) and turns translucent.
    // The pointer, not the ghost, decides where a tiled window lands.
    property real grabX: width / 2         // grab point in tile coords, set by Overview at press
    property real grabY: height / 2
    readonly property real dragScale: 0.6
    readonly property real dragOpacity: 0.6
    readonly property alias ghostScale: ghost.xScale

    // Record a new grab point and take ownership of x/y. If the release animation is still
    // running (scale ≠ 1), moving the Scale origin would displace the rendered tile by
    // (grab − oldOrigin)·(1 − scale) — a re-grab during those 90 ms would jump — so offset
    // x/y by exactly that amount. The assignments are unconditional on purpose: a plain JS
    // write detaches x/y from their bindings (MouseArea's drag writes from C++ and leaves the
    // bindings in place, so a glide target changing mid-drag would otherwise re-assert them).
    // Overview rebinds x/y on release.
    function beginGrab(gx, gy) {
        var s = ghost.xScale
        var dx = s !== 1 ? (gx - grabX) * (1 - s) : 0
        var dy = s !== 1 ? (gy - grabY) * (1 - s) : 0
        x = x - dx; y = y - dy
        grabX = gx; grabY = gy
    }

    HoverHandler { id: hh; enabled: !tile.dragging && tile.decorated }
    // Appear (window opened while the picker is showing): fade + scale 0.9 → 1 from the
    // centre, on channels of their own so the hover/lift Behaviors are not re-smoothing an
    // already smooth ramp (they are disabled while it runs). Both NumberAnimations carry an
    // explicit `from`, so Qt writes that starting value straight to appearScale/appearOpacity
    // when the animation starts — no manual priming of those two properties needed, and no
    // ordering trick with appearAnim.running to get a deterministic first value out of them.
    // But Qt sets that `from` value *before* flipping the animation's own `running` to true,
    // so at that exact instant the hover/lift Behaviors below (gated on !appearAnim.running)
    // are still enabled and would catch the resulting scale/opacity write and smooth it into
    // their own transition instead of letting it land — `priming` closes that one-tick gap.
    property real appearScale: 1
    property real appearOpacity: 1
    property bool priming: false
    function appear() {
        if (!tile.motion.enabled) return
        priming = true
        appearAnim.restart()
        priming = false
    }
    ParallelAnimation {
        id: appearAnim
        NumberAnimation { target: tile; property: "appearScale"; from: 0.9; to: 1
                          duration: tile.motion.normal; easing.type: tile.motion.move }
        NumberAnimation { target: tile; property: "appearOpacity"; from: 0; to: 1
                          duration: tile.motion.normal; easing.type: tile.motion.move }
    }
    scale: (dragging ? 1 : (hh.hovered ? 1.03 : 1)) * appearScale
    transformOrigin: Item.Center
    // Hover raises a tile within its own layer only; dragging is the single global exception.
    z: dragging ? 99999 : tileLayer * 10 + (hh.hovered ? 1 : 0)
    opacity: (dragging ? dragOpacity : ((dimmed || closing) ? 0.35 : 1)) * appearOpacity
    Behavior on scale { enabled: tile.motion.enabled && !appearAnim.running && !priming
        NumberAnimation { duration: tile.motion.fast; easing.type: tile.motion.hover } }
    Behavior on opacity { enabled: tile.motion.enabled && !appearAnim.running && !priming
        NumberAnimation { duration: tile.motion.fast; easing.type: tile.motion.hover } }
    transform: Scale {
        id: ghost
        origin.x: tile.grabX; origin.y: tile.grabY
        xScale: tile.dragging ? tile.dragScale : 1
        yScale: xScale
        Behavior on xScale { enabled: tile.motion.enabled
            NumberAnimation { duration: tile.motion.fast; easing.type: tile.motion.hover } }
    }

    // Floating windows sit above the tiled ones on the real desktop; a soft shadow says so
    // here too. Hidden in transit (the ghost is already lifted by scale and opacity).
    SoftShadow {
        objectName: "floatShadow"
        target: tile
        visible: tile.floating && !tile.dragging
        radius: 5
        blur: 12
        offset: Qt.vector2d(0, 3)
        color: Qt.rgba(0, 0, 0, 0.35)
    }

    ClippingRectangle {
        anchors.fill: parent
        color: tile.bg
        radius: tile.cornerRadius   // grid default: box radius (8) minus the cell inset (3), concentric with the well
        // no outline at rest beyond a faint hairline (adjacent previews with zero Hyprland
        // gaps would otherwise merge); the accent border marks the tiled-insert anchor
        border.width: tile.dropTarget ? 2 : 1
        border.color: tile.borderColor

        ScreencopyView {
            id: cap
            anchors.fill: parent
            visible: tile.wantCapture && cap.hasContent
            captureSource: tile.wantCapture ? tile.handle : null
            live: tile.capMode === "live"
        }

        // icon fallback: shown when not capturing at all (no handle, or capMode "icon" — nothing
        // is expected, so no delay applies), or once iconGraceMs above has elapsed with still no
        // content. While a capture IS expected and its grace hasn't elapsed yet, this stays
        // hidden rather than flashing in ahead of the first frame — see iconGraceMs's own comment
        // for the full story and why the grid leaves it at zero (immediate, as before).
        Image {
            anchors.centerIn: parent
            visible: !cap.visible && tile.iconUrl.length > 0 && (!tile.graceActive || tile.graceElapsed)
            source: tile.iconUrl
            width: Math.min(tile.iconMax, parent.width * 0.5)
            height: width
            fillMode: Image.PreserveAspectFit
            sourceSize.width: width * Screen.devicePixelRatio
            sourceSize.height: height * Screen.devicePixelRatio
        }
        // Same grace as the icon above, for the same reason: an app with no icon at all falls
        // back to this letter instead, and it races the first frame exactly the same way — an
        // unknown app is not a reason to skip the grace, so this is gated identically rather than
        // gated on nothing.
        Text {
            anchors.centerIn: parent
            visible: !cap.visible && tile.iconUrl.length === 0 && (!tile.graceActive || tile.graceElapsed)
            text: String(tile.cls).substring(0, 1).toUpperCase()
            color: tile.fg
            font.pixelSize: Math.min(20, parent.height * 0.5)
        }
    }

    // title label (bottom), fades in on hover
    Rectangle {
        anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
        height: lbl.implicitHeight + 4
        color: Qt.rgba(0, 0, 0, 0.55)
        visible: hh.hovered && lbl.text.length > 0
        opacity: hh.hovered ? 1 : 0
        Behavior on opacity { enabled: tile.motion.enabled
            NumberAnimation { duration: tile.motion.fast; easing.type: tile.motion.hover } }
        Text {
            id: lbl; anchors.centerIn: parent; color: "#fff"
            font.family: tile.fontFamily; font.pixelSize: tile.titleSize
            elide: Text.ElideRight; width: parent.width - 8
            text: (tile.fullscreen === 2 ? "Fullscreen · " : tile.fullscreen === 1 ? "Maximized · " : "")
                  + (tile.title.length ? tile.title : tile.cls)
        }
    }

    // insertion preview: the half of this tile the dragged tiled window will be split into.
    // Fades in/out (motion.fast); geometry follows tile.shownSide, not dropSide.
    Rectangle {
        objectName: "insertHalf"
        visible: opacity > 0
        opacity: tile.dropSide.length > 0 ? 0.45 : 0
        Behavior on opacity { enabled: tile.motion.enabled
            NumberAnimation { duration: tile.motion.fast; easing.type: tile.motion.hover } }
        color: tile.borderColor
        radius: 4
        x: tile.shownSide === "right" ? parent.width / 2 : 0
        y: tile.shownSide === "bottom" ? parent.height / 2 : 0
        width: (tile.shownSide === "left" || tile.shownSide === "right") ? parent.width / 2 : parent.width
        height: (tile.shownSide === "top" || tile.shownSide === "bottom") ? parent.height / 2 : parent.height
    }

    // find ring: accent outline on a matching tile, heavier on the ranked selection. Hidden
    // while this tile is the drop target (that border takes precedence). Fades in/out and
    // thickens on the hover curve (motion.fast); instant with motion off. No mouse handling.
    Rectangle {
        objectName: "matchOutline"
        anchors.fill: parent
        visible: opacity > 0
        opacity: ((tile.matched || tile.cursorTarget) && !tile.dropTarget) ? 1 : 0
        Behavior on opacity { enabled: tile.motion.enabled
            NumberAnimation { duration: tile.motion.fast; easing.type: tile.motion.hover } }
        color: "transparent"
        radius: 5
        border.width: (tile.selectedMatch || tile.cursorTarget) ? 2 : 1
        Behavior on border.width { enabled: tile.motion.enabled
            NumberAnimation { duration: tile.motion.fast; easing.type: tile.motion.hover } }
        border.color: tile.accent
    }

    // fullscreen badge: a drawn four-corner glyph in the top-right corner while the window is
    // fullscreen/maximized. Its own MouseArea stacks above the drag area (z 1), so a badge press
    // never starts a drag, never counts as a tile click, and a middle click on it is swallowed
    // rather than closing the window. Left click → un-fullscreen.
    Rectangle {
        id: badge
        objectName: "fsBadge"
        visible: tile.fullscreen > 0 && !tile.fullscreenPending
        anchors { top: parent.top; right: parent.right; margins: 3 }
        width: 16; height: 16; radius: 4
        color: tile.bg
        border.width: 1; border.color: tile.borderColor
        z: 1
        Repeater {
            model: 4
            Item {
                required property int index
                readonly property bool onRight: index % 2 === 1
                readonly property bool onBottom: index >= 2
                x: onRight ? 9 : 3; y: onBottom ? 9 : 3; width: 4; height: 4
                Rectangle { width: 4; height: 1; color: tile.fg; y: parent.onBottom ? 3 : 0 }
                Rectangle { width: 1; height: 4; color: tile.fg; x: parent.onRight ? 3 : 0 }
            }
        }
        MouseArea {
            anchors.fill: parent
            // Non-interactive instances (decorated: false — a mini-map or window peek tile) keep
            // the badge VISIBLE but disabled: the badge itself still tells a display-only preview
            // that its window is fullscreen/maximized, but nothing there connects
            // unfullscreenRequested, so an enabled click target would swallow the click (left and
            // middle both) and fire a signal no one is listening for. See `decorated`'s own
            // comment above.
            enabled: tile.decorated
            acceptedButtons: Qt.LeftButton | Qt.MiddleButton
            preventStealing: true
            onClicked: function (m) { if (m.button === Qt.LeftButton) tile.unfullscreenRequested() }
        }
    }
}
