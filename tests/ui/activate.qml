import QtQuick
import QtTest

// Offscreen UI suite for the activate spec (docs/specs/2026-09-18-activate-select-design.md).
// The fixture (tests/ui/prepare.py) runs the real Overview against a stub compositor that records
// dispatches, so key handling, hit testing and model reconciliation are production code.
//
// NOTE: the fixture config sets `workspaces: 0` (no padding), so only workspaces seeded below have
// boxes. Workspace 7 deliberately does not exist: it is the "digit with no box" case.
TestCase {
    id: tc
    name: "Activate"
    when: windowShown
    width: 1200; height: 800; visible: true
    property var view
    property var mon

    Component { id: overview; Overview {} }

    function client(addr, cls, x) {
        return { address: addr, at: [x, 1500], size: [400, 400], floating: false,
                 title: cls, "class": cls, fullscreen: 0 }
    }
    function wsRow(id, clients) {
        return { id: id, monitor: mon,
                 toplevels: { values: clients.map(function (c) { return { lastIpcObject: c } }) } }
    }
    // Workspace 1: two tiled windows side by side. Workspace 2: one. Workspace 3: empty, so a
    // well click has a box with no tiles in it.
    function seed(v) {
        mon = { name: "TEST", x: 0, y: 1440, width: 1920, height: 1080, scale: 1,
                lastIpcObject: { reserved: [0, 26, 0, 0], transform: 0,
                                 activeWorkspace: { id: 1 }, specialWorkspace: { id: 0, name: "" } } }
        v.compositor.monitors = { values: [mon] }
        v.compositor.focusedMonitor = mon
        v.compositor.focusedWorkspace = { id: 1 }
        v.compositor.workspaces = { values: [
            wsRow(1, [client("0xA", "alpha", 100), client("0xB", "bravo", 900)]),
            wsRow(2, [client("0xC", "charlie", 100)]),
            wsRow(3, [])
        ] }
    }
    function init() {
        // QtQuickTest runs these alphabetically and the window is shared, so the synthetic cursor
        // arrives wherever the previous test left it. Parking it off every tile makes each test's
        // own hover a real move that arms pointerLive.
        mouseMove(tc, -50, -50)
        view = createTemporaryObject(overview, tc)
        verify(view !== null)
        view.motion.scale = 0            // no entrance/exit fade to wait for
        seed(view)
        view.testConfig.activate = "select"
        view.open()
        wait(400)
        view.compositor.commands = []    // drop the lock install/sync chunks open() dispatches
    }
    function cleanup() { view.close() }

    function tileCentre(addr) {
        for (var i = 0; i < view.testModel.count; i++) {
            var r = view.testModel.get(i)
            if (r.address !== addr) continue
            var p = view.testCanvas.mapToItem(view, r.wx + r.ww / 2, r.wy + r.wh / 2)
            return p
        }
        fail("no tile row for " + addr)
    }
    function hoverTile(addr) { var p = tileCentre(addr); mouseMove(view, p.x, p.y); wait(30) }
    function boxOf(wsId) {
        for (var i = 0; i < view.boxes.length; i++)
            if (view.boxes[i].workspaceId === wsId) return view.boxes[i]
        fail("no box for workspace " + wsId)
    }
    // A point inside a box but on no tile: the well. Workspace 3 is empty, so its centre works.
    function wellCentre(wsId) {
        var b = boxOf(wsId)
        return view.testCanvas.mapToItem(view, b.x + b.w / 2, b.y + b.h / 2)
    }

    // ---- fixture health ------------------------------------------------------------------
    // Distinguishes: a fixture whose stub config has no `activate` property. Then
    // config.activate is undefined, every `=== "select"` test in this file is silently false,
    // the overview runs in enter mode, and the whole suite passes while testing nothing.
    function test_a_the_fixture_carries_the_activate_policy() {
        compare(view.testConfig.activate, "select",
                "prepare.py's stub OmascapeConfig must declare `activate`")
        verify(view.testKeys.activeFocus, "keyCatcher must hold active focus after open()")
    }
    // Distinguishes: a seed where workspace 7 accidentally exists, which would make every
    // missing-box assertion in this file vacuous.
    function test_a_workspace_seven_has_no_box() {
        for (var i = 0; i < view.boxes.length; i++)
            verify(view.boxes[i].workspaceId !== 7, "workspace 7 must not have a box")
    }
}
