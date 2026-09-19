import QtQuick
import QtTest
import "../logic.js" as Logic

TestCase {
    name: "Actions"

    function cand(addr, x, y, w, h, z) { return { address: addr, x: x, y: y, w: w, h: h, z: z } }

    // ---- Modifier keys -----------------------------------------------------------------
    // Distinguishes: a raw key constant in logic.js that does not match the Qt enum it claims
    // to be. logic.js is a `.pragma library` with no access to Qt.Key_*, so every value there is
    // hand-written hex — a transposed digit makes a modifier press count as an ordinary key,
    // silently taking the target away from the pointer mid-chord. Comparing against the real
    // enum here is what pins them.
    //
    // This also carries the cases the UI suite CANNOT: QTest cannot synthesize Key_AltGr on
    // Qt 6.4, which CI runs — its keyToAscii has no case for it and the default branch asserts,
    // aborting the whole run (qasciikey.cpp:280 in v6.4.2). tests/ui/actions.qml therefore
    // presses only the five keys Qt 6.4 can synthesize, and AltGr is covered here instead.
    function test_isModifierKey_covers_every_modifier_and_nothing_else() {
        var mods = [Qt.Key_Shift, Qt.Key_Control, Qt.Key_Alt, Qt.Key_Meta,
                    Qt.Key_CapsLock, Qt.Key_AltGr]
        for (var i = 0; i < mods.length; i++)
            verify(Logic.isModifierKey(mods[i]), "modifier " + i + " (0x" + mods[i].toString(16) + ")")
        // Keys that must NOT count: the chord partners (Ctrl+W, Ctrl+L), the navigation keys,
        // and the lock keys that are not modifiers at all.
        var others = [Qt.Key_W, Qt.Key_L, Qt.Key_A, Qt.Key_Tab, Qt.Key_Backtab, Qt.Key_Up,
                      Qt.Key_Down, Qt.Key_Left, Qt.Key_Right, Qt.Key_Return, Qt.Key_Enter,
                      Qt.Key_Escape, Qt.Key_Space, Qt.Key_NumLock, Qt.Key_ScrollLock, Qt.Key_1]
        for (var j = 0; j < others.length; j++)
            verify(!Logic.isModifierKey(others[j]),
                   "not a modifier: 0x" + others[j].toString(16))
    }

    // Distinguishes: a Space that clears pointer liveness like an ordinary key. The key handler
    // clears pointerLive for everything isActionKey rejects, BEFORE any resolve runs — so a Space
    // outside this predicate means hovering one window and pressing Space previews the Tab cursor
    // instead. Also pins the hex: logic.js is a .pragma library with no Qt.Key_* access, so 0x20
    // is hand-written and a transposed digit would make Space an ordinary key silently.
    function test_isActionKey_accepts_bare_space_only() {
        verify(Logic.isActionKey(Qt.Key_Space, 0, Qt.ControlModifier), "bare Space is an action key")
        var chords = [Qt.ControlModifier, Qt.AltModifier, Qt.MetaModifier,
                      Qt.ControlModifier | Qt.AltModifier]
        for (var i = 0; i < chords.length; i++)
            verify(!Logic.isActionKey(Qt.Key_Space, chords[i], Qt.ControlModifier),
                   "chorded Space is not an action key (chord " + chords[i] + ")")
        // Positive control: the existing action keys must still qualify, so a regression that
        // replaced the predicate's body rather than extending it cannot pass this test.
        verify(Logic.isActionKey(Qt.Key_Return, 0, Qt.ControlModifier))
        verify(Logic.isActionKey(Qt.Key_W, Qt.ControlModifier, Qt.ControlModifier))
        verify(!Logic.isActionKey(Qt.Key_Tab, 0, Qt.ControlModifier), "Tab is keyboard intent")
    }

    // Distinguishes: a hit test that returns the FIRST containing rect instead of the topmost.
    // Both tiles contain (15,15); only a z-aware implementation answers "b".
    function test_tileAt_picks_the_highest_z() {
        var c = [cand("a", 0, 0, 100, 100, 10), cand("b", 10, 10, 50, 50, 20)]
        compare(Logic.tileAt(c, 15, 15), "b")
    }
    // Distinguishes: a tie broken by first-seen rather than paint order. The Repeater paints
    // later delegates on top, so the later of two equal-z rects must win.
    function test_tileAt_later_wins_a_z_tie() {
        var c = [cand("a", 0, 0, 100, 100, 10), cand("b", 0, 0, 100, 100, 10)]
        compare(Logic.tileAt(c, 50, 50), "b")
    }
    // Distinguishes: a miss reported as a hit on the nearest rect (drop targeting does that
    // deliberately; the action hit test must not).
    function test_tileAt_misses_return_empty() {
        compare(Logic.tileAt([cand("a", 0, 0, 10, 10, 1)], 50, 50), "")
        compare(Logic.tileAt([], 1, 1), "")
    }

    function input(o) {
        var base = { pointerLive: false, pointerTileAddress: "", pointerWorkspaceId: -1,
                     query: "", matchAddress: "", cursorAddress: "", selectedId: -1 }
        for (var k in o) base[k] = o[k]
        return base
    }
    // Distinguishes: a resolver that consults the keyboard first. With BOTH a live pointer over
    // a tile and a cursor set, only pointer-first answers "0xP".
    function test_target_live_pointer_beats_the_cursor() {
        var t = Logic.target(input({ pointerLive: true, pointerTileAddress: "0xP",
                                     cursorAddress: "0xC", selectedId: 3 }))
        compare(t.kind, "window"); compare(t.address, "0xP")
    }
    // Distinguishes: a live pointer over a well falling through to the keyboard instead of
    // naming the workspace under it.
    function test_target_live_pointer_over_a_well() {
        var t = Logic.target(input({ pointerLive: true, pointerWorkspaceId: 4, cursorAddress: "0xC" }))
        compare(t.kind, "workspace"); compare(t.id, 4)
    }
    // Distinguishes: a live pointer over empty canvas silently acting on the keyboard target.
    // Destructive actions must have no target rather than a surprising one.
    function test_target_live_pointer_over_nothing_is_null() {
        compare(Logic.target(input({ pointerLive: true, cursorAddress: "0xC", selectedId: 3 })), null)
    }
    // Distinguishes: the keyboard precedence order collapsing. Each assertion removes one level.
    function test_target_keyboard_order_is_match_then_cursor_then_workspace() {
        var m = Logic.target(input({ query: "sl", matchAddress: "0xM", cursorAddress: "0xC", selectedId: 3 }))
        compare(m.address, "0xM")
        var c = Logic.target(input({ cursorAddress: "0xC", selectedId: 3 }))
        compare(c.address, "0xC")
        var w = Logic.target(input({ selectedId: 3 }))
        compare(w.kind, "workspace"); compare(w.id, 3)
        compare(Logic.target(input({})), null)
    }
    // Distinguishes: a match address honoured with no query active (find is off; the stale
    // address must not win over the cursor).
    function test_target_ignores_a_match_address_without_a_query() {
        var t = Logic.target(input({ matchAddress: "0xM", cursorAddress: "0xC" }))
        compare(t.address, "0xC")
    }
    // Distinguishes: a query active but with no match yet (matchAddress empty) falling through
    // to the cursor or the selected workspace instead of staying "no target". A query with no
    // match must be terminal: falling through would make a failed search plus Enter jump
    // somewhere the user did not ask to go (a mistyped search teleporting to whatever workspace
    // happens to be selected is worse than doing nothing). Query and cursor can never both be
    // active in the running overview (setQuery() clears the cursor), but the branch is written
    // terminal anyway, not "unreachable so it doesn't matter" — see the next test.
    function test_target_query_without_match_has_no_target() {
        compare(Logic.target(input({ query: "xyz", matchAddress: "", cursorAddress: "0xC" })), null)
    }
    // Distinguishes: the terminal branch regressing back into a fall-through — the case a future
    // "simplification" would most plausibly reintroduce. A query with no match and a plainly
    // selectable workspace must still answer null, not the workspace.
    function test_target_query_without_match_ignores_the_selected_workspace() {
        compare(Logic.target(input({ query: "xyz", matchAddress: "", selectedId: 3 })), null)
    }

    function tile(addr, ws, x, y) { return { address: addr, wsid: ws, x: x, y: y } }

    property var rows: [tile("b", 1, 200, 0), tile("a", 1, 0, 0), tile("c", 1, 0, 300), tile("z", 2, 0, 0)]
    // Reading order is y then x: "b" is to the right of "a" on the same row, "c" is below both.
    // Distinguishes: cycling in model order instead of reading order. The model here is
    // deliberately b,a,c — only a sorted implementation answers a,b,c.
    // ---- Tab over workspaces, arrows over windows -------------------------------------------
    function wsBox(id, focused) { return { workspaceId: id, focused: !!focused } }

    // Distinguishes: Tab following layout order (boxes are grouped by monitor) rather than
    // workspace number, and a first Tab that lands on the workspace you are already on.
    function test_cycleWorkspace_counts_from_the_focused_workspace_in_number_order() {
        var boxes = [wsBox(6), wsBox(1), wsBox(2, true), wsBox(7)]
        compare(Logic.cycleWorkspace(boxes, -1, 1), 0, "from nothing: the one after the focused ws 2 is ws 6")
        compare(Logic.cycleWorkspace(boxes, 0, 1), 3, "ws 6 -> ws 7")
        compare(Logic.cycleWorkspace(boxes, 3, 1), 1, "ws 7 wraps to ws 1")
        compare(Logic.cycleWorkspace(boxes, 1, -1), 3, "Shift+Tab from ws 1 wraps to ws 7")
    }
    // Distinguishes: the scratchpad row (id -2) sorting first because its id is negative.
    function test_cycleWorkspace_puts_the_scratchpad_last() {
        var boxes = [wsBox(Logic.SCRATCHPAD_ID), wsBox(1, true), wsBox(2)]
        compare(Logic.cycleWorkspace(boxes, 2, 1), 0, "after the last numbered workspace comes the scratchpad")
        compare(Logic.cycleWorkspace(boxes, 0, 1), 1, "and after it, round to ws 1")
    }
    function test_cycleWorkspace_edge_cases() {
        compare(Logic.cycleWorkspace([], -1, 1), -1)
        compare(Logic.cycleWorkspace([wsBox(3), wsBox(4)], -1, 1), 0, "no focused box: start at the first")
        compare(Logic.cycleWorkspace([wsBox(3), wsBox(4)], -1, -1), 1, "…or the last, going back")
    }
    // Distinguishes: arrows that walk reading order instead of space. c sits BELOW a, so Down
    // from a must reach c even though b comes before c in reading order.
    function test_navigateWindows_is_spatial() {
        var tiles = [
            { address: "a", wsid: 1, x: 0,   y: 0,   w: 400, h: 300 },
            { address: "b", wsid: 1, x: 500, y: 0,   w: 400, h: 300 },
            { address: "c", wsid: 1, x: 0,   y: 400, w: 400, h: 300 },
            { address: "z", wsid: 2, x: 0,   y: 0,   w: 400, h: 300 }
        ]
        compare(Logic.navigateWindows(tiles, 1, "a", "down", null), "c")
        compare(Logic.navigateWindows(tiles, 1, "a", "right", null), "b")
        compare(Logic.navigateWindows(tiles, 1, "b", "right", null), "b", "nothing further right: stay")
        compare(Logic.navigateWindows(tiles, 1, "", "right", null), "a", "from nothing: the first window")
        compare(Logic.navigateWindows(tiles, 1, "", "left", null), "c", "…or the last, going back")
        compare(Logic.navigateWindows(tiles, 9, "", "right", null), "", "an empty workspace has no target")
        compare(Logic.navigateWindows(tiles, 1, "a", "down", { c: true }), "a", "a closing window is skipped")
    }

    function test_navigateWindows_left_reaches_taller_overlapping_neighbours() {
        // Live dwindle layout: the 2px gap puts the tall neighbour's centre just outside
        // the short tile. A centre-in-current-row test incorrectly makes Left a no-op.
        var tiles = [
            { address: "a", wsid: 2, x: 201, y: 1467, w: 1022, h: 1252 },
            { address: "b", wsid: 2, x: 1225, y: 1467, w: 1022, h: 625 },
            { address: "c", wsid: 2, x: 1225, y: 2094, w: 510, h: 625 },
            { address: "d", wsid: 2, x: 1737, y: 2094, w: 510, h: 312 },
            { address: "e", wsid: 2, x: 1737, y: 2408, w: 510, h: 311 }
        ]
        compare(Logic.navigateWindows(tiles, 2, "b", "left", null), "a")
        compare(Logic.navigateWindows(tiles, 2, "c", "left", null), "a")
        compare(Logic.navigateWindows(tiles, 2, "d", "left", null), "c")
        compare(Logic.navigateWindows(tiles, 2, "e", "left", null), "c")
        // Mirror the same layout: the fix must work for Right as well.
        for (var i = 0; i < tiles.length; i++) tiles[i].x = -tiles[i].x - tiles[i].w
        compare(Logic.navigateWindows(tiles, 2, "b", "right", null), "a")
        compare(Logic.navigateWindows(tiles, 2, "e", "right", null), "c")
    }

    function test_navigateWindows_reaches_concentric_windows() {
        // Deliberately shuffled; all three centres are (300, 300).
        var tiles = [
            { address: "c", wsid: 1, x: 200, y: 200, w: 200, h: 200 },
            { address: "a", wsid: 1, x: 0, y: 0, w: 600, h: 600 },
            { address: "b", wsid: 1, x: 100, y: 100, w: 400, h: 400 }
        ]
        var dirs = ["right", "down", "left", "up"]
        for (var i = 0; i < dirs.length; i++) {
            var order = i < 2 ? ["a", "b", "c"] : ["c", "b", "a"]
            var cursor = ""
            for (var j = 0; j < order.length; j++) {
                cursor = Logic.navigateWindows(tiles, 1, cursor, dirs[i], null)
                compare(cursor, order[j], dirs[i] + " reaches every window")
            }
            compare(Logic.navigateWindows(tiles, 1, cursor, dirs[i], null), cursor, "no wrap at the edge")
        }
        compare(Logic.navigateWindows(tiles, 1, "a", "right", { b: true }), "c", "skip pending closes")
        tiles.push({ address: "d", wsid: 1, x: 800, y: 200, w: 200, h: 200 })
        compare(Logic.navigateWindows(tiles, 1, "a", "right", null), "b", "visit overlapping peers before leaving")
        compare(Logic.navigateWindows(tiles, 1, "c", "right", null), "d", "resume spatial navigation at the end")
    }

    function test_navigateWindows_identical_rects_have_a_stable_order() {
        var tiles = [
            { address: "c", wsid: 1, x: 0, y: 0, w: 400, h: 300 },
            { address: "a", wsid: 1, x: 0, y: 0, w: 400, h: 300 },
            { address: "b", wsid: 1, x: 0, y: 0, w: 400, h: 300 },
            { address: "aa", wsid: 2, x: 0, y: 0, w: 400, h: 300 }
        ]
        compare(Logic.navigateWindows(tiles, 1, "a", "right", null), "b")
        compare(Logic.navigateWindows(tiles, 1, "b", "right", null), "c")
        compare(Logic.navigateWindows(tiles, 1, "c", "left", null), "b")
    }

    function test_navigateWindows_steps_only_to_touching_neighbours() {
        // The live dwindle layout from the bug report: "a" is a full-height column beside a
        // stack of four. Nothing sits above or below "a", so Up and Down there must stay put
        // rather than sidestep, and Right must land on the tile "a" actually touches.
        var tiles = [
            { address: "a", wsid: 2, x: 201, y: 1467, w: 922, h: 1252 },
            { address: "b", wsid: 2, x: 1125, y: 1467, w: 1122, h: 625 },
            { address: "c", wsid: 2, x: 1125, y: 2094, w: 560, h: 625 },
            { address: "d", wsid: 2, x: 1687, y: 2094, w: 560, h: 312 },
            { address: "e", wsid: 2, x: 1687, y: 2408, w: 560, h: 311 }
        ]
        var expected = {
            a: { left: "a", right: "b", up: "a", down: "a" },
            b: { left: "a", right: "b", up: "b", down: "c" },
            c: { left: "a", right: "d", up: "b", down: "c" },
            d: { left: "c", right: "d", up: "b", down: "e" },
            e: { left: "c", right: "e", up: "d", down: "e" }
        }
        var dirs = ["left", "right", "up", "down"]
        for (var i = 0; i < tiles.length; i++) {
            for (var j = 0; j < dirs.length; j++) {
                var from = tiles[i].address
                compare(Logic.navigateWindows(tiles, 2, from, dirs[j], null),
                        expected[from][dirs[j]], dirs[j] + " from " + from)
            }
        }
    }

    function test_navigateWindows_ties_go_to_reading_order() {
        // A dwindle split leaves two neighbours the same distance below "a" with the same
        // overlap. The choice must not depend on the order the compositor listed them.
        var tiles = [
            { address: "c", wsid: 1, x: 500, y: 300, w: 500, h: 200 },
            { address: "b", wsid: 1, x: 0, y: 300, w: 500, h: 200 },
            { address: "a", wsid: 1, x: 0, y: 0, w: 1000, h: 298 }
        ]
        compare(Logic.navigateWindows(tiles, 1, "a", "down", null), "b")
        compare(Logic.navigateWindows(tiles, 1, "b", "up", null), "a")
        compare(Logic.navigateWindows(tiles, 1, "c", "up", null), "a")
    }

    function test_cycleWindows_reading_order() {
        compare(Logic.cycleWindows(rows, 1, "", 1, null), "a")
        compare(Logic.cycleWindows(rows, 1, "a", 1, null), "b")
        compare(Logic.cycleWindows(rows, 1, "b", 1, null), "c")
    }
    // Distinguishes: a cycle that runs off the end instead of wrapping, in both directions.
    function test_cycleWindows_wraps() {
        compare(Logic.cycleWindows(rows, 1, "c", 1, null), "a")
        compare(Logic.cycleWindows(rows, 1, "a", -1, null), "c")
        compare(Logic.cycleWindows(rows, 1, "", -1, null), "c")
    }
    // Distinguishes: a cycle that ignores the workspace filter, or one that throws on an empty
    // workspace instead of reporting "no window".
    function test_cycleWindows_respects_the_workspace() {
        compare(Logic.cycleWindows(rows, 2, "", 1, null), "z")
        compare(Logic.cycleWindows(rows, 9, "", 1, null), "")
    }
    // Distinguishes: THE Ctrl+W bug this exists to prevent — a repeated close cycling back onto
    // a window whose close is still outstanding. With a skipped, the successor of a is b, never a.
    function test_cycleWindows_never_returns_a_skipped_address() {
        compare(Logic.cycleWindows(rows, 1, "a", 1, { a: true }), "b")
        compare(Logic.cycleWindows(rows, 1, "a", 1, { b: true }), "c")
        compare(Logic.cycleWindows(rows, 1, "a", 1, { a: true, b: true, c: true }), "")
    }
    // Distinguishes: a current address from another workspace treated as "not found" incorrectly
    // — it must restart at the first window, not return "".
    function test_cycleWindows_foreign_current_restarts() {
        compare(Logic.cycleWindows(rows, 1, "z", 1, null), "a")
    }
    // Distinguishes: wrap arithmetic that fails when step magnitude exceeds the list length.
    // With a three-item list, step = -5 must use normalized modulo, not the naive form.
    function test_cycleWindows_wrap_arithmetic_with_large_step() {
        compare(Logic.cycleWindows(rows, 1, "a", 5, null), "c")   // Forward wrap with large step
        compare(Logic.cycleWindows(rows, 1, "a", -5, null), "b")  // Backward wrap with large step
    }

    // ✎ 2026-09-18: a workspace target that names exactly one window IS that window, for Ctrl+W
    // only (docs/specs/2026-09-15-actions-design.md, addendum).
    // Distinguishes: a "lone window" that answers the first window of a busy workspace instead of
    // refusing — the difference between closing the one window you can see and closing whichever
    // of several happens to sort first.
    function test_loneWindow_answers_only_when_the_workspace_names_one() {
        compare(Logic.loneWindow(rows, 2, null), "z", "one window is unambiguous")
        compare(Logic.loneWindow(rows, 1, null), "", "three windows name none of them")
        compare(Logic.loneWindow(rows, 9, null), "", "an empty workspace")
        compare(Logic.loneWindow(rows, -1, null), "", "no workspace at all")
    }
    // Distinguishes: a count that includes windows already asked to close. Those tiles are drawn
    // dimmed and are not cycle stops, so "exactly one window" must mean exactly one the user has
    // not already closed — the same set cycleWindows skips, so the rule matches the screen.
    function test_loneWindow_skips_outstanding_closes() {
        compare(Logic.loneWindow(rows, 1, { a: true, b: true }), "c")
        compare(Logic.loneWindow(rows, 1, { a: true }), "", "b and c are both still live")
        compare(Logic.loneWindow(rows, 2, { z: true }), "", "nothing left to close")
    }

    // Distinguishes: a focus-steal event dropped from the set, which would leave the picker deaf
    // after that action (the Ctrl+W and SUPER+n reports both came from exactly this). And the one
    // event that must NOT be in the set: focusing the layer can itself emit an activewindow change,
    // so regrabbing on it would chase its own tail.
    function test_focusStealingEvent_covers_every_compositor_refocus() {
        verify(Logic.focusStealingEvent("closewindow"))
        verify(Logic.focusStealingEvent("workspacev2"))
        verify(Logic.focusStealingEvent("activespecialv2"))
        verify(Logic.focusStealingEvent("focusedmonv2"))
        verify(!Logic.focusStealingEvent("activewindowv2"), "would regrab in response to its own regrab")
        verify(!Logic.focusStealingEvent("openwindow"))
        verify(!Logic.focusStealingEvent("windowtitlev2"))
        verify(!Logic.focusStealingEvent(""))
    }

    // menuNavigate takes the ITEM LIST, not a count (docs/specs/2026-09-15-actions-design.md,
    // "The menu", addendum 2026-09-17: the separator needs the list to know what to skip).
    // `items(n)` builds n plain, non-separator rows; `sepItems(spec)` marks the `true` slots as
    // separators (no id).
    function items(n) { var a = []; for (var i = 0; i < n; i++) a.push({ id: "i" + i }); return a }
    function sepItems(spec) {
        return spec.map(function (isSep, i) { return isSep ? { separator: true } : { id: "i" + i } })
    }

    // Distinguishes: a menu highlight that does not wrap, or that starts anywhere but the ends.
    function test_menuNavigate() {
        var l = items(3)
        compare(Logic.menuNavigate(l, -1, 1), 0)
        compare(Logic.menuNavigate(l, -1, -1), 2)
        compare(Logic.menuNavigate(l, 2, 1), 0)
        compare(Logic.menuNavigate(l, 0, -1), 2)
        compare(Logic.menuNavigate([], -1, 1), -1)
    }
    // Distinguishes: wrap arithmetic that fails when step magnitude exceeds the count.
    // With a three-item menu, step = -5 must use normalized modulo, not the naive form.
    function test_menuNavigate_wrap_arithmetic_with_large_step() {
        var l = items(3)
        compare(Logic.menuNavigate(l, 0, 5), 2)   // Forward wrap with large step
        compare(Logic.menuNavigate(l, 0, -5), 1)  // Backward wrap with large step
    }
    // Distinguishes: a menuNavigate that does not skip a separator at all — the highlight would
    // land right on it. Stepping from either neighbour must reach past it to the far side.
    function test_menuNavigate_skips_a_separator_in_the_middle() {
        var l = sepItems([false, false, true, false])   // i0, i1, SEP, i3
        compare(Logic.menuNavigate(l, 1, 1), 3, "down from i1 must skip the separator at 2")
        compare(Logic.menuNavigate(l, 3, -1), 1, "up from i3 must skip the separator at 2")
    }
    // Distinguishes: wrap arithmetic that lands exactly on a separator sitting at the array's
    // edge — the case a plain modulo wrap (with no skip loop) hits first.
    function test_menuNavigate_never_wraps_onto_a_separator() {
        var lead = sepItems([true, false, false])        // SEP, i1, i2
        compare(Logic.menuNavigate(lead, 1, -1), 2, "wrap back from i1 must reach the LAST item, not the leading separator")
        compare(Logic.menuNavigate(lead, 2, 1), 1, "wrap forward from the last item must skip the leading separator")
        var trail = sepItems([false, false, true])        // i0, i1, SEP
        compare(Logic.menuNavigate(trail, 1, 1), 0, "wrap forward from i1 must skip the trailing separator")
        compare(Logic.menuNavigate(trail, 0, -1), 1, "wrap back from i0 must reach the last non-separator")
    }
    // Distinguishes: "from none" (-1) landing on a leading/trailing separator instead of stepping
    // past it to the first (down) or last (up) real row.
    function test_menuNavigate_from_none_skips_a_leading_or_trailing_separator() {
        compare(Logic.menuNavigate(sepItems([true, false]), -1, 1), 1, "down from none must skip a leading separator")
        compare(Logic.menuNavigate(sepItems([false, true]), -1, -1), 0, "up from none must skip a trailing separator")
    }
    // Distinguishes: an infinite loop (or a thrown error) when every item is a separator — a
    // degenerate case that must resolve to "no highlight" rather than hang or crash.
    function test_menuNavigate_all_separators_is_degenerate() {
        compare(Logic.menuNavigate([{ separator: true }], -1, 1), -1)
        compare(Logic.menuNavigate([{ separator: true }, { separator: true }], 0, 1), -1)
    }

    function ids(items) { return items.map(function (i) { return i.id }) }
    function win(o) {
        var base = { address: "0xA", floating: false, fullscreen: 0, workspaceId: 1 }
        for (var k in o) base[k] = o[k]
        return base
    }
    function box(o) {
        // windowCount 2 by default: the interesting default is a workspace that CAN offer Close
        // all, so a test that cares about the single-window rule has to say so explicitly.
        var base = { workspaceId: 1, monitorName: "eDP-1", occupied: true, windowCount: 2,
                     armed: false, placeholder: false, special: "", synthetic: false, active: true }
        for (var k in o) base[k] = o[k]
        return base
    }
    property var oneMon: [{ name: "eDP-1" }]
    property var twoMon: [{ name: "eDP-1" }, { name: "HDMI-A-1" }]

    // Distinguishes: a window menu whose ids name a toggle ("toggleFloat") rather than the state
    // to set. A stale snapshot activating a toggle does the opposite of its label; an explicit
    // state is at worst a no-op.
    function test_menuItems_window_ids_name_the_state_to_set() {
        compare(ids(Logic.menuItems({ kind: "window", address: "0xA" },
                                    { win: win({}), monitors: oneMon })),
                ["close", "float", "fullscreen"])
        compare(ids(Logic.menuItems({ kind: "window", address: "0xA" },
                                    { win: win({ floating: true, fullscreen: 2 }), monitors: oneMon })),
                ["close", "tile", "unfullscreen"])
    }
    // Distinguishes: "maximized" (mode 1) treated as not-fullscreen, which would offer to enter
    // fullscreen on a window that is already in one of the two modes.
    function test_menuItems_maximized_counts_as_fullscreen() {
        compare(ids(Logic.menuItems({ kind: "window", address: "0xA" },
                                    { win: win({ fullscreen: 1 }), monitors: oneMon })),
                ["close", "float", "unfullscreen"])
    }
    // Distinguishes: a menu built for a window the rebuild has dropped (closed, or hidden behind
    // a lock placeholder). An empty list is what dismisses the menu.
    function test_menuItems_without_a_window_is_empty() {
        compare(Logic.menuItems({ kind: "window", address: "0xA" }, { win: null, monitors: oneMon }).length, 0)
        compare(Logic.menuItems(null, { monitors: oneMon }).length, 0)
    }

    // ---- addendum 2026-09-17: a window's menu also carries its workspace's group -----------
    // Distinguishes (✎ 2026-09-18): Close all staying beside Close, where it was until the
    // 2026-09-18 addendum moved it into the workspace group — the row acts on every window on
    // the workspace, so it belongs below the line with the rest of them, not among the rows
    // that act on the one window the menu was opened on. Also: a menu missing the group
    // entirely when a box IS given.
    function test_menuItems_window_with_workspace_box_adds_the_group_with_closeAll_in_it() {
        compare(ids(Logic.menuItems({ kind: "window", address: "0xA" },
                                    { win: win({}), box: box({}), monitors: oneMon })),
                ["close", "float", "fullscreen", "separator", "lock", "closeAll"])
    }
    // Distinguishes: a separator item that is not marked `separator: true` (so a naive
    // implementation of Logic.menuNavigate treating it as an ordinary row would go undetected by
    // an id-only check), and Move/Swap missing from the group.
    function test_menuItems_window_group_carries_move_and_swap_too() {
        var out = Logic.menuItems({ kind: "window", address: "0xA" },
                                   { win: win({}), box: box({}), monitors: twoMon })
        compare(ids(out), ["close", "float", "fullscreen", "separator",
                           "lock", "move:HDMI-A-1", "swap:HDMI-A-1", "closeAll"])
        var sep = out[3]
        compare(sep.separator, true)
        verify(!sep.id || sep.id === "separator", "the separator must not double as an activatable row")
    }
    // Distinguishes: a window's own workspace box treated as the SELECTED workspace's box
    // instead — the addendum's whole point. window.workspaceId names where the group's rows
    // apply; ctx.box is what the caller (Overview.boxForWs(win.workspaceId)) must have looked up.
    function test_menuItems_window_group_reflects_its_OWN_workspace_not_a_different_one() {
        var out = Logic.menuItems({ kind: "window", address: "0xA" },
                                   { win: win({}), box: box({ armed: true }), monitors: oneMon })
        compare(ids(out), ["close", "float", "fullscreen", "separator", "unlock", "closeAll"],
                "the box passed in ctx is what must be reflected, armed or not")
    }
    // Distinguishes: hiding a group leaving a dangling separator with nothing under it — here by
    // construction Lock/Unlock is unconditional, so this also pins that the separator is added
    // if, and only if, the group is non-empty.
    function test_menuItems_window_without_a_workspace_box_has_no_group_or_separator() {
        var out = Logic.menuItems({ kind: "window", address: "0xA" },
                                   { win: win({}), box: null, monitors: oneMon })
        compare(ids(out), ["close", "float", "fullscreen"])
        verify(out.every(function (i) { return !i.separator }), "no box: no separator either")
    }
    // ✎ 2026-09-18. Distinguishes: Close all offered on a window whose workspace holds only that
    // window, where it is Close under a longer label and a confirmation dialog. This is the
    // ORDINARY case for a window menu (one window on a workspace is the common shape), so a
    // rule keyed on `occupied` — true for any workspace with a window at all — would leave it
    // showing almost everywhere it should not.
    function test_menuItems_window_group_has_no_closeAll_above_a_lone_window() {
        var out = Logic.menuItems({ kind: "window", address: "0xA" },
                                   { win: win({}), box: box({ windowCount: 1 }), monitors: oneMon })
        compare(ids(out), ["close", "float", "fullscreen", "separator", "lock"])
    }

    // Distinguishes: Move/Swap offered on a single-monitor machine, where they mean nothing.
    function test_menuItems_one_monitor_has_no_move_or_swap() {
        compare(ids(Logic.menuItems({ kind: "workspace", id: 1 }, { box: box({}), monitors: oneMon })),
                ["lock", "closeAll"])
    }
    // Distinguishes: Move naming the workspace's OWN monitor, and the documented item order.
    function test_menuItems_two_monitors_offer_the_other_one() {
        compare(ids(Logic.menuItems({ kind: "workspace", id: 1 }, { box: box({}), monitors: twoMon })),
                ["lock", "move:HDMI-A-1", "swap:HDMI-A-1", "closeAll"])
    }
    // Distinguishes: Swap offered on a hidden workspace. swap_monitors exchanges the monitors'
    // ACTIVE workspaces, so on a hidden one the item would act on a different workspace entirely.
    function test_menuItems_swap_needs_an_active_workspace() {
        compare(ids(Logic.menuItems({ kind: "workspace", id: 1 },
                                    { box: box({ active: false }), monitors: twoMon })),
                ["lock", "move:HDMI-A-1", "closeAll"])
    }
    // Distinguishes: Move offered on a workspace the compositor has never created, or on the
    // scratchpad — neither has a monitor to move between.
    function test_menuItems_synthetic_and_scratchpad_have_no_monitor_items() {
        compare(ids(Logic.menuItems({ kind: "workspace", id: 3 },
                                    { box: box({ synthetic: true, occupied: false, windowCount: 0,
                                                 active: false }), monitors: twoMon })),
                ["lock"])
        compare(ids(Logic.menuItems({ kind: "workspace", id: -2 },
                                    { box: box({ special: "scratchpad", active: false }), monitors: twoMon })),
                ["lock", "closeAll"])
    }
    // Distinguishes: "Close all windows" offered on an empty workspace.
    function test_menuItems_close_all_needs_windows() {
        compare(ids(Logic.menuItems({ kind: "workspace", id: 1 },
                                    { box: box({ occupied: false, windowCount: 0 }), monitors: oneMon })),
                ["lock"])
    }
    // ✎ 2026-09-18. Distinguishes: a rule keyed on "has any windows" rather than "has more than
    // one" — the well and badge menus must apply the same threshold the window menu does, since
    // both now build their rows from workspaceMenuRows. One window is Close, not Close all.
    function test_menuItems_close_all_needs_more_than_one_window() {
        compare(ids(Logic.menuItems({ kind: "workspace", id: 1 },
                                    { box: box({ windowCount: 1 }), monitors: oneMon })), ["lock"])
        compare(ids(Logic.menuItems({ kind: "workspace", id: 1 },
                                    { box: box({ windowCount: 2 }), monitors: oneMon })),
                ["lock", "closeAll"])
    }
    // ✎ 2026-09-18. Distinguishes: a box built before windowCount existed, or one whose count
    // never reached layout() — `undefined > 1` is false, so the row is hidden rather than
    // offered on a workspace whose size is unknown. The destructive row fails closed.
    function test_menuItems_close_all_hidden_when_the_count_is_missing() {
        var b = box({}); delete b.windowCount
        compare(ids(Logic.menuItems({ kind: "workspace", id: 1 }, { box: b, monitors: oneMon })),
                ["lock"])
    }
    // Distinguishes: a lock item whose label does not follow the armed state.
    function test_menuItems_lock_label_follows_the_armed_state() {
        var armed = Logic.menuItems({ kind: "workspace", id: 1 }, { box: box({ armed: true }), monitors: oneMon })
        compare(armed[0].id, "unlock"); compare(armed[0].label, "Unlock")
    }
    // Distinguishes: a monitor glyph chosen by position rather than connector name.
    function test_menuItems_monitor_glyph_follows_the_connector() {
        var items = Logic.menuItems({ kind: "workspace", id: 1 },
                                    { box: box({ monitorName: "HDMI-A-1", active: false }), monitors: twoMon })
        compare(items[1].id, "move:eDP-1")
        compare(items[1].glyph, Logic.monitorGlyph("eDP-1"))
        verify(Logic.monitorGlyph("eDP-1") !== Logic.monitorGlyph("HDMI-A-1"))
    }
    // Distinguishes: a monitor name reaching a Lua chunk unvalidated. The name is interpolated
    // into a quoted Lua string, so a quote or a brace in it must never get that far.
    function test_validMonitorName() {
        verify(Logic.validMonitorName("eDP-1"))
        verify(Logic.validMonitorName("HDMI-A-1"))
        verify(Logic.validMonitorName("DP-2.1"))
        verify(!Logic.validMonitorName('e" })) --'))
        verify(!Logic.validMonitorName("has space"))
        verify(!Logic.validMonitorName(""))
        verify(!Logic.validMonitorName(null))
    }
    // Distinguishes: a bad monitor name surviving into an item id, which would put it one
    // activation away from a chunk.
    function test_menuItems_drops_an_invalid_monitor_name() {
        compare(ids(Logic.menuItems({ kind: "workspace", id: 1 },
                                    { box: box({}), monitors: [{ name: "eDP-1" }, { name: 'bad" name' }] })),
                ["lock", "closeAll"])
    }
}
