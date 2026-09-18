import QtQuick
import QtTest

// Offscreen UI suite for the peek spec (docs/specs/2026-09-18-peek-design.md). The fixture
// (tests/ui/prepare.py) runs the real Overview with only the compositor stubbed, so key routing,
// target resolution and model reconciliation are production code here. This file currently holds
// fixture-health tests only (Task 6); key routing, targeting and cancellation behaviour tests
// land on top of it in Tasks 7 and 8.
//
// What this tier CANNOT show: ScreencopyView has no content offscreen — no compositor, no
// toplevel handles — so every peeked tile falls back to its icon. Every assertion below (and in
// the behaviour tests to come) is on geometry, counts or state. "The capture appeared" is a
// Tier 2 check (tests/integration/).
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
    // Unused in this file's own tests: Task 8 peeks the scratchpad row specifically to exercise
    // the negative workspace id through the peek's identity round-trip. Keep it.
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
    // does not happen, nothing else in this file means anything. The precondition matters as
    // much as the outcome: without asserting `opened` is true first, this test cannot tell
    // "Escape closed it" from "it was never open" — a fixture whose init() silently skipped
    // open() would still show `opened === false` afterwards and this canary would pass vacuously.
    function test_the_fixture_delivers_keys() {
        compare(view.opened, true, "init() must leave the overview open")
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

    // ---- the hold ------------------------------------------------------------------------

    // Distinguishes: a Space that does not open the peek at all, and one that opens it on the
    // wrong target. The pointer is over 0xB while the keyboard's own target is elsewhere.
    function test_space_peeks_the_hovered_window() {
        hoverTile("0xB")
        keyPress(Qt.Key_Space)
        compare(view.peeking, true)
        compare(view.testPeek.shown, true)
        compare(view.testPeek.peekTarget.kind, "window")
        compare(view.testPeek.peekTarget.address, "0xB")
        keyRelease(Qt.Key_Space)
        compare(view.peeking, false)
        compare(view.testPeek.shown, false)
    }

    // Distinguishes: a Space routed as ordinary keyboard intent. This is the whole point of
    // Task 3 — the key handler clears pointerLive for non-action keys BEFORE resolving, so a
    // mis-routed Space peeks the Tab cursor (0xA) instead of the hovered tile (0xB). Both
    // targets exist and differ, which is what makes the assertion discriminate.
    function test_space_prefers_the_pointer_over_the_keyboard_target() {
        keyClick(Qt.Key_Tab)
        compare(view.cursorAddress, "0xA", "precondition: the keyboard target is 0xA")
        hoverTile("0xB")
        keyPress(Qt.Key_Space)
        compare(view.testPeek.peekTarget.address, "0xB", "the hovered tile wins")
        keyRelease(Qt.Key_Space)
        compare(view.cursorAddress, "0xA", "and the cursor is untouched by the hold")
    }

    // Distinguishes: a peek that snapshots its target at press time. Tab moves the cursor while
    // the key is still down; a snapshotting implementation keeps showing the first window.
    function test_the_peek_follows_the_cursor_while_held() {
        keyClick(Qt.Key_Tab)
        var first = view.cursorAddress
        keyPress(Qt.Key_Space)
        compare(view.testPeek.peekTarget.address, first)
        keyClick(Qt.Key_Tab)
        verify(view.cursorAddress !== first, "precondition: Tab moved the cursor")
        compare(view.testPeek.peekTarget.address, view.cursorAddress,
                "the peek re-targeted without a release")
        keyRelease(Qt.Key_Space)
    }

    // Distinguishes: a peek that follows the Tab cursor but not the arrows. The arrows move the
    // SELECTION, which is a different resolve branch from the cursor — an implementation that
    // re-reads the target only in the Tab path passes the test above and fails this one. Right,
    // not Down: this file's two seeded workspaces (ws1, ws2) land side-by-side in one row (see
    // seed()), so Right is the axis with a neighbour here — Down has no box below and would
    // no-op regardless of the implementation, which is not what this test is for.
    function test_the_peek_follows_the_selection_while_held() {
        keyPress(Qt.Key_Space)
        compare(view.testPeek.peekTarget.kind, "workspace")
        var first = view.testPeek.peekTarget.id
        keyClick(Qt.Key_Right)
        verify(view.selectedId !== first, "precondition: Right moved the selection")
        compare(view.testPeek.peekTarget.id, view.selectedId,
                "the peek re-targeted to the newly selected workspace")
        keyRelease(Qt.Key_Space)
    }

    // Distinguishes: a Space still reaching appendQueryText. The query must be byte-identical
    // across the whole hold — a spec rule with no exceptions ("`Space`, any state").
    function test_space_never_extends_the_query() {
        keyClick("a")
        var q = view.query
        verify(q.length > 0, "precondition: a query is active")
        keyPress(Qt.Key_Space)
        keyRelease(Qt.Key_Space)
        compare(view.query, q, "the query must be unchanged")
    }

    // Distinguishes: a peek opening on a workspace as if it were a window, or not opening at
    // all. Hovering the canvas inside a workspace box but off every tile is the workspace-target
    // case; the mini-map must place one row per window on that workspace.
    function test_space_peeks_a_workspace_as_a_mini_map() {
        // No Escape here: with no live pointer and no cursor — the state open() leaves — the
        // target is already the selected workspace. (Escape in that state would `close()` the
        // overview, not clear a cursor.)
        var t = view.resolveTarget()
        verify(t !== null && t.kind === "workspace", "precondition: the target is a workspace")
        keyPress(Qt.Key_Space)
        compare(view.testPeek.shown, true)
        compare(view.testPeek.peekTarget.kind, "workspace")
        compare(view.testPeek.workspaceWindows.length, 2,
                "workspace 1's two windows are handed to the mini-map")
        keyRelease(Qt.Key_Space)
    }

    // Distinguishes: an open decision re-evaluated on every press rather than guarded on state —
    // the shape a real auto-repeat would take. QtTest cannot set isAutoRepeat (see
    // tests/ui/actions.qml:426), so a second plain press while held is the closest offscreen
    // proxy, and the spec's guard is written on state precisely so this proxy is meaningful.
    function test_a_second_press_while_held_changes_nothing() {
        hoverTile("0xB")
        keyPress(Qt.Key_Space)
        compare(view.testPeek.shown, true)
        var target = view.testPeek.peekTarget.address
        keyPress(Qt.Key_Space)
        compare(view.testPeek.shown, true, "still open, not toggled shut")
        compare(view.testPeek.peekTarget.address, target, "and still on the same target")
        keyRelease(Qt.Key_Space)
        compare(view.testPeek.shown, false, "one release closes it")
    }

    // Distinguishes: a hold that arms and opens later. With no target at the press, the spec
    // gives the whole hold nothing — hovering a tile mid-hold must not pop a preview in.
    //
    // "No target" is produced with a query that matches nothing, which is the terminal no-target
    // case `Logic.target` documents. Hovering blank canvas is NOT a reliable way to get one here:
    // `hitWorkspace` returns null only outside every box, so the pointer would have to land in a
    // gap whose existence depends on the fixture's canvas size.
    function test_a_press_with_no_target_stays_closed_for_the_whole_hold() {
        keyClick("z"); keyClick("z"); keyClick("z")
        compare(view.matches.length, 0, "precondition: a query with no match")
        verify(view.resolveTarget() === null, "precondition: no target")
        keyPress(Qt.Key_Space)
        compare(view.testPeek.shown, false)
        hoverTile("0xB")
        compare(view.testPeek.shown, false, "the hold does not open late")
        keyRelease(Qt.Key_Space)
        keyPress(Qt.Key_Space)
        compare(view.testPeek.shown, true, "a fresh press opens normally")
        keyRelease(Qt.Key_Space)
    }

    // Distinguishes: a peek left open when the overview closes while the key is still down — the
    // stuck-forever case, since the release event never arrives at an unfocused surface.
    function test_closing_the_overview_clears_a_held_peek() {
        hoverTile("0xB")
        keyPress(Qt.Key_Space)
        compare(view.testPeek.shown, true)
        view.close()
        compare(view.peeking, false, "peeking is force-cleared, not waiting on a release")
        compare(view.testPeek.shown, false)
        keyRelease(Qt.Key_Space)
    }
}
