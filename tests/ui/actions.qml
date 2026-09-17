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
    // A second monitor, reported alongside `mon` but with no workspace of its own — the only thing
    // it needs to do is exist in Hyprland.monitors so Logic.menuItems() has an eligible target for
    // a workspace menu's "Move to"/"Swap with" rows (with just one monitor, `others` is always
    // empty and those rows never appear at all). The name is deliberately long: it is what widens
    // a menu row past the 150 px floor, the only way to exercise real reflow/clamp geometry.
    // Reusable beyond this file's own clamp test — a later task's Move/Swap tests need exactly
    // this same shape, hence its own function rather than being inlined into one test.
    function seedTwoMonitors(v) {
        seed(v)
        var mon2 = { name: "HDMI-A-1-EXTERNAL-DISPLAY", x: 1920, y: 1440, width: 1920, height: 1080,
                     scale: 1, lastIpcObject: { reserved: [0, 0, 0, 0], transform: 0,
                                                activeWorkspace: { id: -1 }, specialWorkspace: { id: 0, name: "" } } }
        v.compositor.monitors = { values: [mon, mon2] }
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

    // Distinguishes: the overview silently losing keyboard focus after a close. Hyprland refocuses
    // a window when the closed one was focused, and focusing a window takes keys off this on-demand
    // layer — so a repeated Ctrl+W would start landing in the window Hyprland picked. The cursor
    // warp is what re-grants focus; without this wiring nothing is dispatched and the overview goes
    // deaf. Mutation check: delete the closewindow branch in onRawEvent and this goes red.
    function test_a_window_closing_regrabs_keyboard_focus() {
        view.compositor.commands = []
        view.compositor.rawEvent({ name: "closewindow", data: "556cc931f180" })
        wait(30)
        var warps = 0
        for (var i = 0; i < view.compositor.commands.length; i++)
            if (view.compositor.commands[i].indexOf("cursor.move") >= 0) warps++
        compare(warps, 1, "exactly one cursor warp, to re-grant focus")
    }
    // Distinguishes: the picker going deaf after SUPER+n. A workspace switch focuses that
    // workspace's last window, which takes keys off the on-demand layer exactly as a close does —
    // the user reported this separately from the Ctrl+W case, and one shared rule fixes both.
    function test_a_workspace_switch_regrabs_keyboard_focus() {
        view.compositor.commands = []
        view.compositor.rawEvent({ name: "workspacev2", data: "3,3" })
        wait(30)
        var warps = 0
        for (var i = 0; i < view.compositor.commands.length; i++)
            if (view.compositor.commands[i].indexOf("cursor.move") >= 0) warps++
        compare(warps, 1, "exactly one cursor warp, to re-grant focus")
    }

    // Distinguishes: warping the cursor on every window close on the desktop, not just while the
    // picker is up. Closed, the overview holds no keyboard focus and has nothing to re-grab.
    function test_a_window_closing_while_closed_regrabs_nothing() {
        view.close()
        view.compositor.commands = []
        view.compositor.rawEvent({ name: "closewindow", data: "556cc931f180" })
        wait(30)
        compare(view.compositor.commands.length, 0)
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
    // The `!e.isAutoRepeat` guard (auto-repeat closing a whole workspace from one held chord) has
    // no offscreen test here: QtTest's QML key-event API has no way to set isAutoRepeat, and a
    // hand-built event object thrown at Keys.pressed() directly fails to convert to a
    // QQuickKeyEvent* and throws before the handler body runs — a test built on that would pass
    // identically whether or not the guard exists. Covered instead by a live check: holding
    // Ctrl+W on a workspace with several windows must dispatch exactly one close, not one per
    // repeat.
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
    // Distinguishes: open() wiping pendingCloses wholesale. Neither pendingMoves nor
    // pendingFullscreen is ever reset that way — all three decay on their own 1.8 s deadline via
    // the reconcile timer, which keeps running after close() for exactly this reason. Without
    // this a Ctrl+W, Escape, quick re-summon would present the window as ordinary and cyclable,
    // and a second Ctrl+W would dispatch a duplicate close.
    function test_pending_closes_survive_a_quick_reopen() {
        keyClick(Qt.Key_Tab)
        ctrlW()
        verify(view.pendingCloses["0xA"] !== undefined)
        view.close(); view.open(); wait(120)
        verify(view.pendingCloses["0xA"] !== undefined, "pending state must not be wiped on reopen")
    }
    // Distinguishes: closeWindow advancing the cursor regardless of `advanceCursor`. The shared
    // two-window fixture can't tell an ignored flag from a correct one — skipping the closed
    // window from two leaves only one candidate either way. Seeded locally (three windows on one
    // workspace) so the shared fixture is untouched for every other test.
    //
    // The cursor is parked on the THIRD (rightmost) window, not the first: closeWindow always
    // excludes the address it is closing from the ring before it ever looks at `advanceCursor`
    // (pendingCloses[addr] is set first, and closeSkipSet() reads it), so a broken implementation
    // that cycles unconditionally hands cycleWindows a `current` that is never IN the ring and
    // falls back to the ring's first entry — the leftmost surviving window. With the cursor
    // parked on the first window already, that fallback (0xA) coincides with the correct answer
    // (unchanged) and the bug goes unnoticed; parking it on the last window instead means the
    // fallback (0xA) and the correct answer (0xC, unchanged) can never coincide.
    function test_closing_a_non_cursor_window_leaves_the_cursor_in_place() {
        view.compositor.workspaces = { values: [
            wsRow(1, [client("0xA", "alpha", 100), client("0xB", "bravo", 500), client("0xC", "charlie", 900)])
        ] }
        view.rebuild()
        keyClick(Qt.Key_Tab); keyClick(Qt.Key_Tab); keyClick(Qt.Key_Tab)
        compare(view.cursorAddress, "0xC", "cursor on the third window")
        var p = tileCentre("0xB")
        mouseClick(view, p.x, p.y, Qt.MiddleButton)   // closes the second, not the cursor's window
        verify(closed("0xB"))
        compare(view.cursorAddress, "0xC", "the cursor must not move for a window it wasn't on")
    }

    // Distinguishes: `?` typed into the query instead of toggling the tier, and a second line
    // that is always visible.
    function test_question_mark_toggles_the_second_hint_tier() {
        compare(view.hintsExpanded, false)
        compare(view.query, "")
        keyClick("?")
        compare(view.hintsExpanded, true)
        compare(view.query, "", "? must not start a query")
        keyClick("?")
        compare(view.hintsExpanded, false)
    }
    // Distinguishes: a fixed hint budget that ignores the second tier, which would clip it.
    // wait() after the toggle: hintBox is a Column, and a Positioner only re-includes a child
    // that just became visible (hint2) on its next layout polish, not synchronously within the
    // same key event — reading hintSpace immediately would see the stale, pre-toggle size.
    function test_expanding_the_hints_grows_the_card_budget() {
        var before = view.testCard.hintSpace
        keyClick("?")
        wait(20)
        verify(view.testCard.hintSpace > before, "two tiers need more room than one")
    }
    // Distinguishes: the find bar resizing the card when the hints are expanded — the height
    // budget must already reserve the larger of the two, as it does for one tier today.
    function test_typing_does_not_move_the_card_with_hints_expanded() {
        keyClick("?")
        wait(20)   // let hintBox's Column settle on the expanded size before taking the budget
        var budget = view.testCard.hintSpace
        keyClick("a")
        verify(view.query.length > 0)
        compare(view.testCard.hintSpace, budget, "same budget for hints and the find bar")
    }
    // Distinguishes: `?` swallowed as a toggle while a query is active, which would make it
    // impossible to search for a title containing one.
    function test_question_mark_appends_while_a_query_is_active() {
        keyClick("a")
        keyClick("?")
        compare(view.query, "a?")
        compare(view.hintsExpanded, false)
    }
    // Distinguishes: the tier preference being reset by open(), which the spec keeps deliberately
    // (it is the one piece of state that survives a summon).
    function test_open_keeps_the_hint_tier() {
        keyClick("?")
        view.close(); view.open(); wait(120)
        compare(view.hintsExpanded, true)
    }

    // Distinguishes: the flags stopping anywhere between the compositor snapshot and the box —
    // the Tier 1 test pins layout() alone, this pins buildInput() and the seed together.
    function test_boxes_get_active_from_the_monitor_snapshot() {
        compare(view.boxForWs(1).active, true, "the seed's monitor shows workspace 1")
        compare(view.boxForWs(2).active, false)
        compare(view.boxForWs(1).synthetic, false)
    }

    // ---- the context menu ------------------------------------------------------------------
    function menuIds() {
        var out = []
        for (var i = 0; i < view.menuItems.length; i++) out.push(String(view.menuItems[i].id))
        return out
    }
    function rightPress(x, y) { mousePress(view, x, y, Qt.RightButton); mouseRelease(view, x, y, Qt.RightButton) }
    function rightPressTile(addr) { var p = tileCentre(addr); rightPress(p.x, p.y) }
    // The live delegate, not the model row — needed to check where the tile actually sits on
    // screen (e.g. after a cancelled drag), which tileCentre()'s model-based math can't see.
    function tileOf(addr) {
        var children = view.testCanvas.children
        for (var i = 0; i < children.length; i++)
            if (children[i].model && children[i].model.address === addr) return children[i]
        fail("Tile not found: " + addr)
    }
    // The live ContextMenu instance, for geometry checks the exposed root properties can't answer
    // (e.g. its own settled width/height, needed to check where it actually landed on screen).
    function menuComponent() {
        var found = null
        function walk(item) {
            if (!item || found) return
            if (item.toString().indexOf("ContextMenu") === 0) { found = item; return }
            for (var i = 0; i < item.children.length; i++) walk(item.children[i])
        }
        walk(view.testPanel)
        return found
    }

    // Distinguishes: a right press that opens nothing, or that opens the workspace menu because
    // the press fell through the tile to the well beneath it.
    function test_right_press_on_a_tile_opens_the_window_menu() {
        rightPressTile("0xA")
        compare(view.menuOpen, true)
        compare(view.menuTarget.kind, "window")
        compare(view.menuTarget.address, "0xA")
        compare(menuIds(), ["close", "float", "fullscreen"])
    }
    // Distinguishes: a right press that also starts a drag — the drag machinery accepts the
    // right button now, and only an explicit left-button check keeps it out.
    function test_a_right_press_never_starts_a_drag() {
        rightPressTile("0xA")
        compare(view.draggingAddress, "")
        compare(view.dragTile, null)
    }
    // Distinguishes: a cancelled gesture that still manages to submit a drop or open a menu, or
    // that leaves the tile stuck mid-drag instead of settling back at its model position.
    //
    // This does NOT assert that the drag survives a right press+release during it — it doesn't,
    // and that is the platform's doing, not a bug in this file. Qt 6.11.2 cancels a MouseArea's
    // exclusive grab as soon as ANY second accepted button completes a press-release cycle while
    // the first is still held, regardless of drag.target, of which item (if any) accepts the
    // second button, or of using a separate handler (TapHandler) instead of widening the same
    // MouseArea — confirmed with isolated reproductions outside this plugin (see
    // docs/specs/2026-09-15-actions-design.md for the recorded evidence). A drag machinery rewrite
    // onto DragHandler/TapHandler could avoid the cancellation, but that is out of scope here, and
    // right-click-cancels-a-drag is in any case a common, unsurprising convention, not a defect.
    // So this test's job is narrower and is what actually matters: prove the cancellation the
    // engine forces on us is SAFE — the left-button-only guard in onReleased is what earns this,
    // since without it the right release itself would be read as a drop.
    function test_a_right_click_during_a_left_drag_cancels_it_without_dropping() {
        var from = tileCentre("0xA")
        var beforeX = tileOf("0xA").x, beforeY = tileOf("0xA").y
        mousePress(view, from.x, from.y, Qt.LeftButton)
        mouseMove(view, from.x + 30, from.y + 10); wait(20)
        compare(view.draggingAddress, "0xA", "precondition: the left drag is live")
        mousePress(view, from.x + 30, from.y + 10, Qt.RightButton)
        mouseRelease(view, from.x + 30, from.y + 10, Qt.RightButton)
        // The platform has already ended the grab by this point; this release reaches no handler
        // at all (Qt delivers it nowhere) — sent anyway because the user's physical left button
        // really does come up eventually, and it must be harmless when it does.
        mouseRelease(view, from.x + 30, from.y + 10, Qt.LeftButton)
        compare(view.menuOpen, false, "no menu from the cancelled gesture")
        compare(view.compositor.commands.length, 0, "the cancelled gesture must not submit a drop")
        compare(view.dragTile, null, "the drag ends cleanly, via the existing cancel path")
        compare(view.draggingAddress, "")
        compare(tileOf("0xA").x, beforeX, "the tile lands back at its model position")
        compare(tileOf("0xA").y, beforeY)
    }
    // Distinguishes: a workspace menu that cannot be reached on a full well. A well with one
    // tiled window has only a 3 px inset of bare well, so the number badge is the real target.
    function test_right_press_on_the_workspace_badge_opens_the_workspace_menu() {
        var b = view.boxForWs(2)
        var p = view.testCanvas.mapToItem(view, b.x + 12, b.y + 12)   // the badge sits at +6,+6
        rightPress(p.x, p.y)
        compare(view.menuOpen, true)
        compare(view.menuTarget.kind, "workspace")
        compare(view.menuTarget.id, 2)
    }
    // Distinguishes: a badge MouseArea that swallows left clicks too, which would break jumping
    // to a workspace by clicking its well near the badge.
    function test_a_left_click_on_the_badge_still_jumps() {
        var b = view.boxForWs(2)
        var p = view.testCanvas.mapToItem(view, b.x + 12, b.y + 12)
        mouseClick(view, p.x, p.y, Qt.LeftButton)
        compare(view.opened, false)
        verify(view.compositor.commands[0].indexOf('workspace = "2"') >= 0)
    }
    // Distinguishes: arrow keys leaking past the menu to the box selection, and Enter not
    // activating the highlighted row.
    function test_arrows_and_enter_drive_the_menu() {
        var beforeSel = view.selectedId
        rightPressTile("0xA")
        keyClick(Qt.Key_Down); keyClick(Qt.Key_Down)
        compare(view.menuIndex, 1, "the highlight moved, not the box selection")
        compare(view.selectedId, beforeSel)
        keyClick(Qt.Key_Return)
        compare(view.menuOpen, false, "activation dismisses first")
    }
    // Distinguishes: a highlight that does not wrap from "none" to the last row.
    function test_up_from_no_highlight_takes_the_last_row() {
        rightPressTile("0xA")
        keyClick(Qt.Key_Up)
        compare(view.menuIndex, 2)
    }
    // Distinguishes: Esc closing the overview instead of spending itself on the menu.
    function test_escape_dismisses_the_menu_only() {
        rightPressTile("0xA")
        keyClick(Qt.Key_Escape)
        compare(view.menuOpen, false)
        compare(view.opened, true)
        compare(view.compositor.commands.length, 0)
    }
    // Distinguishes: THE chord-leak bug. Ctrl must not dismiss; the W that follows must dismiss
    // and must NOT reach closeTarget().
    function test_a_chord_with_the_menu_open_dismisses_without_acting() {
        rightPressTile("0xA")
        keyPress(Qt.Key_Control)
        compare(view.menuOpen, true, "a lone modifier leaves the menu alone")
        keyClick(Qt.Key_W, Qt.ControlModifier)
        compare(view.menuOpen, false)
        keyRelease(Qt.Key_Control)
        compare(view.compositor.commands.length, 0, "the chord's key was swallowed by the dismissal")
    }
    // Distinguishes: a letter that dismisses and ALSO starts a query.
    function test_a_letter_dismisses_without_starting_a_query() {
        rightPressTile("0xA")
        keyClick("a")
        compare(view.menuOpen, false)
        compare(view.query, "")
    }
    // Distinguishes: auto-repeats of the dismissing key falling through as ordinary input — a
    // held letter would start a query the moment the menu closed.
    function test_a_held_letter_is_swallowed_until_it_is_released() {
        rightPressTile("0xA")
        keyPress("a")                       // dismisses
        compare(view.menuOpen, false)
        compare(view.query, "")
        // A second press while still held. QtTest cannot synthesise a real auto-repeat event
        // (its QML API has no way to set isAutoRepeat), but the latch does not key on that flag
        // for presses — only the release handler does — so this exercises the same code path a
        // repeat would take. True auto-repeat is a live-check item, see Task 15.
        keyPress("a")
        compare(view.query, "", "a further press of the dismissing key stays swallowed")
        keyRelease("a")
        keyClick("a")
        compare(view.query, "a", "a fresh press after the release is ordinary input")
    }
    // Distinguishes: a dismissal catcher that is not panel-sized, letting a scrim press both
    // dismiss the menu and close the overview. The second half is the positive control.
    function test_a_press_outside_dismisses_without_closing() {
        rightPressTile("0xA")
        mouseClick(view, 8, 8, Qt.LeftButton)      // the scrim, far outside the card
        compare(view.menuOpen, false)
        compare(view.opened, true, "one press, one effect")
        mouseClick(view, 8, 8, Qt.LeftButton)
        compare(view.opened, false, "with no menu the same press closes")
    }
    // Distinguishes: a catcher stacked ABOVE the menu, which would make every row press a
    // dismissal and the menu unusable with the mouse.
    function test_a_row_press_activates_it() {
        rightPressTile("0xA")
        // Column positions its children (the row delegates' y) in a polish pass, same as the
        // width settling test_menu_clamps_to_the_panel_after_the_row_widens_it already waits for
        // — without this every row reads y=0 at this point and the click lands on whichever row
        // the Repeater happened to draw on top (the last one), not necessarily row 0.
        wait(50)
        var rows = []
        function collect(item) {
            if (!item) return
            if (item.objectName === "menuRow") rows.push(item)
            for (var i = 0; i < item.children.length; i++) collect(item.children[i])
        }
        collect(view.testPanel)
        compare(rows.length, 3, "one delegate per item")
        var c = rows[0].mapToItem(view, rows[0].width / 2, rows[0].height / 2)
        mouseClick(view, c.x, c.y, Qt.LeftButton)
        compare(view.menuOpen, false)
        verify(closed("0xA"), "the Close row acted")
    }
    // Distinguishes: an open menu frozen on the snapshot it was drawn from. Floating the window
    // elsewhere must relabel the row, keeping the highlight on the same item.
    function test_a_rebuild_updates_the_items_and_keeps_the_highlight() {
        rightPressTile("0xA")
        keyClick(Qt.Key_Down); keyClick(Qt.Key_Down)
        compare(menuIds()[1], "float")
        compare(view.menuIndex, 1)
        var c = client("0xA", "alpha", 100); c.floating = true
        view.compositor.workspaces = { values: [
            wsRow(1, [c, client("0xB", "bravo", 900)]), wsRow(2, [client("0xC", "charlie", 100)]) ] }
        view.rebuild()
        compare(menuIds()[1], "tile", "the row follows the compositor")
        compare(view.menuIndex, 1, "the highlight stays on the same item")
    }
    // Distinguishes: a menu left open over a target that no longer exists, whose activation would
    // then dispatch for a dead address.
    function test_a_rebuild_that_removes_the_target_dismisses() {
        rightPressTile("0xA")
        view.compositor.workspaces = { values: [
            wsRow(1, [client("0xB", "bravo", 900)]), wsRow(2, [client("0xC", "charlie", 100)]) ] }
        view.rebuild()
        compare(view.menuOpen, false)
        compare(view.menuTarget, null)
    }
    // Distinguishes: a placement clamp that reads contextMenu.width/height as a one-shot snapshot
    // at open time, before the Repeater-of-Text layout pass has actually measured the menu — on
    // the very first open that reads the 150 px floor, not this menu's real (possibly wider) size.
    // Every other seed in this suite reports one monitor, so Logic.menuItems() never has an
    // eligible Move/Swap target and no row is ever wider than the floor — the snapshot bug is real
    // but invisible without a second monitor to widen a row past it.
    function test_menu_clamps_to_the_panel_after_the_row_widens_it() {
        seedTwoMonitors(view)
        view.openWorkspaceMenu(2, { x: view.testPanel.width - 10, y: view.testPanel.height - 10 })
        wait(50)   // let the Repeater/Text polish pass measure the real (wider) width
        var cm = menuComponent()
        verify(cm !== null, "ContextMenu not found under testPanel")
        verify(cm.width > 150, "precondition: the Move row must actually widen the menu past the floor")
        verify(cm.x + cm.width <= view.testPanel.width,
               "right edge must stay inside the panel, got x=" + cm.x + " width=" + cm.width)
        verify(cm.y + cm.height <= view.testPanel.height,
               "bottom edge must stay inside the panel, got y=" + cm.y + " height=" + cm.height)
    }
    // Distinguishes: a menu that scrolls away from its target, or is left hanging over new content.
    // Both axes: the Y wire is easy to remember (the layout mostly scrolls vertically) and the X
    // one easy to forget, so a fix that only wired onContentYChanged would still pass a Y-only test.
    function test_scrolling_dismisses_the_menu() {
        rightPressTile("0xA")
        view.testFlick.contentY += 10
        compare(view.menuOpen, false, "scrolling Y dismisses")
        rightPressTile("0xA")
        view.testFlick.contentX += 10
        compare(view.menuOpen, false, "scrolling X dismisses too")
    }
    // Distinguishes: a menu surviving the overview being toggled away with SUPER+P.
    function test_close_dismisses_the_menu() {
        rightPressTile("0xA")
        view.close()
        compare(view.menuOpen, false)
    }
    // Distinguishes: the menu opening mid-drag from the well or badge as well as the tile.
    function test_no_menu_opens_while_a_drag_is_in_flight() {
        var from = tileCentre("0xA")
        mousePress(view, from.x, from.y, Qt.LeftButton)
        mouseMove(view, from.x + 30, from.y + 10); wait(20)
        var b = view.boxForWs(2)
        var p = view.testCanvas.mapToItem(view, b.x + 12, b.y + 12)
        rightPress(p.x, p.y)
        compare(view.menuOpen, false)
        mouseRelease(view, from.x + 30, from.y + 10, Qt.LeftButton)
    }

    function dispatched(fragment) {
        for (var i = 0; i < view.compositor.commands.length; i++)
            if (view.compositor.commands[i].indexOf(fragment) >= 0) return true
        return false
    }

    // Distinguishes: a menu row that dispatches the wrong chunk, or none. "Float" must send the
    // float chunk for THIS address.
    function test_the_float_row_dispatches_the_float_chunk() {
        rightPressTile("0xA")
        compare(menuIds()[1], "float")
        keyClick(Qt.Key_Down); keyClick(Qt.Key_Down); keyClick(Qt.Key_Return)
        verify(dispatched("window.float"))
        verify(dispatched("address:0xA"))
        verify(dispatched('action = "on"'), "the id names the state to set, not a toggle")
    }
    // Distinguishes: Fullscreen sending mode 0 (the badge's direction) instead of entering, and a
    // wiring mixup that sent the chunk for the wrong window (menuTarget vs. some other address).
    function test_the_fullscreen_row_enters_fullscreen() {
        rightPressTile("0xA")
        keyClick(Qt.Key_Down); keyClick(Qt.Key_Down); keyClick(Qt.Key_Down); keyClick(Qt.Key_Return)
        verify(dispatched("window.fullscreen"))
        verify(dispatched("address:0xA"))
        compare(view.pendingFullscreen["0xA"].mode, 2)
    }
    // Distinguishes: a window action that leaves a pending drop in place, whose optimistic row
    // would then survive the action until the 1.8 s deadline.
    function test_a_window_action_supersedes_a_pending_drop() {
        view.pendingMoves["0xA"] = { workspaceId: 2, pos: null, deadline: Date.now() + 1800 }
        rightPressTile("0xA")
        keyClick(Qt.Key_Down); keyClick(Qt.Key_Down); keyClick(Qt.Key_Return)
        compare(view.pendingMoves["0xA"], undefined)
    }

    // ---- workspace actions: Lock/Unlock, Close all ----------------------------------------
    // Distinguishes: a Lock row that toggles rather than setting the state its label names.
    function test_the_lock_row_arms_the_workspace() {
        view.testLocks.loadArmed([])
        var b = view.boxForWs(2)
        var p = view.testCanvas.mapToItem(view, b.x + 12, b.y + 12)
        rightPress(p.x, p.y)
        compare(menuIds()[0], "lock")
        keyClick(Qt.Key_Down); keyClick(Qt.Key_Return)
        compare(view.testLocks.isArmed("2"), true)
        rightPress(p.x, p.y)
        compare(menuIds()[0], "unlock", "the row now names the other direction")
    }
    // Distinguishes: an explicit-state setter degraded into an unconditional toggle. Task 12's
    // note on this: a chunk/setter meant to set an explicit state, changed to toggle instead,
    // reproduces the right end state by coincidence whenever the starting state is the opposite
    // one — exactly what test_the_lock_row_arms_the_workspace alone could not catch, since it only
    // ever presses Lock once from unarmed. Calling lockSet with the state it is ALREADY in is the
    // case only an explicit setter gets right: a toggle would flip it back off and re-dispatch.
    function test_lock_set_already_in_the_requested_state_is_a_no_op() {
        view.testLocks.loadArmed([])
        view.lockSet(2, true)
        compare(view.testLocks.isArmed("2"), true)
        compare(view.testLocks.writes.length, 1)
        var syncs = 0
        for (var i = 0; i < view.compositor.commands.length; i++)
            if (view.compositor.commands[i].indexOf("ARMED") >= 0) syncs++
        view.lockSet(2, true)                       // already armed: must be a no-op
        compare(view.testLocks.isArmed("2"), true, "a redundant Lock must not invert it")
        compare(view.testLocks.writes.length, 1, "no redundant write")
        var syncs2 = 0
        for (var j = 0; j < view.compositor.commands.length; j++)
            if (view.compositor.commands[j].indexOf("ARMED") >= 0) syncs2++
        compare(syncs2, syncs, "no redundant sync either")
    }
    // Carry-forward from an earlier review: no test asserted the UNARMED direction of the lock
    // label, so a build that swapped the "Lock"/"Unlock" label strings while keeping the ids
    // correct would have passed the whole suite. Pin both labels, not just the ids.
    function test_the_lock_row_label_names_each_direction() {
        view.testLocks.loadArmed([])
        var b = view.boxForWs(2)
        var p = view.testCanvas.mapToItem(view, b.x + 12, b.y + 12)
        rightPress(p.x, p.y)
        compare(view.menuItems[0].id, "lock")
        compare(view.menuItems[0].label, "Lock", "unarmed row must say Lock, not Unlock")
        keyClick(Qt.Key_Escape)
        view.testLocks.loadArmed(["2"])
        rightPress(p.x, p.y)
        compare(view.menuItems[0].id, "unlock")
        compare(view.menuItems[0].label, "Unlock", "armed row must say Unlock, not Lock")
    }
    // Distinguishes: Close all leaving a just-dropped window's optimistic row behind — the
    // compositor closes it (it reads the workspace's own list), so the row must go with it.
    function test_close_all_clears_a_pending_drop_into_that_workspace() {
        view.pendingMoves["0xC"] = { workspaceId: 1, pos: null, deadline: Date.now() + 1800 }
        var b = view.boxForWs(1)
        var p = view.testCanvas.mapToItem(view, b.x + 12, b.y + 12)
        rightPress(p.x, p.y)
        var i = menuIds().indexOf("closeAll")
        verify(i >= 0, "workspace 1 has windows")
        for (var k = 0; k <= i; k++) keyClick(Qt.Key_Down)
        keyClick(Qt.Key_Return)
        verify(dispatched("close all") || dispatched("window.close"))
        compare(view.pendingMoves["0xC"], undefined, "the dropped window's row must not outlive it")
        verify(view.pendingCloses["0xA"] !== undefined, "windows already on the workspace too")
    }

    // `seedTwoMonitors(v)` ALREADY EXISTS in tests/ui/actions.qml — Task 10 added it when
    // fixing the menu placement clamp, which needed a menu wide enough to overflow the
    // panel edge. Reuse it; do not define a second one. It seeds a second monitor so the
    // Move/Swap rows exist at all.
    // Distinguishes: a Move row that names the workspace's own monitor, or dispatches nothing.
    function test_the_move_row_dispatches_a_workspace_move() {
        seedTwoMonitors(view)
        var b = view.boxForWs(1)
        var p = view.testCanvas.mapToItem(view, b.x + 12, b.y + 12)
        rightPress(p.x, p.y)
        var i = menuIds().indexOf("move:HDMI-A-1-EXTERNAL-DISPLAY")
        verify(i >= 0, "the OTHER monitor is offered: " + menuIds().join(","))
        for (var k = 0; k <= i; k++) keyClick(Qt.Key_Down)
        keyClick(Qt.Key_Return)
        verify(dispatched("workspace.move"))
        verify(dispatched('monitor = "HDMI-A-1-EXTERNAL-DISPLAY"'))
        verify(dispatched('workspace = "1"'))
    }

    // Distinguishes: Swap offered on a hidden workspace (where swap_monitors would act on a
    // different workspace entirely), and a swap chunk that omits the source monitor.
    function test_swap_is_offered_only_on_an_active_workspace() {
        seedTwoMonitors(view)
        // seedTwoMonitors names the second monitor with a deliberately LONG connector (Task 10
        // needed a menu wide enough to overflow the panel edge). Read the name from the seed
        // rather than hardcoding it.
        var otherMon = view.compositor.monitors.values[1].name
        var hidden = view.boxForWs(2)
        var ph = view.testCanvas.mapToItem(view, hidden.x + 12, hidden.y + 12)
        rightPress(ph.x, ph.y)
        compare(menuIds().indexOf("swap:" + otherMon), -1, "workspace 2 is not what eDP-1 shows")
        keyClick(Qt.Key_Escape)
        var b = view.boxForWs(1)
        var p = view.testCanvas.mapToItem(view, b.x + 12, b.y + 12)
        rightPress(p.x, p.y)
        var i = menuIds().indexOf("swap:" + otherMon)
        verify(i >= 0)
        for (var k = 0; k <= i; k++) keyClick(Qt.Key_Down)
        keyClick(Qt.Key_Return)
        verify(dispatched("workspace.swap_monitors"))
        verify(dispatched('monitor1 = "TEST"'), "the workspace's own monitor is the source")
        verify(dispatched('monitor2 = "' + otherMon + '"'))
    }
}
