import QtQuick
import QtTest

TestCase {
    id: tc
    name: "Lock"
    when: windowShown
    width: 1200; height: 800; visible: true
    property var view
    property var mon
    readonly property int scratchHyprId: -73
    Component { id: overview; Overview {} }

    function client(addr, cls, title, x, floating) {
        return { address: addr, at: [x, 1500], size: [500, 400], floating: !!floating,
                 title: title, "class": cls, fullscreen: 0 }
    }
    function wsRow(id, clients, name) {
        return { id: id, name: name === undefined ? String(id) : name, monitor: mon,
                 toplevels: { values: clients.map(function (c) { return { lastIpcObject: c } }) } }
    }
    function seed(v) {
        mon = { name: "TEST", x: 0, y: 1440, width: 1920, height: 1080,
                scale: 1, lastIpcObject: { reserved: [0, 26, 0, 0], transform: 0 } }
        v.compositor.monitors = { values: [mon] }
        v.compositor.focusedMonitor = mon
        v.compositor.focusedWorkspace = { id: 1 }
        v.compositor.workspaces = { values: [
            wsRow(1, [client("0xA", "chromium", "Chromium", 100, false)]),
            wsRow(2, [client("0xB", "Slack", "Slack", 100, true)]),
            wsRow(scratchHyprId, [client("0xS", "Bitwarden", "Bitwarden", 900, true)], "special:scratchpad") ] }
    }
    function init() {
        view = createTemporaryObject(overview, tc)
        verify(view !== null)
        view.motion.scale = 0
        seed(view)
        view.testLocks.loadArmed([])       // the file has loaded: empty set
        view.open()
        wait(400)
    }
    function cleanup() { view.close() }
    function cmds() { return view.compositor.commands }
    function installs() { return cmds().filter(function (c) { return c.indexOf("omyview-lock-layer") >= 0 }).length }
    function syncs() { return cmds().filter(function (c) { return c.indexOf("local ARMED = {") >= 0 }) }
    function lastSync() { var s = syncs(); return s.length ? s[s.length - 1] : "" }
    function boxOf(wsId) {
        for (var i = 0; i < view.boxes.length; i++) if (view.boxes[i].workspaceId === wsId) return view.boxes[i]
        return null
    }
    function row(addr) {
        for (var i = 0; i < view.testModel.count; i++)
            if (view.testModel.get(i).address === addr) return view.testModel.get(i)
        return null
    }
    function type(s) { for (var i = 0; i < s.length; i++) keyClick(s.charAt(i)) }
    function ctrlL() { keyClick("l", Qt.ControlModifier) }

    // Distinguishes: open() not installing, installing without syncing the loaded set, or
    // installing/syncing more than once per open(). Builds its own view (rather than reusing
    // `view` from init()) so `commands` can be reset right after the stub "loads" and before
    // open() runs — pinning exactly what open() itself dispatches, nothing from
    // Component.onCompleted or loadArmed().
    function test_open_installs_then_syncs_the_loaded_set() {
        var v = createTemporaryObject(overview, tc); v.motion.scale = 0; seed(v)
        v.testLocks.loadArmed([])          // the file has loaded: empty set
        v.compositor.commands = []         // drop Component.onCompleted's install and loadArmed's sync
        v.open(); wait(400)
        var c = v.compositor.commands
        var installIdx = -1, syncIdx = -1, installs = 0, syncs = 0
        for (var i = 0; i < c.length; i++) {
            if (c[i].indexOf("omyview-lock-layer") >= 0) { installs++; if (installIdx < 0) installIdx = i }
            if (c[i].indexOf("local ARMED = {") >= 0) { syncs++; if (syncIdx < 0) syncIdx = i }
        }
        compare(installs, 1, "open() installs exactly once")
        compare(syncs, 1, "open() syncs exactly once")
        verify(c[syncIdx].indexOf("local ARMED = {}") >= 0, "the loaded (empty) set")
        verify(installIdx < syncIdx, "install before sync")
        v.close()
    }
    // Distinguishes: a sync dispatched while the locks file is still unresolved (would disable
    // rules the compositor holds). The view is created WITHOUT loadArmed().
    function test_no_sync_before_the_locks_file_has_loaded() {
        var v = createTemporaryObject(overview, tc); v.motion.scale = 0; seed(v)
        v.open(); wait(400)
        var s = v.compositor.commands.filter(function (c) { return c.indexOf("local ARMED = {") >= 0 })
        compare(s.length, 0, "no sync while armed is unresolved")
        verify(v.compositor.commands.some(function (c) { return c.indexOf("omyview-lock-layer") >= 0 }), "but install did run")
        // ctrlL() dispatches through whichever view last forced keyboard focus, which is `v`
        // here (its own open() ran a Qt.callLater(forceActiveFocus) after `view`'s did).
        ctrlL()
        compare(v.testLocks.writes.length, 0, "toggle is a no-op while unresolved")
        verify(v.compositor.commands.some(function (c) { return c.indexOf("locks file unreadable") >= 0 }),
               "the user is told why Ctrl+L did nothing")
        var warned = v.compositor.commands.filter(function (c) { return c.indexOf("locks file unreadable") >= 0 }).length
        ctrlL()
        compare(v.compositor.commands.filter(function (c) { return c.indexOf("locks file unreadable") >= 0 }).length,
                warned, "reported at most once per open")
        v.testLocks.loadArmed(["3"])
        var s2 = v.compositor.commands.filter(function (c) { return c.indexOf("local ARMED = {") >= 0 })
        compare(s2.length, 1, "the load itself triggers the sync"); verify(s2[0].indexOf('"3"') >= 0)
        v.close()
    }
    // Distinguishes: a reload echo (watchChanges/reload() re-emitting `loaded` with unchanged
    // content — our own atomic write reading back its own bytes, a stray watcher firing) being
    // treated as a real change and re-dispatching a sync (and, while open, re-rebuilding) for
    // nothing.
    function test_loadArmed_with_unchanged_content_does_not_resync() {
        var v = createTemporaryObject(overview, tc); v.motion.scale = 0; seed(v)
        v.testLocks.loadArmed(["3"])
        v.open(); wait(400)
        v.compositor.commands = []                  // drop everything open() itself dispatched
        v.testLocks.loadArmed(["3"])                 // identical content: an echo, not a change
        var syncs2 = v.compositor.commands.filter(function (c) { return c.indexOf("local ARMED = {") >= 0 })
        compare(syncs2.length, 0, "an unchanged reload must not re-sync")
        v.close()
    }
    // Distinguishes: Ctrl+L not writing, writing the wrong selector, or not syncing the new set.
    function test_ctrl_l_arms_and_disarms_the_selected_box() {
        keyClick(Qt.Key_Right)                         // ws 2
        compare(view.selectedId, 2)
        var before = syncs().length
        ctrlL()
        compare(view.testLocks.writes.length, 1); compare(JSON.parse(view.testLocks.writes[0]).armed, ["2"])
        compare(syncs().length, before + 1); verify(lastSync().indexOf('"2"') >= 0)
        compare(boxOf(2).armed, true)
        ctrlL()
        compare(JSON.parse(view.testLocks.writes[1]).armed, [])
        verify(lastSync().indexOf("local ARMED = {}") >= 0)
        compare(boxOf(2).armed, false)
    }
    // Distinguishes: the scratchpad armed by its (dynamic) id instead of its name.
    function test_ctrl_l_on_the_scratchpad_writes_its_name() {
        keyClick("s", Qt.ControlModifier)              // show the row
        keyClick(Qt.Key_Down)
        compare(view.selectedId, -2)
        ctrlL()
        compare(JSON.parse(view.testLocks.writes[0]).armed, ["special:scratchpad"])
        verify(lastSync().indexOf("-2") < 0 && lastSync().indexOf("-73") < 0)
    }
    // Distinguishes: a config reload not re-installing (globals are lost on reload).
    function test_configreloaded_reinstalls_and_resyncs() {
        var i = installs(), s = syncs().length
        view.compositor.rawEvent({ name: "configreloaded", data: "" })
        compare(installs(), i + 1); compare(syncs().length, s + 1)
        view.compositor.rawEvent({ name: "workspace", data: "2" })
        compare(installs(), i + 1, "other events do not reinstall")
    }
    // Distinguishes: a write failure blocking enforcement (the compositor must still be synced
    // from the in-memory set) or losing the in-memory change.
    function test_write_failure_keeps_memory_and_still_syncs() {
        view.testLocks.failWrites = true
        var before = syncs().length
        ctrlL()
        compare(view.testLocks.writeFailures, 1)
        compare(syncs().length, before + 1); verify(lastSync().indexOf('"1"') >= 0)
        compare(boxOf(1).armed, true)
    }
    // Distinguishes: a padded (empty, synthetic) workspace never carrying armed/placeholder
    // flags, so arming an empty workspace shows no badge.
    function test_padded_workspace_carries_armed_and_placeholder() {
        view.testConfig.workspaces = 10
        view.rebuild()
        var idx = -1
        for (var i = 0; i < view.boxes.length; i++) if (view.boxes[i].workspaceId === 7) idx = i
        verify(idx >= 0, "workspace 7 is padded into the layout")
        view.selectedIndex = idx
        ctrlL()
        compare(boxOf(7).armed, true)
        verify(view.testLocks.writes[0].indexOf('"7"') >= 0)
        // Pin the numeral term: an empty, armed-then-sharing box shows only the lock glyph,
        // never the big low-contrast numeral underneath it.
        view.testLocks.setSharing(true)
        compare(childNamed(boxItemOf(7), "lockGlyph").visible, true)
        compare(childNamed(boxItemOf(7), "wsNumeral").visible, false,
                "an empty armed box shows the glyph alone, never the numeral under it")
    }
    // Distinguishes: the hint not advertising the key.
    function test_hint_mentions_ctrl_l() {
        var hints = view.testHintModel, found = false
        for (var i = 0; i < hints.length; i++) if (hints[i].k === "ctrl+l") found = true
        verify(found)
    }
    // Distinguishes: an invalidFile notification firing again on a re-emit within the same
    // open (an echo), or never firing again after a fresh open.
    function test_invalid_file_notified_once_per_open() {
        view.testLocks.emitInvalid("bad json")
        view.testLocks.emitInvalid("bad json")
        compare(cmds().filter(function (c) { return c.indexOf("locks file ignored") >= 0 }).length, 1,
                "reported at most once per open")
        view.close(); view.open(); wait(400)
        view.testLocks.emitInvalid("bad json")
        compare(cmds().filter(function (c) { return c.indexOf("locks file ignored") >= 0 }).length, 2,
                "a fresh open can report again")
    }

    function childNamed(item, name) {
        var ch = item.children
        for (var i = 0; i < ch.length; i++) if (ch[i].objectName === name) return ch[i]
        return null
    }
    function canvasItems(name) {
        var out = [], ch = view.testCanvas.children
        for (var i = 0; i < ch.length; i++) if (ch[i].objectName === name) out.push(ch[i])
        return out
    }
    function boxItemOf(wsId) {
        var items = canvasItems("wsBox")
        for (var i = 0; i < items.length; i++) if (items[i].model.workspaceId === wsId) return items[i]
        return null
    }
    function badgeOf(wsId) {
        var items = canvasItems("wsBadge")
        for (var i = 0; i < items.length; i++) if (items[i].model.workspaceId === wsId) return items[i]
        return null
    }
    // Distinguishes: the badge not showing the lock, or showing it on unarmed boxes.
    function test_armed_box_shows_a_lock_badge_and_keeps_its_tiles() {
        ctrlL()                                        // arms ws 1
        verify(childNamed(badgeOf(1), "wsBadgeText").text.indexOf("\u{F033E}") >= 0, "lock glyph in the badge")
        verify(childNamed(badgeOf(2), "wsBadgeText").text.indexOf("\u{F033E}") < 0)
        verify(row("0xA") !== null, "not sharing: tiles stay")
        compare(childNamed(boxItemOf(1), "lockGlyph").visible, false)
    }
    // Distinguishes: a placeholder box still holding a tile (a live capture) or hiding the glyph.
    function test_share_turns_armed_boxes_into_placeholders() {
        ctrlL()
        view.testLocks.setSharing(true)
        compare(row("0xA"), null, "no tile on the placeholder box")
        verify(row("0xB") !== null, "unarmed box unaffected")
        compare(childNamed(boxItemOf(1), "lockGlyph").visible, true)
        compare(childNamed(boxItemOf(1), "wsNumeral").visible, false, "numeral hidden under the glyph")
        view.testLocks.setSharing(false)
        verify(row("0xA") !== null, "tiles return when the share ends")
        compare(childNamed(boxItemOf(1), "lockGlyph").visible, false)
    }
    // Distinguishes: find still matching a window on a placeholder box. Positive control first.
    function test_find_skips_placeholder_boxes_with_a_positive_control() {
        type("chromium"); compare(view.matches.length, 1)
        keyClick(Qt.Key_Escape)
        ctrlL()
        type("chromium"); compare(view.matches.length, 1, "armed but not sharing: still matches")
        view.testLocks.setSharing(true)
        compare(view.matches.length, 0, "placeholder: not in the input")
        view.testLocks.setSharing(false)
        compare(view.matches.length, 1, "back")
    }
    // Distinguishes: the selected match's box becoming a placeholder without the successor rule.
    // The overview stays open throughout — onSharingChanged only rebuilds while open, so a
    // close/reopen cycle would mask a broken successor rule behind a fresh, unrelated rebuild.
    function test_selected_match_on_a_box_that_becomes_a_placeholder_falls_to_the_successor() {
        var rows = view.compositor.workspaces.values
        rows[1].toplevels.values.push({ lastIpcObject: client("0xC", "chromium2", "Chromium 2", 700, false) })
        view.rebuild()
        type("chromium")
        compare(view.matches.length, 2); compare(view.selectedId, 1)
        keyClick(Qt.Key_Backspace, Qt.ControlModifier)   // clears the query; overview stays open
        compare(view.selectedId, 1, "restored to the pre-query selection")
        ctrlL()                                          // arms ws 1 (still selected)
        compare(boxOf(1).armed, true)
        type("chromium"); compare(view.selectedMatchAddress, "0xA")
        view.testLocks.setSharing(true)
        compare(view.matches.length, 1); compare(view.selectedMatchAddress, "0xC"); compare(view.selectedId, 2)
    }
    function tileOf(addr) {
        var ch = view.testCanvas.children
        for (var i = 0; i < ch.length; i++) if (ch[i].model && ch[i].model.address === addr) return ch[i]
        fail("no tile for " + addr)
    }
    function dragTo(addr, wsId) {
        var t = tileOf(addr), p = t.mapToItem(tc, t.width / 2, t.height / 2)
        var b = boxOf(wsId), goal = view.testCanvas.mapToItem(tc, b.x + b.w / 2, b.y + b.h / 2)
        mousePress(tc, p.x, p.y, Qt.LeftButton)
        mouseMove(tc, p.x + 12, p.y + 2, 20)
        mouseMove(tc, goal.x, goal.y, 20)
        mouseRelease(tc, goal.x, goal.y, Qt.LeftButton)
    }
    // Distinguishes: a drop onto a placeholder box creating an optimistic row (a live capture on
    // a box that must show none) or not dispatching the move.
    function test_drop_onto_a_placeholder_box_dispatches_but_keeps_no_tile() {
        keyClick(Qt.Key_Right); ctrlL()                // arm ws 2
        view.testLocks.setSharing(true)
        var before = cmds().length
        dragTo("0xA", 2)
        compare(cmds().length, before + 1)
        verify(cmds()[before].indexOf('workspace = "2"') >= 0)
        compare(row("0xA").wsid, 1, "no optimistic move of the row")
        compare(view.pendingMoves["0xA"], undefined, "no pending entry")
    }
    // Distinguishes: a pending drop's row surviving the box becoming a placeholder.
    function test_pending_drop_row_is_dropped_when_the_box_becomes_a_placeholder() {
        keyClick(Qt.Key_Right); ctrlL(); keyClick(Qt.Key_Left)   // arm ws 2, back on ws 1
        dragTo("0xA", 2)
        compare(row("0xA").wsid, 2, "optimistic row on ws 2 (not sharing yet)")
        verify(view.pendingMoves["0xA"] !== undefined)
        view.testLocks.setSharing(true)
        compare(view.pendingMoves["0xA"], undefined, "pending cleared")
        compare(row("0xA").wsid, 1, "row back on its authoritative workspace")
    }
    // Distinguishes: a grab in flight surviving its source box becoming a placeholder (the
    // dragged window itself is under the "no tiles on a placeholder box" rule too), instead of
    // being cancelled the same way rebuild() already cancels a drag on a window that closed.
    function test_drag_in_flight_from_a_box_that_becomes_a_placeholder_is_cancelled() {
        ctrlL()                                          // arms ws 1 (selected by default)
        compare(boxOf(1).armed, true)
        var t = tileOf("0xA"), p = t.mapToItem(tc, t.width / 2, t.height / 2)
        mousePress(tc, p.x, p.y, Qt.LeftButton)
        mouseMove(tc, p.x + 12, p.y + 2, 20)
        mouseMove(tc, p.x + 35, p.y + 20, 20)
        verify(view.draggingAddress !== "")
        var before = cmds().length
        view.testLocks.setSharing(true)
        compare(view.draggingAddress, "")
        compare(view.dragTile, null)
        compare(row("0xA"), null)
        mouseRelease(tc, p.x + 35, p.y + 20, Qt.LeftButton)
        compare(cmds().length, before, "no dispatch from the swallowed release")
    }
}
