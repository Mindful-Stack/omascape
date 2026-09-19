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
    // the STUB declares the name — that production reads the same name is proved by
    // test_b_hover_does_not_retarget_in_select_mode, not here.
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

    // ---- select-mode targeting -------------------------------------------------------------
    function ctrlW() { keyClick(Qt.Key_W, Qt.ControlModifier) }

    // This is the behavioural proof `test_a_the_fixture_carries_the_activate_policy` defers to:
    // flipping the policy flips the answer, which only production actually reading the key can
    // produce.
    //
    // Distinguishes: a resolveTarget that still passes pointerLive through in select mode, AND
    // one that switched the pointer off for both policies — the same hover is resolved under
    // each, so either mistake fails one half. The hover is a REAL move (pointerLive goes true):
    // the point is that liveness no longer reaches the resolver, not that the pointer stopped.
    //
    // What it does NOT distinguish, verified by mutation: resolveTarget holds two independent
    // guards — the local `selectMode` short-circuit around the hit test, and the `selectMode`
    // argument handed to Logic.target — and EITHER ALONE satisfies this test. Removing both
    // fails it. So this pins that the policy reaches the resolver, not which guard carried it;
    // the pure-layer half is pinned separately by tst_actions.qml's selectMode cases.
    //
    // The selection is the one open() makes, the focused workspace. Deliberately not set with a
    // digit: digits do not select until the policy reaches the key handler in the next task, and
    // before that a digit jumps and closes the overview out from under the test.
    function test_b_hover_does_not_retarget_in_select_mode() {
        compare(view.selectedId, 1, "open() selects the focused workspace")
        hoverTile("0xC")                         // a window on a DIFFERENT workspace
        compare(view.pointerLive, true, "the pointer really did move")

        var t = view.resolveTarget()
        compare(t.kind, "workspace")
        compare(t.id, 1, "select mode: the selection, not the hovered tile")

        view.testConfig.activate = "enter"
        var e = view.resolveTarget()
        compare(e.kind, "window")
        compare(e.address, "0xC", "enter mode: the same hover still names the tile")
    }

    // ---- select-mode digits: Logic.digitActivate wired through the latch -------------------
    // Distinguishes: a digit that still jumps (the overview would close and dispatch), or one
    // that selects without moving the box selection.
    function test_c_a_digit_selects_without_leaving() {
        keyClick(Qt.Key_2)
        compare(view.opened, true, "a first press must not leave the overview")
        compare(view.selectedId, 2)
        compare(view.compositor.commands.length, 0, "nothing dispatched on a select")
    }
    // Distinguishes: a latch keyed on the workspace instead of the key press, and a second press
    // that re-selects instead of committing.
    function test_c_the_same_digit_again_enters() {
        keyClick(Qt.Key_2)
        keyClick(Qt.Key_2)
        compare(view.opened, false)
        compare(view.compositor.commands.length, 1)
        verify(view.compositor.commands[0].indexOf('workspace = "2"') >= 0,
               "dispatched: " + view.compositor.commands[0])
    }
    // Distinguishes: a latch that ignores intervening input — the bug where 2, 3, 2 enters 2.
    function test_c_a_different_digit_clears_the_latch() {
        keyClick(Qt.Key_2); keyClick(Qt.Key_3); keyClick(Qt.Key_2)
        compare(view.opened, true, "no press was ever a repeat")
        compare(view.selectedId, 2)
    }
    // Distinguishes: a latch cleared only by digits. Tab moves the selection, so a later repeat
    // of the old digit must not complete.
    function test_c_another_key_clears_the_latch() {
        keyClick(Qt.Key_2); keyClick(Qt.Key_Tab); keyClick(Qt.Key_2)
        compare(view.opened, true)
    }
    // Distinguishes: a latch cleared by pointer movement. Under select mode a mouse move changes
    // nothing at all, so it must not silently break a pending repeat.
    function test_c_a_mouse_move_does_not_clear_the_latch() {
        keyClick(Qt.Key_2)
        hoverTile("0xA")
        compare(view.pointerLive, true, "the hover must be a REAL move, or this proves nothing")
        keyClick(Qt.Key_2)
        compare(view.opened, false, "the repeat must still complete after a mouse move")
    }
    // Distinguishes: THE missing-box gap. Workspace 7 has no box (see the seed), so neither
    // press may select, dispatch or leave — and the inert digit must also clear a pending latch,
    // or 2, 7, 2 would enter workspace 2 with a keystroke in between that did not count.
    function test_c_a_digit_with_no_box_is_inert() {
        keyClick(Qt.Key_7)
        compare(view.opened, true)
        compare(view.selectedId, 1, "selection untouched (workspace 1 is focused at open)")
        compare(view.compositor.commands.length, 0)

        keyClick(Qt.Key_7)
        compare(view.opened, true, "a second inert press must not enter either")
        compare(view.compositor.commands.length, 0)

        keyClick(Qt.Key_2); keyClick(Qt.Key_7); keyClick(Qt.Key_2)
        compare(view.opened, true, "the inert digit must have cleared the latch")
    }
    // Auto-repeat has NO test here on purpose: QtTest's QML key API cannot set isAutoRepeat
    // (tests/ui/actions.qml:431 says so for the Ctrl+W guard). That is why the rule lives in
    // digitActivate, where test_digitActivate_an_auto_repeat_is_a_true_no_op covers both
    // failure modes. Holding a digit is a live-check item, not an offscreen one.

    // Distinguishes: a latch that outlives the summon it was armed in, which would make the
    // first digit press of the NEXT open enter instead of select. Asserted BEHAVIOURALLY, by
    // reopening and pressing the same digit: `digitActivate` already returns latch 0 on enter,
    // so a state-only check would stay green even with open()'s reset deleted.
    function test_c_entering_leaves_no_latch_behind() {
        keyClick(Qt.Key_2); keyClick(Qt.Key_2)
        compare(view.opened, false)

        view.open()
        wait(400)
        view.compositor.commands = []    // after the open: it dispatches lock chunks of its own
        keyClick(Qt.Key_2)
        compare(view.opened, true, "the first digit of a new summon selects; it never completes")
        compare(view.compositor.commands.length, 0, "and dispatches nothing")
    }
    // Distinguishes: a latch taken AFTER the dialog/menu/dismiss-key branches, each of which
    // returns early. A key swallowed by the menu would then leave the latch armed — and a menu
    // action can close or move a window first — so `2`, a menu-swallowed key, `2` would enter a
    // workspace after two presses that never showed a selection between them.
    function test_c_a_key_swallowed_by_the_menu_still_clears_the_latch() {
        keyClick(Qt.Key_2)
        compare(view.digitLatch, Qt.Key_2, "armed")

        var p = tileCentre("0xA")
        mousePress(view, p.x, p.y, Qt.RightButton)
        mouseRelease(view, p.x, p.y, Qt.RightButton)
        wait(30)
        compare(view.menuOpen, true, "the menu must really be open, or this proves nothing")

        keyClick(Qt.Key_Escape)                  // dismisses the menu; never reaches the branches
        wait(30)
        compare(view.menuOpen, false)
        compare(view.digitLatch, 0, "a swallowed key must still have cleared the latch")
    }
    // Distinguishes: a policy flip that leaves a stale latch, so the first digit after switching
    // back completes a gesture begun under the old policy.
    function test_c_a_policy_change_clears_the_latch() {
        keyClick(Qt.Key_2)
        compare(view.digitLatch, Qt.Key_2)
        view.testConfig.activate = "enter"
        view.testConfig.activate = "select"
        compare(view.digitLatch, 0)
        keyClick(Qt.Key_2)
        compare(view.opened, true, "that press selects; it does not complete the old gesture")
    }
    // Distinguishes: the default policy regressing. Under "enter" a single digit still jumps.
    function test_c_enter_policy_is_unchanged() {
        view.testConfig.activate = "enter"
        keyClick(Qt.Key_2)
        compare(view.opened, false, "one press jumps under the default policy")
        compare(view.compositor.commands.length, 1)
    }
    // Distinguishes: the missing-box rule leaking into enter mode. Under "enter", 7 must still
    // dispatch and let Hyprland create workspace 7 — that is today's behaviour and it is not in
    // this feature's scope to change.
    function test_c_enter_policy_still_jumps_to_a_missing_workspace() {
        view.testConfig.activate = "enter"
        keyClick(Qt.Key_7)
        compare(view.opened, false)
        compare(view.compositor.commands.length, 1)
        verify(view.compositor.commands[0].indexOf('workspace = "7"') >= 0)
    }

    // Distinguishes: a click that still focuses and closes, and one that sets only the cursor
    // without the workspace — the `selectedId` compare kills that one outright, before the
    // rebuild. The rebuild half is a regression guard rather than the primary assertion: it
    // pins the consequence (applyTiles wiping a cursor that is not on selectedId) so a future
    // change that reintroduces the cursor-only click fails on the symptom as well as the cause.
    function test_d_a_tile_click_selects_and_survives_a_rebuild() {
        var p = tileCentre("0xC")                 // workspace 2
        mouseClick(view, p.x, p.y)
        wait(30)
        compare(view.opened, true, "a single click must not leave")
        compare(view.compositor.commands.length, 0)
        compare(view.cursorAddress, "0xC")
        compare(view.selectedId, 2, "the click must move the box selection too")

        view.rebuild()   // synchronous; the idiom every other UI suite uses
        compare(view.cursorAddress, "0xC", "the cursor must survive applyTiles")
        compare(view.selectedId, 2)
    }
    // Distinguishes: a double-click that focuses twice, or that leaves the overview open. The
    // command count is the sharp half: Qt delivers `released` around `doubleClicked` and both
    // paths run, so exactly one dispatch proves the guards hold.
    function test_d_a_double_click_enters_the_window() {
        var p = tileCentre("0xC")
        mouseDoubleClickSequence(view, p.x, p.y)
        wait(30)
        compare(view.opened, false)
        compare(view.compositor.commands.length, 1, "exactly one focus dispatch")
        verify(view.compositor.commands[0].indexOf("address:0xC") >= 0)
    }
    // Distinguishes: a well click that jumps (enter-mode behaviour) or that leaves a stale
    // window cursor behind, which would make Enter focus a window instead of entering the box.
    function test_d_a_well_click_selects_the_workspace() {
        var p = tileCentre("0xA")
        mouseClick(view, p.x, p.y)                // cursor onto a window first
        wait(30)
        var w = wellCentre(3)                     // workspace 3 is empty
        mouseClick(view, w.x, w.y)
        wait(30)
        compare(view.opened, true)
        compare(view.selectedId, 3)
        compare(view.cursorAddress, "", "a well click clears the window cursor")
    }
    // Distinguishes: a well double-click that selects twice instead of committing.
    function test_d_a_well_double_click_enters_the_workspace() {
        var w = wellCentre(3)
        mouseDoubleClickSequence(view, w.x, w.y)
        wait(30)
        compare(view.opened, false)
        compare(view.compositor.commands.length, 1)
        verify(view.compositor.commands[0].indexOf('workspace = "3"') >= 0)
    }
    // Distinguishes: a click clearing the latch only for digits. A click makes a NEW selection,
    // so a pending repeat of the old digit must not complete afterwards.
    function test_d_a_click_clears_the_digit_latch() {
        keyClick(Qt.Key_2)
        var p = tileCentre("0xA")
        mouseClick(view, p.x, p.y)
        wait(30)
        keyClick(Qt.Key_2)
        compare(view.opened, true, "the click must have cleared the latch")
    }
    // Distinguishes: a drag that also counts as a click and so selects on drop.
    // Distinguishes: a click that resolves the tile's workspace through `_windowByAddress`, which
    // for the ~1.8 s of an optimistic drop still reports the SOURCE workspace while the tile is
    // already drawn in the target (submitDrop notes the disagreement at Overview.qml:966). The
    // click would then select a box the tile is not in, and the next rebuild would clear the ring.
    function test_d_a_click_on_a_just_dropped_tile_selects_the_box_it_landed_in() {
        var from = tileCentre("0xA"), to = wellCentre(3)
        mousePress(view, from.x, from.y, Qt.LeftButton)
        mouseMove(view, from.x + 12, from.y + 2, 20)
        mouseMove(view, to.x, to.y, 20)
        mouseRelease(view, to.x, to.y, Qt.LeftButton)
        wait(30)

        // The optimistic row now says workspace 3; the compositor stub still reports 1.
        var p = tileCentre("0xA")
        mouseClick(view, p.x, p.y)
        wait(30)
        compare(view.cursorAddress, "0xA")
        compare(view.selectedId, 3, "the box the tile is drawn in, not the one it came from")
    }
    // A drag needs TWO moves, as tests/ui/drag.qml:57 does it: a short one to cross Qt's
    // startDragDistance and arm `drag.active`, then the real one. A single jump leaves `moved`
    // false, the release is a click, and the test would "fail" on production code that is
    // perfectly correct — which is exactly what it did before this was fixed.
    function test_d_a_moved_drag_does_not_select() {
        var from = tileCentre("0xA"), to = wellCentre(3)
        mousePress(view, from.x, from.y, Qt.LeftButton)
        mouseMove(view, from.x + 12, from.y + 2, 20)
        mouseMove(view, to.x, to.y, 20)
        verify(view.draggingAddress === "0xA", "the drag must really have started")
        mouseRelease(view, to.x, to.y, Qt.LeftButton)
        wait(30)
        compare(view.cursorAddress, "", "a moved drag is not a click")
    }
    // Distinguishes: the default policy regressing. Under "enter" a single click still focuses.
    function test_d_enter_policy_click_still_focuses() {
        view.testConfig.activate = "enter"
        var p = tileCentre("0xC")
        mouseClick(view, p.x, p.y)
        wait(30)
        compare(view.opened, false)
        compare(view.compositor.commands.length, 1)
    }

    // Distinguishes: Ctrl+W still acting on hover in select mode — the consequence the spec
    // accepted explicitly. Hovering 0xA while 0xC is selected must close 0xC.
    function test_d_ctrl_w_closes_the_selected_window_not_the_hovered_one() {
        var p = tileCentre("0xC")
        mouseClick(view, p.x, p.y)               // select 0xC (workspace 2)
        wait(30)
        view.compositor.commands = []
        hoverTile("0xA")
        ctrlW()
        compare(view.compositor.commands.length, 1)
        verify(view.compositor.commands[0].indexOf("0xC") >= 0,
               "closed " + view.compositor.commands[0] + ", expected the selected 0xC")
        verify(view.compositor.commands[0].indexOf("0xA") < 0)
    }
}
