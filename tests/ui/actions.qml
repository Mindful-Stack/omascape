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
    // A floating scratchpad window (real scratchpad contents are floating, per
    // tests/ui/scratchpad.qml) on Hyprland's own special-workspace id, named so buildInput()
    // remaps it onto Logic.SCRATCHPAD_ID.
    function scratchRow(hyprId, addr, cls) {
        return { id: hyprId, name: "special:scratchpad", monitor: mon,
                 toplevels: { values: [{ lastIpcObject: { address: addr, at: [900, 1500], size: [400, 400],
                                                           floating: true, title: cls, "class": cls,
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
    function init() {
        // Compensates for a gap between this fixture and the real (kept-loaded) shell: every test
        // gets a BRAND NEW Overview instance (createTemporaryObject), so pointerSceneX/Y start at
        // their (0, 0) declared default rather than carrying over the real scene position the way
        // a single kept-loaded instance would across a close/reopen. QtQuickTest also runs this
        // file's functions in ALPHABETICAL order, not declaration order, so a test earlier in that
        // order that ends with the real synthetic cursor resting over a tile (e.g.
        // test_a_lone_modifier_press_changes_nothing) leaves it there on the one real QQuickWindow
        // this whole file shares. The next test's fresh instance then sees its very first
        // onPointChanged report a position that differs from ITS OWN (0, 0) default — even though
        // the real pointer never moved during that test — and notePointerMove reads that as motion.
        // open()'s own `pointerLive = false` (production fix for the same-instance case) cannot
        // help here: it runs before that first onPointChanged arrives. Parking the real cursor off
        // any tile before each test is what actually breaks the chain; it changes nothing the
        // suite asserts about liveness, only which stray motion is allowed to count.
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
    // Distinguishes: a tileCandidates() scale expansion that is wrong (a flipped sign, a missing
    // division by 2) but invisible to every test that only ever hits a tile's dead centre — a
    // mistake like that is invariant under any origin-centred scaling and would still hit-test
    // correctly there. This point sits inside the painted 1.03-scaled rect (the hover lift's own
    // halo) but strictly outside the tile's unscaled model geometry, so only a correct expansion
    // resolves it to the tile.
    function test_tile_candidates_hit_the_scaled_edge_not_the_unscaled_one() {
        hoverTile("0xA")   // hovering 0xA also scales IT (WindowTile's own HoverHandler, `hh`)
        var row = null
        for (var i = 0; i < view.testModel.count; i++) {
            var r = view.testModel.get(i)
            if (r.address === "0xA") { row = r; break }
        }
        verify(row !== null, "no model row for 0xA")
        var cands = view.tileCandidates(), c = null
        for (var j = 0; j < cands.length; j++) if (cands[j].address === "0xA") { c = cands[j]; break }
        verify(c !== null, "no candidate for 0xA")
        verify(c.x < row.wx, "a hovered tile's candidate must be expanded left of its model geometry")
        var px = (c.x + row.wx) / 2, py = row.wy + row.wh / 2   // strictly in the halo, left of the base edge
        var p = view.testCanvas.mapToItem(view, px, py)
        mouseMove(view, p.x, p.y)
        wait(30)
        var t = view.resolveTarget()
        compare(t.kind, "window"); compare(t.address, "0xA")
    }
    // Distinguishes: open() failing to drop a stale liveness from the PREVIOUS summon. On a real
    // desktop the overview is kept loaded between summons, and SUPER+P is a compositor keybind it
    // never sees as a key event — closing with the pointer resting on a tile and reopening with
    // the keyboard, mouse untouched, must hand the target to the keyboard, not replay the old
    // hover. Reuses the SAME `view` across close/open (unlike every other test's fresh instance
    // per test), to match that kept-loaded scenario exactly.
    function test_reopening_drops_a_stale_pointer_liveness() {
        hoverTile("0xA")
        compare(view.pointerLive, true)
        view.close()
        view.open()
        wait(400)
        compare(view.pointerLive, false, "a keyboard re-summon must not inherit the old hover")
        var t = view.resolveTarget()
        compare(t.kind, "workspace"); compare(t.id, 1)
    }

    // ---- key classes ---------------------------------------------------------------------
    // Distinguishes: a navigation key that fails to clear liveness — the parked-mouse bug. After
    // an arrow the pointer must no longer decide, even though it never moved.
    function test_a_navigation_key_clears_pointer_liveness() {
        hoverTile("0xA")
        keyClick(Qt.Key_Right)
        compare(view.pointerLive, false)
    }
    // Distinguishes: THE regression the spec's key classes exist to prevent — for EVERY key
    // isModifierKey claims, not just Ctrl. A lone modifier press must never clear liveness, or
    // hover + Ctrl+W could never act on the hovered tile. Covering only Ctrl once let a wrong
    // numeric constant ship (Qt.Key_AltGr was mislabelled onto Qt.Key_CapsLock's code): each of
    // these presses the exact key the predicate names and would have caught that key falling
    // through to the "clears liveness" path instead.
    function test_a_lone_modifier_press_changes_nothing() {
        var mods = [
            { key: Qt.Key_Shift, name: "Shift" },
            { key: Qt.Key_Control, name: "Control" },
            { key: Qt.Key_Alt, name: "Alt" },
            { key: Qt.Key_Meta, name: "Meta" },
            { key: Qt.Key_CapsLock, name: "CapsLock" },
            { key: Qt.Key_AltGr, name: "AltGr" }
        ]
        for (var i = 0; i < mods.length; i++) {
            hoverTile("0xA")
            keyPress(mods[i].key)
            compare(view.pointerLive, true, mods[i].name + " alone is neither navigation nor an action")
            keyRelease(mods[i].key)
            compare(view.pointerLive, true, mods[i].name + " release must not clear liveness either")
        }
    }
    // Distinguishes: a printable key that leaves liveness set, which would make a hovered tile
    // outrank the find match the user just typed.
    function test_typing_clears_pointer_liveness() {
        hoverTile("0xA")
        keyClick("a")
        compare(view.pointerLive, false)
        compare(view.query, "a")
    }

    // ---- the Tab window cursor ------------------------------------------------------------
    function ringed() {
        var out = []
        for (var i = 0; i < view.testModel.count; i++) {
            var r = view.testModel.get(i)
            if (r.cursor) out.push(r.address)
        }
        return out
    }

    // Distinguishes: a cursor that follows model order rather than reading order. 0xA is the
    // left-hand window; a model-order implementation would also answer 0xA here, so the second
    // Tab is what discriminates — it must reach 0xB, the window to its right.
    function test_tab_walks_the_selected_workspace_in_reading_order() {
        compare(view.cursorAddress, "")
        keyClick(Qt.Key_Tab)
        compare(view.cursorAddress, "0xA")
        compare(ringed(), ["0xA"], "exactly one tile carries the ring")
        keyClick(Qt.Key_Tab)
        compare(view.cursorAddress, "0xB")
        keyClick(Qt.Key_Tab)
        compare(view.cursorAddress, "0xA", "wraps")
    }
    // Distinguishes: Shift+Tab treated as Tab. From nothing it must take the LAST window.
    function test_shift_tab_walks_backwards() {
        keyClick(Qt.Key_Backtab)
        compare(view.cursorAddress, "0xB")
        keyClick(Qt.Key_Backtab)
        compare(view.cursorAddress, "0xA")
    }
    // Distinguishes: a cursor that survives navigation, which would leave a ring on a workspace
    // the user has navigated away from and make Enter focus a window they cannot see.
    function test_an_arrow_clears_the_cursor() {
        keyClick(Qt.Key_Tab)
        compare(view.cursorAddress, "0xA")
        keyClick(Qt.Key_Right)
        compare(view.cursorAddress, "")
        compare(ringed(), [])
    }
    // Distinguishes: Esc collapsing two levels at once. The first Esc must consume only the
    // cursor and leave the overview open.
    function test_escape_unwinds_the_cursor_before_closing() {
        keyClick(Qt.Key_Tab)
        keyClick(Qt.Key_Escape)
        compare(view.cursorAddress, "")
        compare(view.opened, true, "the first Escape spends itself on the cursor")
        keyClick(Qt.Key_Escape)
        compare(view.opened, false)
    }
    // Distinguishes: Enter jumping to the workspace instead of focusing the cursor's window.
    function test_enter_focuses_the_cursor_window() {
        keyClick(Qt.Key_Tab)
        keyClick(Qt.Key_Return)
        compare(view.opened, false)
        compare(view.compositor.commands.length, 1)
        verify(view.compositor.commands[0].indexOf('address:0xA') >= 0)
        verify(view.compositor.commands[0].indexOf('focus') >= 0)
    }
    // Distinguishes: Enter ignoring a live pointer — the target rule must apply to Enter too, so
    // a hovered tile beats the cursor.
    function test_enter_prefers_a_hovered_tile_over_the_cursor() {
        keyClick(Qt.Key_Tab)
        compare(view.cursorAddress, "0xA")
        hoverTile("0xB")
        keyClick(Qt.Key_Return)
        verify(view.compositor.commands[0].indexOf('address:0xB') >= 0)
    }
    // Distinguishes: a cursor kept alive after its window left the selected workspace, which
    // would leave Ctrl+W pointing at a window drawn somewhere else entirely.
    function test_the_cursor_clears_when_its_window_leaves_the_workspace() {
        keyClick(Qt.Key_Tab)
        compare(view.cursorAddress, "0xA")
        view.compositor.workspaces = { values: [
            wsRow(1, [client("0xB", "bravo", 900)]),
            wsRow(2, [client("0xC", "charlie", 100), client("0xA", "alpha", 900)])
        ] }
        view.rebuild()
        compare(view.cursorAddress, "")
    }
    // Distinguishes: find and the cursor coexisting, which would give two rings and an ambiguous
    // Enter.
    function test_a_query_clears_the_cursor() {
        keyClick(Qt.Key_Tab)
        keyClick("a")
        compare(view.cursorAddress, "")
        verify(view.query.length > 0)
    }
    // Distinguishes: a cursor that leaks across summons on the kept-loaded component.
    function test_open_clears_the_cursor() {
        keyClick(Qt.Key_Tab)
        view.close()
        view.open()
        wait(120)
        compare(view.cursorAddress, "")
    }
    // Distinguishes: a focusWindow() that lost its scratchpad branch and always sent a plain
    // focus. Every other test in this file uses ordinary workspaces, so none of them can tell a
    // raise from a plain focus — this is the one path a stripped-down focusWindow (just
    // `Hyprland.dispatch('hl.dsp.focus...')`, no scratchpad check) would still pass every other
    // test while shipping the exact bug the user hit before this work started: a scratchpad
    // window matched by the overview got focused but stayed buried under a floating sibling.
    function test_enter_raises_a_cursor_on_a_scratchpad_window() {
        view.compositor.workspaces = { values: [
            wsRow(1, [client("0xA", "alpha", 100), client("0xB", "bravo", 900)]),
            wsRow(2, [client("0xC", "charlie", 100)]),
            scratchRow(-73, "0xS", "vault")
        ] }
        keyClick("s", Qt.ControlModifier)   // reveal the scratchpad row (Ctrl+S)
        var idx = -1
        for (var i = 0; i < view.boxes.length; i++) if (view.boxes[i].workspaceId === -2) { idx = i; break }
        verify(idx >= 0, "the scratchpad box must appear once shown")
        view.selectedIndex = idx
        keyClick(Qt.Key_Tab)
        compare(view.cursorAddress, "0xS")
        keyClick(Qt.Key_Return)
        compare(view.compositor.commands.length, 1)
        var cmd = view.compositor.commands[0]
        verify(cmd.indexOf('address:0xS') >= 0)
        verify(cmd.indexOf('alter_zorder({ mode = "top", window = sel })') >= 0,
               "a cursor on a scratchpad window must raise it, not just focus it, got: " + cmd)
        compare(view.opened, false)
    }

    // ---- Ctrl+W, pendingCloses, pending-move supersession ---------------------------------
    function closed(addr) {
        for (var i = 0; i < view.compositor.commands.length; i++) {
            var c = view.compositor.commands[i]
            if (c.indexOf('window.close') >= 0 && c.indexOf('address:' + addr) >= 0) return true
        }
        return false
    }
    function ctrlW() { keyClick(Qt.Key_W, Qt.ControlModifier) }

    // Distinguishes: Ctrl+W acting on the workspace rather than the cursor's window, and a close
    // that does not advance — the ring must land on the OTHER window, not stay on the closed one.
    function test_ctrl_w_closes_the_cursor_window_and_advances() {
        keyClick(Qt.Key_Tab)
        compare(view.cursorAddress, "0xA")
        ctrlW()
        verify(closed("0xA"))
        compare(view.cursorAddress, "0xB", "the ring moves off the window being closed")
        verify(view.testModel.get(0).closing || view.testModel.get(1).closing, "the closing tile dims")
    }
    // Distinguishes: THE repeated-close bug. With both windows still reported by the compositor,
    // a second Ctrl+W must close 0xB, and a third must close nothing — never cycle back to 0xA.
    function test_repeated_ctrl_w_clears_the_workspace_without_repeating() {
        keyClick(Qt.Key_Tab)
        ctrlW(); ctrlW()
        verify(closed("0xA")); verify(closed("0xB"))
        compare(view.cursorAddress, "", "no eligible window is left to ring")
        var n = view.compositor.commands.length
        ctrlW()
        compare(view.compositor.commands.length, n, "a third press has no target")
    }
    // Distinguishes: a workspace target silently closing something. Ctrl+W with no window target
    // must dispatch nothing at all.
    function test_ctrl_w_on_a_workspace_target_does_nothing() {
        compare(view.cursorAddress, "")
        ctrlW()
        compare(view.compositor.commands.length, 0)
    }
    // Distinguishes: auto-repeat closing a whole workspace from one held chord.
    function test_ctrl_w_ignores_auto_repeat() {
        keyClick(Qt.Key_Tab)
        ctrlW()
        var n = view.compositor.commands.length
        view.testKeys.Keys.pressed({ key: Qt.Key_W, modifiers: Qt.ControlModifier, isAutoRepeat: true,
                                     text: "", accepted: false })
        compare(view.compositor.commands.length, n)
    }
    // Distinguishes: the parked-mouse rule for a destructive key. The pointer sat over 0xB the
    // whole time; only the key press that came AFTER the move may let it decide.
    function test_ctrl_w_follows_the_most_recent_input_device() {
        keyClick(Qt.Key_Tab)                 // cursor on 0xA, pointer not live
        hoverTile("0xB")                     // pointer moved last
        ctrlW()
        verify(closed("0xB"), "the hovered tile wins")
        verify(!closed("0xA"))
    }
    // Distinguishes: an action key that clears liveness. The second Ctrl+W must still resolve to
    // the hovered window (a no-op, since its close is outstanding) and must NOT fall through to
    // the cursor. An arrow in between is the positive control that the cursor path still works.
    function test_consecutive_action_keys_keep_the_pointer_in_charge() {
        keyClick(Qt.Key_Tab)                 // cursor on 0xA
        hoverTile("0xB")
        ctrlW()
        var n = view.compositor.commands.length
        ctrlW()
        compare(view.compositor.commands.length, n, "0xB's close is already outstanding")
        verify(!closed("0xA"))
        keyClick(Qt.Key_Right); keyClick(Qt.Key_Left)   // navigation returns control to the keyboard
        keyClick(Qt.Key_Tab)
        ctrlW()
        verify(closed("0xA"))
    }
    // Distinguishes: a close that leaves the drop's optimistic row in place — applyTiles skips
    // updates and removals for an address in pendingMoves, so without supersession the tile of a
    // just-dropped window would survive its own close until the 1.8 s deadline.
    function test_closing_supersedes_a_pending_drop() {
        view.pendingMoves["0xA"] = { workspaceId: 2, pos: null, deadline: Date.now() + 1800 }
        keyClick(Qt.Key_Tab)
        compare(view.cursorAddress, "0xA")
        ctrlW()
        compare(view.pendingMoves["0xA"], undefined, "the optimistic row must not outlive the close")
    }
    // Distinguishes: a refused close that never lets go. Past the deadline, with the window still
    // reported, the tile must un-dim and become cyclable again.
    function test_a_refused_close_recovers_at_the_deadline() {
        keyClick(Qt.Key_Tab)
        ctrlW()
        verify(view.pendingCloses["0xA"] !== undefined)
        view.pendingCloses["0xA"] = Date.now() - 1      // the deadline has passed
        view.rebuild()
        compare(view.pendingCloses["0xA"], undefined)
        keyClick(Qt.Key_Tab)
        compare(view.cursorAddress, "0xA", "cyclable again")
    }
    // Distinguishes: the middle click drifting from Ctrl+W. Both must go through one path, so the
    // middle click clears pending state too.
    function test_middle_click_shares_the_close_path() {
        view.pendingMoves["0xA"] = { workspaceId: 2, pos: null, deadline: Date.now() + 1800 }
        var p = tileCentre("0xA")
        mouseClick(view, p.x, p.y, Qt.MiddleButton)
        verify(closed("0xA"))
        compare(view.pendingMoves["0xA"], undefined)
    }
    // Distinguishes: pendingCloses leaking across summons on the kept-loaded component, which
    // would leave a tile dimmed and un-cyclable on the next open.
    function test_open_clears_pending_closes() {
        keyClick(Qt.Key_Tab)
        ctrlW()
        view.close(); view.open(); wait(120)
        compare(Object.keys(view.pendingCloses).length, 0)
    }
}
