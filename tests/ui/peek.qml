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
    // Workspace 1's "bravo" window (0xB), captured by reference at seed() time so a test can
    // mutate its title/position in place and call view.rebuild() to re-derive `root._windows` —
    // the same pattern tests/ui/drag.qml uses for its own `client`. Only the mini-map churn probes
    // below need this; every other test in this file goes through the compositor fixture only.
    property var winB

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
        winB = client("0xB", "bravo", 900)
        v.compositor.monitors = { values: [mon] }
        v.compositor.focusedMonitor = mon
        v.compositor.focusedWorkspace = { id: 1 }
        v.compositor.workspaces = { values: [
            wsRow(1, [client("0xA", "alpha", 100), winB]),
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

    // Distinguishes: a re-press treated as a fresh open once the hold's cancellation is the only
    // thing guarding it (the plan's own missing "no-op when the hold is cancelled" row). A first
    // press with no target aborts the hold and sets `peekCancelled`; clearing the query mid-hold
    // makes a target exist again, but the SAME physical press must stay inert until the key is
    // actually released — a second press must not reopen it just because resolving would now
    // succeed. Red if the whole guard (`Overview.qml`'s `if (root.peeking || root.peekCancelled)
    // return`) is deleted; red if only the `|| root.peekCancelled` clause is removed; red if the
    // no-target branch stops setting `peekCancelled` (`root.peekAbort()`).
    function test_a_press_after_cancellation_stays_closed_for_the_rest_of_the_hold() {
        keyClick("z"); keyClick("z"); keyClick("z")
        compare(view.matches.length, 0, "precondition: a query with no match")
        keyPress(Qt.Key_Space)
        compare(view.peeking, false, "no target: the press aborts, nothing opens")
        view.setQuery("")
        verify(view.resolveTarget() !== null, "precondition: a target exists again")
        keyPress(Qt.Key_Space)
        compare(view.peeking, false,
                "still cancelled: a target reappearing mid-hold does not reopen the SAME hold")
        keyRelease(Qt.Key_Space)
    }

    // PROVISIONAL: this pins a transitional state, not the spec's final word on it. Once Task 8
    // adds the rebuild()-driven disappearance check, a target that stops resolving mid-hold ought
    // to end the hold on its own (via that check), not merely leave the layer showing nothing.
    // Until then, this test is the guard's OTHER half: a null target on a REPEAT press must not
    // retroactively cancel a hold that already opened successfully — cancellation is a decision
    // the no-target branch makes once, at open, not something a later press re-derives. Red if
    // the whole guard is deleted (a second press would re-run the no-target branch and set
    // `peekCancelled`); correctly stays green if only the cancelled half above is removed, since
    // this hold was never cancelled to begin with.
    function test_a_second_press_after_the_target_stops_resolving_does_not_cancel_the_hold() {
        var t = view.resolveTarget()
        verify(t !== null && t.kind === "workspace", "precondition: the target is a workspace")
        keyPress(Qt.Key_Space)
        compare(view.peeking, true)
        keyClick("z"); keyClick("z"); keyClick("z")
        compare(view.matches.length, 0, "precondition: the query now matches nothing")
        keyPress(Qt.Key_Space)
        compare(view.peekCancelled, false, "a repeat press does not retroactively cancel the hold")
        compare(view.peeking, true, "and the hold is still open")
        keyRelease(Qt.Key_Space)
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

    // Distinguishes: `open()`'s own `peekReset()` call being deleted. Nothing inside a single
    // hold would notice that loss (`test_a_press_after_cancellation...` above covers a repeat
    // press within the SAME hold, which is a different code path), but a `peekCancelled` left set
    // from a hold that was still cancelled when the overview closed — the key's release event
    // never arrives at an unfocused surface, so nothing else clears it — would silently swallow
    // the very first Space of the NEXT summon. Leaves a hold cancelled, closes without ever
    // releasing Space, reopens, and presses Space again: a fresh summon must not inherit the
    // previous one's cancellation.
    function test_a_fresh_summon_is_not_inert_from_a_previous_cancelled_hold() {
        keyClick("z"); keyClick("z"); keyClick("z")
        compare(view.matches.length, 0, "precondition: a query with no match")
        keyPress(Qt.Key_Space)
        compare(view.peekCancelled, true, "precondition: the hold is cancelled")
        view.close(); wait(50); view.open(); wait(400)
        verify(view.resolveTarget() !== null,
               "precondition: open() resets the query, so a target exists again")
        keyPress(Qt.Key_Space)
        compare(view.peeking, true,
                "a fresh summon is not held inert by the previous summon's cancellation")
        keyRelease(Qt.Key_Space)
    }

    // ---- the mini-map's window-list cache (Task 7 review, item 1) --------------------------

    // Distinguishes: `peekWorkspaceWindowsFor()`'s cache losing identity stability on a change
    // that should NOT bust it. A title-only edit touches none of the fields the mini-map's
    // placement (`_placeWindows`/`peekTiles` in logic.js) actually reads — `address`, `ax`, `ay`,
    // `sw`, `sh`, `floating`, `fullscreen`, `workspaceId` — so the cached array must come back
    // UNCHANGED: the same array object, not merely an equal one. Identity is the whole point and
    // is invisible from the array's contents alone: PeekLayer's Repeater keys its `model` on that
    // identity, and a fresh-but-equal array reassigns the model, destroying and recreating every
    // WindowTile underneath it — and with it, every live ScreencopyView capture, mid-hold, on
    // compositor traffic that has nothing to do with the peeked workspace. No capture exists in
    // this offscreen tier to show the restart directly (see this file's own header comment), so
    // this checks the one proxy that stands in for it: whether the array reference itself moved.
    function test_a_title_only_change_keeps_the_mini_maps_window_list_identity() {
        var t = view.resolveTarget()
        verify(t !== null && t.kind === "workspace", "precondition: the target is a workspace")
        keyPress(Qt.Key_Space)
        var before = view.testPeek.workspaceWindows
        verify(before.length === 2, "precondition: workspace 1 has two windows")
        winB.title = "bravo-renamed"
        view.rebuild()
        verify(view.testPeek.workspaceWindows === before,
               "a title-only change must not reassign the mini-map's window list")
        keyRelease(Qt.Key_Space)
    }

    // Distinguishes: the cache's OTHER failure mode — one that never busts and serves stale
    // geometry forever. Moving 0xB changes `ax`, one of the fields the signature is built from
    // (see the test above), so the cache must miss: a NEW array, whose row for 0xB carries the
    // NEW position rather than the one cached before the move. Read together, these two tests pin
    // both directions of the cache and rule out the two mutations a reviewer found green against
    // the original implementation (disabling the cache outright, and a cache that ignores its own
    // signature).
    function test_a_moved_window_busts_the_mini_maps_cache_with_fresh_geometry() {
        var t = view.resolveTarget()
        verify(t !== null && t.kind === "workspace", "precondition: the target is a workspace")
        keyPress(Qt.Key_Space)
        var before = view.testPeek.workspaceWindows
        var beforeAx = -1
        for (var i = 0; i < before.length; i++) if (before[i].address === "0xB") beforeAx = before[i].ax
        verify(beforeAx >= 0, "precondition: 0xB is in the mini-map's window list")
        winB.at = [winB.at[0] + 50, winB.at[1]]
        view.rebuild()
        var after = view.testPeek.workspaceWindows
        verify(after !== before, "a geometry change must bust the cache")
        var afterAx = -1
        for (var j = 0; j < after.length; j++) if (after[j].address === "0xB") afterAx = after[j].ax
        compare(afterAx, beforeAx + 50, "the cache must not serve 0xB's stale position")
        keyRelease(Qt.Key_Space)
    }
}
