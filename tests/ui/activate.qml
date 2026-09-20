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
    // Hyprland allocates the special workspace's id dynamically and it is NOT -2 — the layout
    // remaps it (buildInput, Overview.qml:425). Seeding a different number here, as
    // tests/ui/scratchpad.qml does, keeps every -2 assertion below a proof of the remap rather
    // than a coincidence.
    readonly property int scratchHyprId: -73

    Component { id: overview; Overview {} }

    function client(addr, cls, x) {
        return { address: addr, at: [x, 1500], size: [400, 400], floating: false,
                 title: cls, "class": cls, fullscreen: 0 }
    }
    function wsRow(id, clients, name) {
        return { id: id, name: name === undefined ? String(id) : name, monitor: mon,
                 toplevels: { values: clients.map(function (c) { return { lastIpcObject: c } }) } }
    }
    // Workspace 1: two tiled windows side by side. Workspace 2: one. Workspace 3: empty, so a
    // well click has a box with no tiles in it. Plus a scratchpad row holding one window, which
    // open() hides and Ctrl+S reveals — so it changes nothing for any test that does not ask for
    // it, and `test_a_the_seed_is_what_the_later_tests_assume` pins both halves of that.
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
            wsRow(3, []),
            // "syncthing" is deliberately free of every letter this suite ever types into the
            // query ("a", "b", "bravo"), so revealing the row can never change a match set and
            // the find tests keep meaning what they say.
            wsRow(scratchHyprId, [client("0xS", "syncthing", 900)], "special:scratchpad")
        ] }
    }
    // The compositor acknowledging a drop of 0xA onto workspace 3: the stub records dispatches
    // but never moves anything itself, so a test that needs the move to land must say so.
    function v3(v) {
        v.compositor.workspaces = { values: [
            wsRow(1, [client("0xB", "bravo", 900)]),
            wsRow(2, [client("0xC", "charlie", 100)]),
            wsRow(3, [client("0xA", "alpha", 100)])
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
        var b = boxOrNull(wsId)
        if (b === null) fail("no box for workspace " + wsId)
        return b
    }
    // The same lookup for tests that assert a box is ABSENT — boxOf's own failure is what makes
    // it useless for that.
    function boxOrNull(wsId) {
        for (var i = 0; i < view.boxes.length; i++)
            if (view.boxes[i].workspaceId === wsId) return view.boxes[i]
        return null
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

        // The scratchpad row, guarded in both directions. Hidden, or the two counts above are
        // wrong and every other test in this file shifts with them; and revealed by Ctrl+S into
        // a real -2 box with its tile in the model, or the scratchpad tests below would be
        // asserting over a layout that never grew one.
        compare(boxOrNull(-2), null, "the seeded scratchpad row stays hidden until Ctrl+S")
        compare(boxOrNull(scratchHyprId), null, "Hyprland's own special id never reaches the layout")
        ctrlS()
        verify(boxOrNull(-2) !== null, "Ctrl+S must reveal the seeded scratchpad row")
        compare(view.testModel.count, 4, "and bring 0xS into the layout with it")
    }

    // ---- select-mode targeting -------------------------------------------------------------
    function ctrlW() { keyClick(Qt.Key_W, Qt.ControlModifier) }
    function ctrlS() { keyClick(Qt.Key_S, Qt.ControlModifier) }

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

        // …and it must still be there once the compositor catches up, which is what makes
        // selecting the target box right rather than merely optimistic. The click's own press
        // drops the pending move (Overview.qml:1959, "a second grab supersedes"), so from here
        // the only thing holding the tile on workspace 3 is the compositor's own report — which
        // in a real session is exactly what the drop's dispatch produces.
        v3(view)                                  // Hyprland acknowledges: 0xA now lives on ws 3
        view.rebuild()
        compare(view.selectedId, 3)
        compare(view.cursorAddress, "0xA", "the ring survives the compositor catching up")
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
        // draggingAddress is set in onPressed, before any movement, so it proves nothing about
        // the drag having started. The drop target only resolves once the pointer is over box 3.
        compare(view.dropTargetWs, 3, "the drag must really have reached workspace 3")
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

    function type(s) { for (var i = 0; i < s.length; i++) keyClick(s.charAt(i)) }

    // Distinguishes: a select-mode Ctrl+W that diverges from enter mode's. main's lone-window
    // carve-out (closeTarget, ✎ 2026-09-18) closes a workspace's only window rather than making
    // you step into the tile first, and that reasoning does not weaken when the workspace was
    // reached by selecting rather than by hovering — it strengthens, since selecting a workspace
    // IS the primary gesture here. All three cases below are the carve-out's own boundary, read
    // through the select-mode target rule: one window closes, two stay inert rather than
    // escalating to close-all, none has nothing to name.
    function test_d_ctrl_w_on_a_selected_workspace_follows_the_lone_window_carve_out() {
        keyClick(Qt.Key_2)                       // workspace 2 holds exactly 0xC
        compare(view.selectedId, 2)
        compare(view.cursorAddress, "", "a digit clears the cursor, so the target is the workspace")
        ctrlW()
        compare(view.compositor.commands.length, 1, "the lone window closes")
        verify(view.compositor.commands[0].indexOf("0xC") >= 0,
               "closed " + view.compositor.commands[0])

        view.compositor.commands = []
        keyClick(Qt.Key_1)                       // workspace 1 holds 0xA and 0xB
        ctrlW()
        compare(view.compositor.commands.length, 0, "two windows: inert, never close-all")

        keyClick(Qt.Key_3)                       // workspace 3 is empty
        ctrlW()
        compare(view.compositor.commands.length, 0, "no window to name")
    }
    // Distinguishes: a click on a MATCH that sets the cursor instead of moving the match — the
    // ring would then say one thing and Enter another, and followMatch would undo it on the next
    // rebuild. "a" matches alpha and charlie; the click picks the one find did not select.
    function test_e_clicking_a_match_moves_the_selected_match() {
        type("a")
        verify(view.query.length > 0)
        var p = tileCentre("0xC")
        mouseClick(view, p.x, p.y)
        wait(30)
        compare(view.query, "a", "the query survives a click inside it")
        compare(view.selectedMatchAddress, "0xC")
        compare(view.cursorAddress, "", "the match branch must never set the cursor")

        view.rebuild()   // synchronous; the idiom every other UI suite uses
        compare(view.selectedMatchAddress, "0xC", "rematchAfterRebuild must preserve it")

        var t = view.resolveTarget()
        compare(t.kind, "window"); compare(t.address, "0xC", "Enter and Ctrl+W act on the click")
    }
    // Distinguishes: a click on a DIMMED tile being ignored (a visible tile left inert), or
    // selecting while the query stays live — where target() would keep returning the old match.
    function test_e_clicking_a_non_match_clears_the_query() {
        type("bravo")                             // matches 0xB only
        compare(view.selectedMatchAddress, "0xB")
        var p = tileCentre("0xC")                 // charlie: not a match
        mouseClick(view, p.x, p.y)
        wait(30)
        compare(view.query, "", "clicking outside the filter ends it")
        compare(view.cursorAddress, "0xC")
        compare(view.selectedId, 2)

        view.rebuild()   // synchronous; the idiom every other UI suite uses
        compare(view.cursorAddress, "0xC", "and survives the rebuild")
        var t = view.resolveTarget()
        compare(t.address, "0xC")
    }
    // Distinguishes: the query branch resolving the workspace through _windowByAddress instead
    // of displayedWorkspaceOf. test_d_a_click_on_a_just_dropped_tile_... pins the same rule on
    // the no-query path, and this branch is a SEPARATE code path that was regressed once and
    // restored — without this, that exact regression passes the suite.
    //
    // "b" matches bravo (0xB) and nothing else: alpha and charlie have no 'b'. One keystroke, so
    // the click lands well inside the 1.8 s optimistic-drop window opened by the drag above.
    function test_e_clicking_a_just_dropped_non_match_selects_the_box_it_landed_in() {
        var from = tileCentre("0xA"), to = wellCentre(3)
        mousePress(view, from.x, from.y, Qt.LeftButton)
        mouseMove(view, from.x + 12, from.y + 2, 20)
        mouseMove(view, to.x, to.y, 20)
        mouseRelease(view, to.x, to.y, Qt.LeftButton)
        wait(30)

        type("b")
        compare(view.selectedMatchAddress, "0xB", "0xA must NOT be a match here")

        var p = tileCentre("0xA")                 // dimmed, and mid-drop
        mouseClick(view, p.x, p.y)
        wait(30)
        compare(view.query, "", "a dimmed tile still ends the query")
        compare(view.cursorAddress, "0xA")
        compare(view.selectedId, 3, "the box the tile is drawn in, not the one it came from")
    }
    // Distinguishes: restorePreQuerySelection running AFTER the click's own selection and
    // stomping it — the ordering trap called out in the spec.
    function test_e_clicking_a_well_clears_the_query_then_selects() {
        type("bravo")
        var w = wellCentre(3)
        mouseClick(view, w.x, w.y)
        wait(30)
        compare(view.query, "")
        compare(view.selectedId, 3, "the click's own selection must outlive setQuery(\"\")")
        compare(view.cursorAddress, "")
    }
    // Distinguishes: a double-click inside a query that selects twice instead of committing.
    function test_e_double_clicking_a_match_enters_it() {
        type("a")
        var p = tileCentre("0xC")
        mouseDoubleClickSequence(view, p.x, p.y)
        wait(30)
        compare(view.opened, false)
        compare(view.compositor.commands.length, 1)
        verify(view.compositor.commands[0].indexOf("address:0xC") >= 0)
    }
    // Distinguishes: a hint row hard-coded to the enter-policy wording, which would tell a
    // select-mode user that a digit jumps. Reads the live model, so it also catches a row that
    // changed shape.
    function test_f_the_hint_row_follows_the_policy() {
        function labelFor(key) {
            var m = view.testHintModel
            for (var i = 0; i < m.length; i++) if (m[i].k === key) return m[i].l
            fail("no hint cap for " + key)
        }
        compare(labelFor("1–0"), "select")
        compare(labelFor("↵"), "enter")

        view.testConfig.activate = "enter"
        compare(labelFor("1–0"), "jump", "the default policy's wording")
        compare(labelFor("↵"), "select")
    }

    // ---- the four untested Behaviour rows, plus the promised Tab assertion (issue #33) ------
    // Everything below closes a row of the spec's Behaviour table that shipped with no Tier 2
    // test. The code was right in each case; what was missing was the guard.

    // ---- `Enter` commits ---------------------------------------------------------------------
    // The half of the feature's name that the suite never pressed. What was asserted before was
    // `resolveTarget()` naming the right thing — the INPUT to activateTarget(), not proof that
    // Enter acts on it. A handler that resolved correctly and then did nothing, or that jumped
    // somewhere else, passed.
    //
    // Distinguishes, in all three: an Enter that no longer reaches activateTarget (nothing
    // dispatches, the overview stays open), one that closes without dispatching, and one that
    // still consults the pointer — hence the hover onto a tile on a DIFFERENT workspace before
    // each press, which is the sharp half. Under "enter" that same hover WOULD be the target
    // (test_b asserts exactly that), so a policy leak cannot hide.
    function test_g_enter_enters_the_selected_workspace() {
        keyClick(Qt.Key_2)
        compare(view.selectedId, 2)
        hoverTile("0xA")                          // workspace 1, and pointerLive goes true
        compare(view.pointerLive, true, "the hover must be a REAL move, or this proves nothing")
        keyClick(Qt.Key_Return)
        compare(view.opened, false, "Enter commits the selection")
        compare(view.compositor.commands.length, 1)
        verify(view.compositor.commands[0].indexOf('workspace = "2"') >= 0,
               "dispatched: " + view.compositor.commands[0])
    }
    // The cursor half of the same rule: with a window selected, Enter focuses that window rather
    // than entering its workspace.
    function test_g_enter_enters_the_selected_window() {
        var p = tileCentre("0xC")
        mouseClick(view, p.x, p.y)                // select 0xC on workspace 2
        wait(30)
        compare(view.cursorAddress, "0xC")
        compare(view.compositor.commands.length, 0, "the click itself dispatches nothing")

        hoverTile("0xA")
        keyClick(Qt.Key_Return)
        compare(view.opened, false)
        compare(view.compositor.commands.length, 1)
        verify(view.compositor.commands[0].indexOf("address:0xC") >= 0,
               "dispatched: " + view.compositor.commands[0])
        verify(view.compositor.commands[0].indexOf('workspace = "2"') < 0,
               "a window selection must focus, not enter its workspace")
    }
    // The third branch of the target rule, and the assertion
    // test_e_clicking_a_match_moves_the_selected_match stops one step short of: it proves
    // resolveTarget() names the clicked match, this proves Enter acts on it.
    //
    // Distinguishes: an Enter that consults the cursor or the selected workspace while a query
    // is live — the precedence that makes the whole find × click rule necessary.
    //
    // The hover has to be placed deliberately here, unlike in the two tests above: mouseClick
    // leaves the pointer ON the clicked tile, so without a move afterwards a pointer-targeting
    // Enter would name 0xC too and pass by coincidence. 0xA is a match for this query as well
    // as being on another workspace, so the hover cannot be waved away as targeting something
    // find had already excluded.
    function test_g_enter_after_clicking_a_match_focuses_that_match() {
        type("a")
        var p = tileCentre("0xC")
        mouseClick(view, p.x, p.y)
        wait(30)
        compare(view.selectedMatchAddress, "0xC")

        hoverTile("0xA")
        compare(view.pointerLive, true, "the hover must be a REAL move, or this proves nothing")
        compare(view.selectedMatchAddress, "0xC", "a mouse move never moves the match")
        keyClick(Qt.Key_Return)
        compare(view.opened, false)
        compare(view.compositor.commands.length, 1)
        verify(view.compositor.commands[0].indexOf("address:0xC") >= 0,
               "dispatched: " + view.compositor.commands[0])
    }

    // ---- a click moves the find selection, it does not merely look as though it did ----------
    // The spec's own Tier 2 plan promised this one and it never landed. `selectedMatchAddress`
    // alone cannot tell a click that moved `matchIndex` from one that repainted the ring: the
    // cheapest proof is to keep cycling and watch the SAME set come round.
    //
    // Distinguishes: a click that rebuilt `matches` from the clicked tile (Tab would then have
    // one entry to cycle, or a different set), and one that left matchIndex where find had put
    // it (the first Tab would step off 0xA, not off the clicked 0xC).
    //
    // "a" is a subsequence of all three class names; the ranking is alpha, bravo, charlie —
    // 'a' at a word start in "alpha" outscores the mid-word 'a' in the other two, and "bravo"
    // outscores the longer "charlie" on the length penalty.
    function test_g_tab_still_cycles_the_same_match_set_after_a_click() {
        type("a")
        compare(view.matches.length, 3, "alpha, bravo and charlie all match 'a'")
        compare(view.selectedMatchAddress, "0xA", "find's own pick, the best-ranked match")

        var p = tileCentre("0xC")
        mouseClick(view, p.x, p.y)
        wait(30)
        compare(view.selectedMatchAddress, "0xC")

        keyClick(Qt.Key_Tab)
        compare(view.query, "a", "Tab inside a query cycles matches; it never steps workspaces")
        compare(view.matches.length, 3, "the same set, untouched by the click")
        compare(view.selectedMatchAddress, "0xA", "one step on from the CLICKED match, wrapping")
        keyClick(Qt.Key_Tab)
        compare(view.selectedMatchAddress, "0xB")
    }

    // ---- a double-click inside a live query, on the two branches that clear it ---------------
    // Only the match branch was covered. The spec promises all three compose the same way — "a
    // click plus an enter of what that click selected" — and these two are where the query is
    // CLEARED first, which is a different code path (selectMatchOrClearQuery's tail, and
    // selectWorkspaceBox) reached twice in quick succession.
    //
    // Distinguishes, in both: a second step that re-resolves instead of entering what the first
    // step selected — it would enter the match the query had named rather than what was clicked
    // — and a double-click that dispatches twice, since Qt delivers `released` around
    // `doubleClicked` and both paths run.
    //
    // The `query` compare is load-bearing and not decoration. By the time `doubleClicked`
    // arrives the first click has already cleared the filter, so every assertion about the
    // DISPATCH is satisfied by a double-click that entered the right thing without the clearing
    // step ever having run — verified by mutation: make a click inside a live query inert
    // (`selectTile`'s query branch returning early, or `selectWorkspaceBox` keeping the query)
    // and the count, the address and `opened` all still pass. Only the surviving query fails,
    // which is what makes these tests of the COMPOSITION rather than of the second click alone.
    // close() does not reset find — open() does — so the query is still readable afterwards.
    function test_g_double_clicking_a_non_match_clears_the_query_then_enters_it() {
        type("bravo")                             // matches 0xB only; 0xA and 0xC have no 'b'
        compare(view.selectedMatchAddress, "0xB")
        var p = tileCentre("0xC")                 // charlie: dimmed
        mouseDoubleClickSequence(view, p.x, p.y)
        wait(30)
        compare(view.query, "", "the click half must still have ended the filter")
        compare(view.opened, false)
        compare(view.compositor.commands.length, 1, "exactly one focus dispatch")
        verify(view.compositor.commands[0].indexOf("address:0xC") >= 0,
               "entered " + view.compositor.commands[0] + ", expected the clicked 0xC")
        verify(view.compositor.commands[0].indexOf("address:0xB") < 0,
               "never the match the query had named")
    }
    function test_g_double_clicking_a_well_inside_a_query_enters_the_workspace() {
        type("bravo")
        compare(view.selectedMatchAddress, "0xB")
        var w = wellCentre(3)                     // workspace 3 is empty, and holds no match
        mouseDoubleClickSequence(view, w.x, w.y)
        wait(30)
        compare(view.query, "", "the click half must still have ended the filter")
        compare(view.opened, false)
        compare(view.compositor.commands.length, 1)
        verify(view.compositor.commands[0].indexOf('workspace = "3"') >= 0,
               "entered " + view.compositor.commands[0] + ", expected workspace 3")
        verify(view.compositor.commands[0].indexOf("address:0xB") < 0,
               "a well enters its workspace, never the query's match")
    }

    // ---- middle-click is direct manipulation, in both policies -------------------------------
    // The spec's Decisions bullet is explicit that middle-click and right-click never resolve a
    // target and are identical under both policies. No middle button appeared in this suite at
    // all, so that claim rested entirely on the Close suite — which only ever runs under
    // "enter". (Right-click has a witness here already:
    // test_c_a_key_swallowed_by_the_menu_still_clears_the_latch opens the menu with one.)
    //
    // Distinguishes: a middle click made select-aware — routed through closeTarget, it would
    // close 0xC via the lone-window carve-out on the SELECTED workspace 2 while the pointer sat
    // on 0xA. The two addresses can never coincide, so either half of that mistake shows.
    function test_g_middle_click_closes_the_pointed_window_not_the_selection() {
        keyClick(Qt.Key_2)                        // select workspace 2, whose lone window is 0xC
        compare(view.selectedId, 2)
        compare(view.cursorAddress, "", "a digit clears the cursor: the target is the workspace")

        var p = tileCentre("0xA")
        mouseClick(view, p.x, p.y, Qt.MiddleButton)
        wait(30)
        compare(view.opened, true, "a middle click never leaves the overview")
        compare(view.compositor.commands.length, 1)
        verify(view.compositor.commands[0].indexOf("window.close") >= 0,
               "dispatched: " + view.compositor.commands[0])
        verify(view.compositor.commands[0].indexOf("address:0xA") >= 0,
               "closed " + view.compositor.commands[0] + ", expected the pointed 0xA")
        verify(view.compositor.commands[0].indexOf("address:0xC") < 0,
               "never the selection's lone window")
        compare(view.selectedId, 2, "and the selection is not moved by a middle click")
    }

    // ---- the scratchpad row is an ordinary box -----------------------------------------------
    // The spec says the scratchpad follows the same rules "because it IS one" — a box in
    // `boxes` with `workspaceId: -2`. Nothing in this suite mentioned it, so that reasoning was
    // untested, and the negative id is exactly where a selection path can go wrong: it reaches
    // the layout through `indexOfWorkspace(boxes, -2)` and leaves it through `jump(-2)`, which
    // must take Logic.isScratchpad's branch rather than dispatching a workspace Hyprland has
    // never heard of. `digitActivate` is NOT part of this: it maps the ten digit keys onto ids
    // 1–10 and can never name -2, so the row is reached by click or by Tab, like any other box
    // without a digit of its own.
    //
    // Distinguishes: a click path that resolves the box by anything but the row's own id, and
    // one that special-cases the scratchpad into the enter-policy jump. The rebuild is the same
    // applyTiles trap test_d_a_tile_click_selects_and_survives_a_rebuild pins on workspace 2 —
    // a cursor whose box selection did not follow it is dropped at the next rebuild.
    function test_g_the_scratchpad_tile_selects_like_any_other_box() {
        ctrlS()
        verify(boxOrNull(-2) !== null, "the scratchpad row must be in the layout")
        var p = tileCentre("0xS")
        mouseClick(view, p.x, p.y)
        wait(30)
        compare(view.opened, true, "a single click must not leave")
        compare(view.compositor.commands.length, 0, "nothing dispatched on a select")
        compare(view.cursorAddress, "0xS")
        compare(view.selectedId, -2, "the box selection follows the tile, negative id and all")

        view.rebuild()
        compare(view.cursorAddress, "0xS", "the cursor must survive applyTiles")
        compare(view.selectedId, -2)
    }
    // Distinguishes: a double-click on a scratchpad tile that selects twice instead of
    // committing, and one that dispatches the bare focus rather than the guarded scratchpad
    // chunk — a scratchpad window focused without being raised stays behind whatever is on top
    // of it (focusWindow, Overview.qml:757).
    function test_g_a_double_click_on_the_scratchpad_tile_enters_it() {
        ctrlS()
        var p = tileCentre("0xS")
        mouseDoubleClickSequence(view, p.x, p.y)
        wait(30)
        compare(view.opened, false)
        compare(view.compositor.commands.length, 1, "exactly one dispatch")
        var cmd = view.compositor.commands[0]
        verify(cmd.indexOf("address:0xS") >= 0, "dispatched: " + cmd)
        verify(cmd.indexOf("alter_zorder") >= 0, "the scratchpad chunk, which also raises it")
    }
    // The workspace half, and the one place `jump(-2)` is reached under this policy. Tab is how
    // the row is selected without a cursor: it has no digit, and its only tile would set one.
    //
    // Distinguishes: an Enter that dispatches a numeric workspace focus for -2 — a workspace
    // Hyprland does not have, so nothing would happen and the overview would close anyway,
    // which is why the negative assertion is here rather than left to the command count.
    function test_g_enter_on_the_selected_scratchpad_row_shows_the_scratchpad() {
        ctrlS()
        keyClick(Qt.Key_Backtab)                  // back from ws 1 wraps to the scratchpad, last
        compare(view.selectedId, -2)
        compare(view.cursorAddress, "", "Tab clears the cursor: the target is the row itself")

        keyClick(Qt.Key_Return)
        compare(view.opened, false)
        compare(view.compositor.commands.length, 1)
        var cmd = view.compositor.commands[0]
        verify(cmd.indexOf('workspace.toggle_special("scratchpad")') >= 0, "show chunk, got: " + cmd)
        verify(cmd.indexOf("get_active_special_workspace") >= 0, "guarded against hiding one already up")
        verify(cmd.indexOf('workspace = "-2"') < 0, "never a numeric jump to the remapped id")
    }
}
