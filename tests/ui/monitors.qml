import QtQuick
import QtTest

// Offscreen UI suite for what the overview accepts as a monitor. The fixture (tests/ui/prepare.py)
// runs the real Overview with the compositor replaced by a stub, so buildInput(), the layout and
// the card's own sizing are production code here.
TestCase {
    id: tc
    name: "Monitors"
    when: windowShown
    width: 1200; height: 800; visible: true
    property var view
    property var mon

    Component { id: overview; Overview {} }

    function client(addr, cls, x) {
        return { address: addr, at: [x, 1500], size: [400, 400], floating: false,
                 title: cls, "class": cls, fullscreen: 0 }
    }
    function wsRow(id, monitor, clients) {
        return { id: id, monitor: monitor,
                 toplevels: { values: clients.map(function (c) { return { lastIpcObject: c } }) } }
    }
    // What Quickshell hands the plugin for a workspace Hyprland reports on no monitor at all
    // (`"monitor": "?"` in `hyprctl workspaces -j`, a persistent rule whose monitor is absent, or
    // a workspace left behind by an unplugged one): a monitor object of that name with every
    // field zeroed and an empty lastIpcObject. It is a placeholder, never a screen.
    function phantomMon() {
        return { name: "?", x: 0, y: 0, width: 0, height: 0, scale: 0, lastIpcObject: {} }
    }
    function seed(v) {
        mon = { name: "TEST", x: 0, y: 1440, width: 1920, height: 1080, scale: 1,
                lastIpcObject: { reserved: [0, 26, 0, 0], transform: 0,
                                 activeWorkspace: { id: 1 }, specialWorkspace: { id: 0, name: "" } } }
        v.compositor.monitors = { values: [mon, phantomMon()] }
        v.compositor.focusedMonitor = mon
        v.compositor.focusedWorkspace = { id: 1 }
        v.compositor.workspaces = { values: [
            wsRow(1, mon, [client("0xA", "alpha", 100)]),
            wsRow(2, mon, []),
            // The workspace that names the placeholder. Hyprland has created it and it keeps its
            // key, but no screen is showing it — so the overview draws its well in the focused
            // monitor's group rather than in one of the placeholder's own.
            wsRow(6, phantomMon(), [])
        ] }
    }
    function init() {
        view = createTemporaryObject(overview, tc)
        verify(view !== null)
        view.motion.scale = 0
        seed(view)
        view.open()
        wait(400)
    }
    function cleanup() { view.close() }

    // Distinguishes: THE bug this suite exists for (found on a real desktop, 2026-09-18). A
    // monitor with a 0x0 logical size divides 0 by 0 for its aspect, and that NaN reaches the
    // cell height, every box in its group, the canvas and finally the card. A Rectangle whose
    // height is NaN paints NOTHING, so the overview mapped its surface, took keyboard focus and
    // laid a scrim over the desktop with no card on it — and because `panel.visible` follows
    // `card.opacity`, the fade never landed and the surface stayed mapped after the close.
    function test_a_placeholder_monitor_never_reaches_the_card() {
        verify(isFinite(view.testCard.implicitHeight),
               "card height must be finite, got " + view.testCard.implicitHeight)
        verify(view.testCard.implicitHeight > 0, "card must have a height")
        verify(isFinite(view.testCanvas.implicitHeight),
               "canvas height must be finite, got " + view.testCanvas.implicitHeight)
    }
    // Distinguishes: a placeholder admitted as a real screen. Two "monitors" turn the layout
    // multi-monitor — chip bands, group insets, a backdrop — for a machine with one display.
    function test_a_placeholder_monitor_is_not_a_second_group() {
        compare(view.multiMonitor, false)
        var names = []
        for (var i = 0; i < view.groups.length; i++) names.push(view.groups[i].monitorName)
        compare(names.indexOf("?"), -1, "a placeholder must not own a group: " + names.join(","))
    }
    function boxIds() {
        var ids = []
        for (var i = 0; i < view.boxes.length; i++) ids.push(view.boxes[i].workspaceId)
        ids.sort(function (a, b) { return a - b })
        return ids
    }
    // Distinguishes: a monitorless workspace dropped from the picture instead of shown. It has a
    // key like any other and SUPER+6 jumps to it, so it gets a well — on the focused monitor,
    // since the one it names is not on screen anywhere. Every box keeps finite geometry and none
    // claims the placeholder's name.
    function test_a_workspace_on_no_monitor_still_gets_a_well() {
        compare(boxIds().indexOf(6) !== -1, true, "no well for workspace 6: " + boxIds().join(","))
        for (var i = 0; i < view.boxes.length; i++) {
            var b = view.boxes[i]
            verify(isFinite(b.h) && b.h > 0, "box " + b.workspaceId + " height " + b.h)
            verify(isFinite(b.y), "box " + b.workspaceId + " y " + b.y)
            compare(b.monitorName, "TEST", "box " + b.workspaceId + " sits on " + b.monitorName)
        }
    }
    // Distinguishes: THE regression a naive "skip what has no monitor" produces (reported on a
    // real desktop, 2026-09-18). `workspaces: N` promises a well for every key 1–0 whether or not
    // Hyprland has created it, and padWorkspaces leans each synthetic id on the nearest lower
    // REAL one's monitor — so a real workspace 6 that names a monitor nothing knows takes 7, 8
    // and 9 down with it, and the grid stops at the ids below it.
    function test_padding_fills_every_key_past_a_monitorless_workspace() {
        view.testConfig.workspaces = 10
        view.rebuild()
        wait(50)
        compare(boxIds(), [1,2,3,4,5,6,7,8,9,10])
        for (var i = 0; i < view.boxes.length; i++)
            compare(view.boxes[i].monitorName, "TEST",
                    "box " + view.boxes[i].workspaceId + " sits on " + view.boxes[i].monitorName)
    }
}
