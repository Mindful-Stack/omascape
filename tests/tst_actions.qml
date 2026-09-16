import QtQuick
import QtTest
import "../logic.js" as Logic

TestCase {
    name: "Actions"

    function cand(addr, x, y, w, h, z) { return { address: addr, x: x, y: y, w: w, h: h, z: z } }

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

    function tile(addr, ws, x, y) { return { address: addr, wsid: ws, x: x, y: y } }

    property var rows: [tile("b", 1, 200, 0), tile("a", 1, 0, 0), tile("c", 1, 0, 300), tile("z", 2, 0, 0)]
    // Reading order is y then x: "b" is to the right of "a" on the same row, "c" is below both.
    // Distinguishes: cycling in model order instead of reading order. The model here is
    // deliberately b,a,c — only a sorted implementation answers a,b,c.
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

    // Distinguishes: a menu highlight that does not wrap, or that starts anywhere but the ends.
    function test_menuNavigate() {
        compare(Logic.menuNavigate(3, -1, 1), 0)
        compare(Logic.menuNavigate(3, -1, -1), 2)
        compare(Logic.menuNavigate(3, 2, 1), 0)
        compare(Logic.menuNavigate(3, 0, -1), 2)
        compare(Logic.menuNavigate(0, -1, 1), -1)
    }
}
