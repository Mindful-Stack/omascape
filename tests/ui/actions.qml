import QtQuick
import QtTest

// Offscreen UI suite for the actions spec (docs/specs/2026-09-15-actions-design.md). The fixture
// (tests/ui/prepare.py) runs the real Overview with the compositor replaced by a stub that records
// dispatches, so everything here exercises production key handling, hit testing and model
// reconciliation — only the compositor and the two Quickshell.Io components are stubbed.
TestCase {
    id: tc
    name: "Actions"
    when: windowShown
    width: 1200; height: 800; visible: true
    property var view
    property var mon

    Component { id: overview; Overview {} }

    // Workspace 1 holds two tiled windows side by side (A left, B right); workspace 2 holds one.
    // Side-by-side, not stacked, so reading order is decided by x and a y-only sort would fail.
    function client(addr, cls, x) {
        return { address: addr, at: [x, 1500], size: [400, 400], floating: false,
                 title: cls, "class": cls, fullscreen: 0 }
    }
    function wsRow(id, clients) {
        return { id: id, monitor: mon,
                 toplevels: { values: clients.map(function (c) { return { lastIpcObject: c } }) } }
    }
    function seed(v) {
        mon = { name: "TEST", x: 0, y: 1440, width: 1920, height: 1080, scale: 1,
                lastIpcObject: { reserved: [0, 26, 0, 0], transform: 0,
                                 activeWorkspace: { id: 1 }, specialWorkspace: { id: 0, name: "" } } }
        v.compositor.monitors = { values: [mon] }
        v.compositor.focusedMonitor = mon
        v.compositor.focusedWorkspace = { id: 1 }
        v.compositor.workspaces = { values: [
            wsRow(1, [client("0xA", "alpha", 100), client("0xB", "bravo", 900)]),
            wsRow(2, [client("0xC", "charlie", 100)])
        ] }
    }
    function init() {
        // QtQuickTest runs this file's test functions in alphabetical order, not declaration
        // order, and the real synthetic cursor lives on the shared TestCase window, not on the
        // (fresh, per-test) `view`. Without this, a test earlier in that alphabetical order that
        // ends with the pointer resting over a tile (e.g. test_a_lone_modifier_press_changes_nothing)
        // leaves the OS-level cursor there; the next test's freshly-created Overview lays its own
        // tile out at the identical screen position, and Qt's normal hover reconciliation on the
        // new item fires the HoverHandler immediately — before that test has done anything of its
        // own. Parking off any tile first is test-isolation only: it changes nothing the suite
        // asserts about liveness, only when the *previous* test's mouse motion is allowed to count.
        mouseMove(tc, -50, -50)
        view = createTemporaryObject(overview, tc)
        verify(view !== null)
        view.motion.scale = 0            // no entrance/exit fade to wait for
        seed(view)
        view.open()
        wait(400)
        view.compositor.commands = []    // drop the lock install/sync chunks open() dispatches
    }
    function cleanup() { view.close() }

    // Centre of a tile in TestCase coordinates, for mouseMove/mousePress.
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

    // ---- fixture health ------------------------------------------------------------------
    // Distinguishes: a fixture where keyClick never reaches keyCatcher. Escape on an empty query
    // closes, an effect only Keys.onPressed can produce.
    function test_keys_reach_the_catcher() {
        verify(view.testKeys.activeFocus, "keyCatcher must hold active focus after open()")
        keyClick(Qt.Key_Escape)
        compare(view.opened, false)
    }
    // Distinguishes: a fixture where a synthetic mouseMove never reaches the HoverHandler — which
    // would make every pointer-targeting test below vacuously pass on the keyboard path.
    function test_a_mouse_move_makes_the_pointer_live() {
        compare(view.pointerLive, false, "no pointer motion has happened yet")
        hoverTile("0xA")
        compare(view.pointerLive, true)
        var t = view.resolveTarget()
        compare(t.kind, "window"); compare(t.address, "0xA")
    }
    // Distinguishes: a hit test reading the model instead of the delegates. Both agree here, so
    // this only pins that the fixture's delegate geometry matches the rows the other tests use.
    function test_tile_candidates_match_the_model_rows() {
        compare(view.tileCandidates().length, view.testModel.count)
    }

    // ---- key classes ---------------------------------------------------------------------
    // Distinguishes: a navigation key that fails to clear liveness — the parked-mouse bug. After
    // an arrow the pointer must no longer decide, even though it never moved.
    function test_a_navigation_key_clears_pointer_liveness() {
        hoverTile("0xA")
        keyClick(Qt.Key_Right)
        compare(view.pointerLive, false)
    }
    // Distinguishes: THE regression the spec's key classes exist to prevent. A lone Ctrl press
    // must not clear liveness, or hover + Ctrl+W could never act on the hovered tile.
    function test_a_lone_modifier_press_changes_nothing() {
        hoverTile("0xA")
        keyPress(Qt.Key_Control)
        compare(view.pointerLive, true, "Ctrl alone is neither navigation nor an action")
        keyRelease(Qt.Key_Control)
        compare(view.pointerLive, true)
    }
    // Distinguishes: a printable key that leaves liveness set, which would make a hovered tile
    // outrank the find match the user just typed.
    function test_typing_clears_pointer_liveness() {
        hoverTile("0xA")
        keyClick("a")
        compare(view.pointerLive, false)
        compare(view.query, "a")
    }
}
