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
