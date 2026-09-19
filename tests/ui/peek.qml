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
    // mis-routed Space peeks the arrow cursor (0xA) instead of the hovered tile (0xB). Both
    // targets exist and differ, which is what makes the assertion discriminate. Right, not Tab,
    // sets the precondition: since ec6083b, Tab steps workspaces and clears the cursor as a side
    // effect, so it can no longer be the key that puts a window under keyboard target in the
    // first place — only an arrow does that now.
    function test_space_prefers_the_pointer_over_the_keyboard_target() {
        keyClick(Qt.Key_Right)
        compare(view.cursorAddress, "0xA", "precondition: the keyboard target is 0xA")
        hoverTile("0xB")
        keyPress(Qt.Key_Space)
        compare(view.testPeek.peekTarget.address, "0xB", "the hovered tile wins")
        keyRelease(Qt.Key_Space)
        compare(view.cursorAddress, "0xA", "and the cursor is untouched by the hold")
    }

    // Distinguishes: a peek that snapshots its target at press time. An arrow moves the window
    // cursor while the key is still down; a snapshotting implementation keeps showing the first
    // window. Right, not Tab: since ec6083b, Tab steps workspaces and clears the cursor as a
    // side effect rather than moving it, so only an arrow exercises the cursor-follows-live-hold
    // path this test is named for.
    function test_the_peek_follows_the_cursor_while_held() {
        keyClick(Qt.Key_Right)
        var first = view.cursorAddress
        keyPress(Qt.Key_Space)
        compare(view.testPeek.peekTarget.address, first)
        keyClick(Qt.Key_Right)
        verify(view.cursorAddress !== first, "precondition: Right moved the cursor")
        compare(view.testPeek.peekTarget.address, view.cursorAddress,
                "the peek re-targeted without a release")
        keyRelease(Qt.Key_Space)
    }

    // Distinguishes: a peek that follows the arrow-key cursor but not Tab's workspace selection.
    // Tab moves the SELECTION (and, as a side effect, clears the cursor), which is a different
    // resolve branch from the cursor — an implementation that re-reads the target only in the
    // arrow path passes the test above and fails this one. This used to be an arrow test too
    // (Down, then Right after a fixture-driven rewrite), back when arrows drove the selection;
    // since ec6083b inverted the keys, Tab is the one and only selection key, so it no longer
    // needs a geometry-dependent direction to find a neighbour — cycleWorkspace steps the boxes
    // list itself, not the screen layout.
    function test_the_peek_follows_the_selection_while_held() {
        keyPress(Qt.Key_Space)
        compare(view.testPeek.peekTarget.kind, "workspace")
        var first = view.testPeek.peekTarget.id
        keyClick(Qt.Key_Tab)
        verify(view.selectedId !== first, "precondition: Tab moved the selection")
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
    //
    // Review note (round 2): the `hoverTile` assertion below is satisfied by `peeking` simply
    // never having become true — it would stay green even if the no-target press latched nothing
    // at all. The repeat `keyPress` added after it is what actually pins the LATCH this test's own
    // name claims ("for the WHOLE hold"): a target now exists (0xB is hovered), so a press that
    // merely re-checked `peeking` (false) with no cancel to also check would wrongly open here.
    function test_a_press_with_no_target_stays_closed_for_the_whole_hold() {
        keyClick("z"); keyClick("z"); keyClick("z")
        compare(view.matches.length, 0, "precondition: a query with no match")
        verify(view.resolveTarget() === null, "precondition: no target")
        keyPress(Qt.Key_Space)
        compare(view.testPeek.shown, false)
        hoverTile("0xB")
        compare(view.testPeek.shown, false, "the hold does not open late")
        keyPress(Qt.Key_Space)
        compare(view.testPeek.shown, false,
                "a repeat press within the SAME hold must stay closed even though a target now exists")
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

    // ---- cancellation --------------------------------------------------------------------

    // Distinguishes: a peek that slides to a successor when its window closes. 0xB vanishes
    // mid-hold; the target then falls through to the selected workspace, which is a perfectly
    // valid target — so an implementation keyed on "the target went null" keeps the layer open
    // on a workspace the user never chose, and passes every test that only checks peekTarget.
    function test_a_closed_window_cancels_the_hold() {
        hoverTile("0xB")
        keyPress(Qt.Key_Space)
        compare(view.testPeek.shown, true)
        view.compositor.workspaces = { values: [
            wsRow(1, [client("0xA", "alpha", 100)]),
            wsRow(2, [client("0xC", "charlie", 100)])
        ] }
        view.rebuild()
        compare(view.peekCancelled, true)
        compare(view.testPeek.shown, false, "the layer is gone")
        keyClick(Qt.Key_Tab)
        compare(view.testPeek.shown, false, "and navigation does not bring it back")
        keyRelease(Qt.Key_Space)
        compare(view.peekCancelled, false, "the release clears the cancel")
        keyPress(Qt.Key_Space)
        compare(view.testPeek.shown, true, "a fresh press peeks again")
        keyRelease(Qt.Key_Space)
    }

    // Distinguishes: a cancel keyed on "the resolved target changed" rather than on the model.
    // Escape clears the cursor, which retargets the peek to the selected workspace — intentional
    // navigation, not disappearance. Nothing left the model, so the peek must FOLLOW, not cancel.
    // This is the negative control for the test above; without it, "cancel whenever the target
    // changes" passes everything else in this file. Since ec6083b, Tab ALSO clears the cursor —
    // as a side effect of stepping the workspace selection — so this test deliberately uses an
    // arrow to set the cursor and Escape to clear it, not Tab for either: the point here is
    // Escape's clear-without-cancel, and folding Tab's own clearing side effect in would test
    // something else entirely.
    function test_clearing_the_cursor_retargets_without_cancelling() {
        keyClick(Qt.Key_Right)
        keyPress(Qt.Key_Space)
        compare(view.testPeek.peekTarget.kind, "window")
        keyClick(Qt.Key_Escape)                  // clears the cursor; the window still exists
        compare(view.peekCancelled, false, "navigation must not cancel")
        compare(view.testPeek.shown, true)
        compare(view.testPeek.peekTarget.kind, "workspace", "it followed to the selected workspace")
        keyRelease(Qt.Key_Space)
    }

    // Distinguishes: a peeked workspace treated as gone when it merely empties. An empty
    // workspace is still a target per the spec, and must peek as an empty mini-map — cancelling
    // here would make the common "close the last window" case flicker the layer away.
    function test_an_emptied_but_surviving_workspace_does_not_cancel() {
        var t = view.resolveTarget()             // already a workspace after open(); see above
        verify(t !== null && t.kind === "workspace")
        keyPress(Qt.Key_Space)
        compare(view.testPeek.shown, true)
        // Workspace 1 survives with no windows: still reported, still in boxes.
        view.compositor.workspaces = { values: [wsRow(1, []), wsRow(2, [client("0xC", "charlie", 100)])] }
        view.rebuild()
        compare(view.peekCancelled, false, "an empty workspace is still a target")
        compare(view.testPeek.shown, true)
        compare(view.testPeek.workspaceWindows.length, 0, "and the mini-map is empty")
        keyRelease(Qt.Key_Space)
    }

    // Distinguishes: a peeked workspace that leaves the model entirely. Unlike the test above,
    // workspace 1 is no longer reported at all, so it is not in boxes and the peek must cancel.
    function test_a_destroyed_workspace_cancels_the_hold() {
        keyPress(Qt.Key_Space)                   // the target is already the selected workspace
        compare(view.testPeek.peekTarget.kind, "workspace")
        var gone = view.testPeek.peekTarget.id
        view.compositor.workspaces = { values: [wsRow(2, [client("0xC", "charlie", 100)])] }
        view.compositor.focusedWorkspace = { id: 2 }
        view.rebuild()
        verify(view.boxForWs(gone) === null, "precondition: the workspace really left boxes")
        compare(view.peekCancelled, true)
        compare(view.testPeek.shown, false)
        keyRelease(Qt.Key_Space)
    }

    // Distinguishes: a menu opening on top of a peek, or a peek popping back when the menu goes.
    // Right-click never reaches the key handler, which is why the spec's original "neither can
    // open while Space is down" was false and this rule exists.
    function test_opening_a_menu_cancels_the_hold() {
        hoverTile("0xB")
        keyPress(Qt.Key_Space)
        compare(view.testPeek.shown, true)
        var p = tileCentre("0xB")
        mousePress(view, p.x, p.y, Qt.RightButton)
        mouseRelease(view, p.x, p.y, Qt.RightButton)
        wait(30)
        compare(view.menuOpen, true, "the menu opened")
        compare(view.testPeek.shown, false, "and the peek yielded")
        view.menuDismiss()
        compare(view.testPeek.shown, false, "dismissing the menu does not bring it back")
        keyRelease(Qt.Key_Space)
    }

    // Distinguishes: a peek left open when keyboard focus leaves mid-hold. The release event
    // never arrives at an unfocused surface, so without the force-clear the layer sticks open
    // forever — the bug the spec calls out explicitly. Asserted WITHOUT a release, which is the
    // whole point: a test that releases the key cannot tell the force-clear from the handler.
    function test_focus_loss_clears_a_held_peek() {
        hoverTile("0xB")
        keyPress(Qt.Key_Space)
        compare(view.testPeek.shown, true)
        view.testKeys.focus = false              // drop the key catcher's active focus
        wait(30)
        compare(view.peeking, false, "cleared without any release event")
        compare(view.peekCancelled, true, "and cancelled, so a still-held key cannot re-open it")
        keyRelease(Qt.Key_Space)
    }

    // Distinguishes: the scratchpad's NEGATIVE workspace id (Logic.SCRATCHPAD_ID is -2) breaking
    // the identity round-trip. peekKeyOf writes "s:-2" and the rebuild check parses it back with
    // parseInt — a key built by concatenation and read back by a naive split, or a check using
    // `id > 0`, fails here and nowhere else in this file.
    function test_the_scratchpad_row_peeks_like_any_workspace() {
        view.compositor.workspaces = { values: [
            wsRow(1, [client("0xA", "alpha", 100), client("0xB", "bravo", 900)]),
            wsRow(2, [client("0xC", "charlie", 100)]),
            scratchRow(-99, "0xS", "scratch")
        ] }
        view.rebuild()
        keyClick("s", Qt.ControlModifier)        // reveal the scratchpad row
        wait(30)
        // Walk to the scratchpad row with Tab, not an arrow: the scratchpad is a WORKSPACE (a
        // row of the mini-map's own boxes list, walked by cycleWorkspace), and since ec6083b
        // Tab is the key that steps workspace selection — arrows now step the window cursor
        // inside whichever workspace is already selected, which would never reach it.
        keyClick(Qt.Key_Tab); keyClick(Qt.Key_Tab); keyClick(Qt.Key_Tab)
        // Walk to the scratchpad row rather than assuming its index.
        var guard = 0
        while (view.selectedId !== -2 && guard++ < 8) keyClick(Qt.Key_Tab)
        compare(view.selectedId, -2, "precondition: the scratchpad row is selected")
        keyPress(Qt.Key_Space)
        compare(view.testPeek.shown, true)
        compare(view.testPeek.peekTarget.id, -2)
        compare(view.peekedKey, "s:-2", "the identity key round-trips a negative id")
        compare(view.peekCancelled, false, "and a rebuild must not read it as a vanished workspace")
        view.rebuild()
        compare(view.peekCancelled, false, "still not cancelled after a fresh rebuild")
        keyRelease(Qt.Key_Space)
    }

    // Distinguishes: a Space that both dismisses a menu and opens a peek from one press. The
    // menuDismissKey latch must swallow it, and the still-held key must stay inert.
    function test_space_dismissing_a_menu_does_not_peek() {
        var p = tileCentre("0xA")
        mousePress(view, p.x, p.y, Qt.RightButton); mouseRelease(view, p.x, p.y, Qt.RightButton)
        wait(30)
        compare(view.menuOpen, true)
        keyPress(Qt.Key_Space)
        compare(view.menuOpen, false, "Space dismissed the menu")
        compare(view.testPeek.shown, false, "and did not also open a peek")
        keyPress(Qt.Key_Space)
        compare(view.testPeek.shown, false, "the held key stays swallowed")
        keyRelease(Qt.Key_Space)
        keyPress(Qt.Key_Space)
        compare(view.testPeek.shown, true, "a fresh press after the release peeks")
        keyRelease(Qt.Key_Space)
    }

    // Distinguishes: opening the close-all confirmation cancelling a held peek — a separate call
    // site from openMenu()'s, and one nothing else in this file exercises. Calls
    // openCloseAllConfirm() directly (rather than walking a menu to "Close all") because the
    // dialog opening is the thing under test, not how a user would reach it — that path is
    // Actions::test_close_all_from_the_window_menu_opens_the_confirmation's job.
    function test_opening_the_close_all_confirm_cancels_the_hold() {
        var t = view.resolveTarget()
        verify(t !== null && t.kind === "workspace", "precondition: the target is a workspace")
        keyPress(Qt.Key_Space)
        compare(view.testPeek.shown, true)
        view.openCloseAllConfirm(t.id)
        compare(view.confirmOpen, true, "precondition: the dialog actually opened")
        compare(view.peekCancelled, true, "opening it cancels the hold")
        compare(view.testPeek.shown, false, "and the peek yielded")
        view.cancelCloseAllConfirm()
        compare(view.testPeek.shown, false, "dismissing the dialog does not bring it back")
        keyRelease(Qt.Key_Space)
    }

    // Distinguishes: peekedKey pinned to the target at PRESS time rather than following a
    // mid-hold retarget. Peeks window A (the arrow cursor's first stop), retargets onto B with a
    // second Right while still held, then closes B — the window the layer is ACTUALLY showing, not
    // the one it started on. Without onPeekTargetChanged keeping peekedKey in step with the
    // retarget, it would still read "w:A" here, wmap would still have an entry for A (A was never
    // touched), the model check would see nothing gone, and this would wrongly stay open — even
    // though what's on screen (B) just vanished. Right, not Tab: since ec6083b, Tab steps the
    // workspace selection and clears the cursor rather than moving it, so it can no longer
    // retarget the WINDOW cursor this test is pinning.
    function test_closing_the_retargeted_window_cancels_the_hold() {
        keyClick(Qt.Key_Right)
        var first = view.cursorAddress
        keyPress(Qt.Key_Space)
        compare(view.testPeek.peekTarget.address, first, "precondition: peeking the first window")
        keyClick(Qt.Key_Right)
        var second = view.cursorAddress
        verify(second !== first, "precondition: Right retargeted to a different window")
        compare(view.testPeek.peekTarget.address, second, "precondition: the peek followed to it")
        compare(view.peekedKey, "w:" + second, "precondition: peekedKey names the CURRENT target")
        // Close the retargeted window (second); the original (first) survives untouched.
        view.compositor.workspaces = { values: [
            wsRow(1, [client(first, "alpha", 100)]),
            wsRow(2, [client("0xC", "charlie", 100)])
        ] }
        view.rebuild()
        compare(view.peekCancelled, true, "closing the window the peek actually shows must cancel")
        compare(view.testPeek.shown, false)
        keyRelease(Qt.Key_Space)
    }

    // Distinguishes: peekAbort() latching the cancel with no hold in flight (review fix). A modal
    // that opens and closes without Space ever being pressed must not leave the NEXT press dead —
    // reproduced by a right-click that opens a menu, Escape to dismiss it, then holding Space
    // fresh. Before the fix, openMenu()'s peekAbort() call unconditionally set peekCancelled
    // regardless of whether a key was down to suppress, and only a real Space release — which
    // never happens in this sequence — clears it, so the very next, unrelated press was silently
    // swallowed until one stray press+release cycle happened to arm it.
    function test_a_menu_opened_and_dismissed_without_space_does_not_dead_the_next_press() {
        var p = tileCentre("0xA")
        mousePress(view, p.x, p.y, Qt.RightButton); mouseRelease(view, p.x, p.y, Qt.RightButton)
        wait(30)
        compare(view.menuOpen, true, "precondition: the menu opened")
        keyClick(Qt.Key_Escape)
        compare(view.menuOpen, false, "precondition: Escape dismissed it")
        compare(view.peekCancelled, false, "no Space was ever down: nothing should be latched")
        keyPress(Qt.Key_Space)
        compare(view.testPeek.shown, true, "a fresh hold must open, not be swallowed by a stale cancel")
        keyRelease(Qt.Key_Space)
    }

    // Distinguishes: a lost release during focus loss leaving the NEXT fresh press dead one level
    // down from test_a_menu_opened_and_dismissed_without_space_does_not_dead_the_next_press above.
    // Focus loss cancels the hold correctly (peekKeyDown=true, peekCancelled=true) — but the
    // physical release that would normally clear both never reaches an unfocused catcher, by
    // construction. If nothing clears them when focus RETURNS, they are still set the next time
    // the user reaches for Space, and that unrelated fresh press is swallowed exactly as it was
    // before peekKeyDown existed. No release is ever sent here — that omission is the whole point.
    function test_a_lost_release_during_focus_loss_does_not_dead_the_next_press() {
        hoverTile("0xB")
        keyPress(Qt.Key_Space)
        compare(view.testPeek.shown, true)
        view.testKeys.focus = false
        wait(30)
        compare(view.peekCancelled, true, "precondition: focus loss cancelled the hold")
        // No keyRelease(Qt.Key_Space) anywhere in this test: the release never arrives while
        // unfocused, and by the time focus below returns it is gone for good, not merely delayed.
        view.testKeys.focus = true
        wait(30)
        keyPress(Qt.Key_Space)
        compare(view.testPeek.shown, true, "a fresh press after focus returns must not be dead")
        keyRelease(Qt.Key_Space)
    }

    // Distinguishes: a stale peekKeyDown surviving a close()/open() cycle. close() aborts a held
    // peek whose release will also never arrive (the same "release never arrives" fact as the
    // test above, via a different door: the surface is torn down instead of merely unfocused), so
    // peekKeyDown is left true across the boundary unless open()'s peekReset() clears it too. Left
    // stale, a modal opened in the FRESH session — with no Space held at all this time — would
    // incorrectly read "a key is down" and latch a cancel nothing asked for, deadening the next
    // real press. Uses a right-click (not Space) after reopening specifically because Space is
    // what must stay untouched by the previous summon's leftovers.
    function test_a_stale_key_down_flag_across_a_summon_does_not_dead_the_next_press() {
        hoverTile("0xB")
        keyPress(Qt.Key_Space)
        compare(view.testPeek.shown, true)
        view.close()   // peekAbort() under a still-held key whose release will never arrive
        view.open(); wait(400)
        // No Space is held anywhere in this fresh session.
        var p = tileCentre("0xA")
        mousePress(view, p.x, p.y, Qt.RightButton); mouseRelease(view, p.x, p.y, Qt.RightButton)
        wait(30)
        compare(view.menuOpen, true, "precondition: the menu opened")
        view.menuDismiss()
        compare(view.peekCancelled, false, "no Space was ever down this session: nothing should be latched")
        keyPress(Qt.Key_Space)
        compare(view.testPeek.shown, true, "a fresh press must not be dead from a stale flag")
        keyRelease(Qt.Key_Space)
    }

    // Distinguishes: a peek that is undiscoverable. Space is not a key anyone guesses, and it is
    // the only gesture in the overview with no visible affordance at all.
    function test_the_hint_row_advertises_the_peek() {
        var found = false
        for (var i = 0; i < view.testHintModel.length; i++)
            if (String(view.testHintModel[i].k).toLowerCase().indexOf("space") >= 0) found = true
        verify(found, "the primary hint row must name the peek key")
    }
}
