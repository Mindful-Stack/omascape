import QtQuick
import QtTest

// Offscreen UI suite for the peek spec (docs/specs/2026-09-18-peek-design.md). The fixture
// (tests/ui/prepare.py) runs the real Overview with only the compositor stubbed, so key routing,
// target resolution and model reconciliation are production code here.
//
// What this tier CANNOT show: ScreencopyView has no content offscreen — no compositor, no
// toplevel handles — so every peeked tile falls back to its icon. Every assertion below is on
// geometry, counts or state. "The capture appeared" is a Tier 2 check (tests/integration/).
TestCase {
    id: tc
    name: "Peek"
    when: windowShown
    width: 1200; height: 800; visible: true
    property var view
    property var mon

    Component { id: overview; Overview {} }

    // Workspace 1 holds two tiled windows side by side (A left, B right); workspace 2 holds one.
    function client(addr, cls, x) {
        return { address: addr, at: [x, 1500], size: [400, 400], floating: false,
                 title: cls, "class": cls, fullscreen: 0 }
    }
    function wsRow(id, clients) {
        return { id: id, monitor: mon,
                 toplevels: { values: clients.map(function (c) { return { lastIpcObject: c } }) } }
    }
    // A floating scratchpad window on Hyprland's own dynamic special-workspace id, named so
    // buildInput() remaps it onto Logic.SCRATCHPAD_ID (-2). Mirrors tests/ui/scratchpad.qml.
    function scratchRow(hyprId, addr, cls) {
        return { id: hyprId, name: "special:scratchpad", monitor: mon,
                 toplevels: { values: [{ lastIpcObject: { address: addr, at: [900, 1500],
                                                           size: [400, 400], floating: true,
                                                           title: cls, "class": cls,
                                                           fullscreen: 0 } }] } }
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
    // QtQuickTest runs functions in ALPHABETICAL order and this file shares one QQuickWindow, so
    // the synthetic cursor arrives wherever the previous test left it. Parking it off every tile
    // makes each test's own hover a real move — see tests/ui/actions.qml's init() for the full
    // account of what this prevents.
    function init() {
        mouseMove(tc, -50, -50)
        view = createTemporaryObject(overview, tc)
        verify(view !== null)
        view.motion.scale = 0
        seed(view)
        view.open()
        wait(400)
        view.compositor.commands = []
    }
    function cleanup() { view.close() }

    function tileCentre(addr) {
        for (var i = 0; i < view.testModel.count; i++) {
            var r = view.testModel.get(i)
            if (r.address !== addr) continue
            return view.testCanvas.mapToItem(view, r.wx + r.ww / 2, r.wy + r.wh / 2)
        }
        fail("no tile row for " + addr); return null
    }
    function hoverTile(addr) { var p = tileCentre(addr); mouseMove(view, p.x, p.y); wait(30) }

    // ---- fixture health ------------------------------------------------------------------

    // Distinguishes: a fixture where PeekLayer was never instantiated, or where the testPeek
    // alias points at something else. Every behaviour test below reads view.testPeek.shown, and
    // an undefined property compares equal to nothing useful — this fails loudly instead.
    function test_the_fixture_exposes_a_peek_layer() {
        verify(view.testPeek !== null && view.testPeek !== undefined, "testPeek alias missing")
        compare(view.testPeek.shown, false, "the peek starts closed")
        verify(view.testPeek.boxW > 0 && view.testPeek.boxH > 0,
               "the 60% box has real geometry: " + view.testPeek.boxW + "x" + view.testPeek.boxH)
    }

    // Distinguishes: a fixture whose keys never reach keyCatcher — the failure mode that makes
    // every key test below pass vacuously. Escape on an empty query closes the overview; if this
    // does not happen, nothing else in this file means anything.
    function test_the_fixture_delivers_keys() {
        keyClick(Qt.Key_Escape)
        compare(view.opened, false)
    }

    // Distinguishes: a fixture where the pointer cannot target a tile, which would make every
    // "Space peeks the hovered window" assertion untestable. Positive control for hoverTile().
    function test_the_fixture_can_hover_a_tile() {
        hoverTile("0xB")
        var t = view.resolveTarget()
        verify(t !== null, "hovering a tile must resolve a target")
        compare(t.kind, "window"); compare(t.address, "0xB")
    }
}
