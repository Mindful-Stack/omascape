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
    // A point inside a box but on NO tile: the well. Only valid for an unoccupied workspace — a
    // box with even one tiled window leaves a few px of bare well at the inset, so the centre is
    // the tile, and a "well click" test would silently become a tile-click test. The guard makes
    // a future wellCentre(1) fail loudly instead.
    function wellCentre(wsId) {
        var b = boxOf(wsId)
        verify(!b.occupied, "wellCentre(" + wsId + ") needs an EMPTY workspace; this one has windows")
        return view.testCanvas.mapToItem(view, b.x + b.w / 2, b.y + b.h / 2)
    }

    // ---- fixture health ------------------------------------------------------------------
    // Test ordering: QtQuickTest runs these ALPHABETICALLY, not in declaration order. The health
    // checks below are named `test_a_` so a broken fixture reports before anything that depends
    // on it; later tasks take `test_b_`, `test_c_`, … in the order they were added.
    //
    // Distinguishes: a fixture whose stub config has no `activate` property. Then
    // config.activate is undefined, every `=== "select"` test in this file is silently false and
    // the overview runs in enter mode while the suite still passes. Note this proves only that
    // the STUB declares the name — that production reads the same name is proved by the first
    // test that asserts on behaviour, not here.
    function test_a_the_fixture_carries_the_activate_policy() {
        compare(view.testConfig.activate, "select",
                "prepare.py's stub OmascapeConfig must declare `activate`")
        verify(view.testKeys.activeFocus, "keyCatcher must hold active focus after open()")
    }
    // Distinguishes: a seed that produced no boxes or no tiles at all — a buildInput regression or
    // a botched wsRow — which every loop-based check in this file would pass vacuously, leaving
    // later tests to fail with confusing symptoms instead of one loud message here. The ws-7
    // assertion is the other half: a seed where 7 accidentally exists makes every
    // "digit with no box" test vacuous in the opposite direction.
    function test_a_the_seed_is_what_the_later_tests_assume() {
        compare(view.boxes.length, 3, "workspaces 1, 2 and 3 must all have boxes")
        compare(view.testModel.count, 3, "three windows: 0xA and 0xB on ws 1, 0xC on ws 2")
        verify(!boxOf(3).occupied, "workspace 3 must stay empty; the well tests need it")
        for (var i = 0; i < view.boxes.length; i++)
            verify(view.boxes[i].workspaceId !== 7, "workspace 7 must not have a box")
    }
}
