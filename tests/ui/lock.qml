import QtQuick
import QtTest

TestCase {
    id: tc
    name: "Lock"
    when: windowShown
    width: 1200; height: 800; visible: true
    property var view
    property var mon
    property var screenObj
    readonly property int scratchHyprId: -73
    Component { id: overview; Overview {} }
    // The monitor is a QtObject, not a plain JS object, so `lastIpcObject` is a real QML property:
    // the share-time reminder frame binds to that snapshot, and a test replacing it (what
    // `Hyprland.refreshMonitors()` does for real) must re-evaluate the binding.
    Component {
        id: monitorStub
        QtObject {
            property string name: "TEST"
            property int x: 0
            property int y: 1440
            property int width: 1920
            property int height: 1080
            property real scale: 1
            property var lastIpcObject: null
        }
    }
    // Stands in for a Quickshell ShellScreen. Deliberately NOT the monitor's pixel size, so a
    // strip sized from the wrong object is visible in the numbers.
    Component {
        id: screenStub
        QtObject { property string name: "TEST"; property int width: 1600; property int height: 900 }
    }

    function client(addr, cls, title, x, floating) {
        return { address: addr, at: [x, 1500], size: [500, 400], floating: !!floating,
                 title: title, "class": cls, fullscreen: 0 }
    }
    function wsRow(id, clients, name) {
        return { id: id, name: name === undefined ? String(id) : name, monitor: mon,
                 toplevels: { values: clients.map(function (c) { return { lastIpcObject: c } }) } }
    }
    // A monitor IPC snapshot in Hyprland's own shape: `specialWorkspace` is always present and
    // reports `{ id: 0, name: "" }` when none is open (verified on 0.56.2).
    function ipc(activeId, specialName) {
        return { reserved: [0, 26, 0, 0], transform: 0,
                 activeWorkspace: { id: activeId, name: String(activeId) },
                 specialWorkspace: { id: specialName ? -98 : 0, name: specialName || "" } }
    }
    function seed(v) {
        mon = createTemporaryObject(monitorStub, tc)
        mon.lastIpcObject = ipc(1, "")
        screenObj = createTemporaryObject(screenStub, tc)
        v.compositor.monitors = { values: [mon] }
        v.compositor.focusedMonitor = mon
        v.compositor.focusedWorkspace = { id: 1 }
        v.compositor.workspaces = { values: [
            wsRow(1, [client("0xA", "chromium", "Chromium", 100, false)]),
            wsRow(2, [client("0xB", "Slack", "Slack", 100, true)]),
            wsRow(scratchHyprId, [client("0xS", "Bitwarden", "Bitwarden", 900, true)], "special:scratchpad") ] }
        v.testScreens = [screenObj]
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
    // "omyview_lock" appears in both the install and sync chunks (both touch the shared _G
    // table); "local ARMED" is unique to sync, so excluding it isolates the install dispatches.
    function installs() {
        return cmds().filter(function (c) { return c.indexOf("omyview_lock") >= 0 && c.indexOf("local ARMED") < 0 }).length
    }
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
            if (c[i].indexOf("omyview_lock") >= 0 && c[i].indexOf("local ARMED") < 0) { installs++; if (installIdx < 0) installIdx = i }
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
        verify(v.compositor.commands.some(function (c) { return c.indexOf("omyview_lock") >= 0 && c.indexOf("local ARMED") < 0 }),
               "but install did run")
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
    // Distinguishes: the write landing before the sync (the compositor's enforcement would then
    // wait on disk) from the spec's ordering — memory, then sync, then write.
    function test_ctrl_l_syncs_before_it_writes() {
        ctrlL()
        compare(view.testLocks.writeAt.length, 1)
        compare(view.testLocks.writeAt[0], cmds().length, "the write happened after the last sync")
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
    // Distinguishes: an armed tile (outside a share) still trying a live capture, which Hyprland
    // answers with its "permission denied" texture instead of the window — armed must fall back
    // to the icon on its own, not only once the box becomes a placeholder.
    function test_armed_box_tiles_fall_back_to_icons() {
        compare(tileOf("0xA").capMode, "live")
        ctrlL()                                        // arms ws 1
        compare(tileOf("0xA").capMode, "icon")
        compare(tileOf("0xB").capMode, "live", "unarmed ws 2 unaffected")
        ctrlL()                                        // disarms ws 1
        compare(tileOf("0xA").capMode, "live")
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
    // Distinguishes: a placeholder box that stops being a jump target (Enter or a click on the
    // well must still switch to the workspace — the lock hides content, never navigation).
    function test_placeholder_box_still_jumps_on_enter_and_click() {
        ctrlL()                                        // arm ws 1 (selected)
        view.testLocks.setSharing(true)
        compare(boxOf(1).placeholder, true)
        var before = cmds().length
        keyClick(Qt.Key_Return)
        compare(cmds().length, before + 1)
        verify(cmds()[before].indexOf('workspace = "1"') >= 0, "Enter jumps, got: " + cmds()[before])
        compare(view.opened, false)
        view.open(); wait(400)
        view.testLocks.setSharing(true)
        var b = boxOf(1), p = view.testCanvas.mapToItem(tc, b.x + b.w / 2, b.y + b.h / 2)
        before = cmds().length
        mouseClick(tc, p.x, p.y, Qt.LeftButton)
        compare(cmds().length, before + 1)
        verify(cmds()[before].indexOf('workspace = "1"') >= 0, "click jumps, got: " + cmds()[before])
        compare(view.opened, false)
    }
    // ---- Share-time reminder frame (docs/specs/2026-09-12-lock-design.md, addendum) ----------
    // One LockFrame per screen, four strips each. The fixture instantiates them exactly like the
    // shell does (`Variants`/`Repeater` over the screen list), so a missing instance shows up here
    // as "no lockFrame instance" rather than a silently absent cue.
    function strip(name) {
        var ch = view.children, frames = 0, found = null
        for (var i = 0; i < ch.length; i++) {
            if (ch[i].objectName !== "lockFrame") continue
            frames++
            var sc = ch[i].children
            for (var j = 0; j < sc.length; j++) if (sc[j].objectName === name) found = sc[j]
        }
        compare(frames, 1, "exactly one lockFrame instance for the one screen")
        verify(found !== null, "no strip named " + name)
        return found
    }
    function fillOf(name) {
        var ch = strip(name).children
        for (var i = 0; i < ch.length; i++) if (ch[i].objectName === "lockFrameFill") return ch[i]
        fail("no fill rectangle in " + name)
    }
    // Distinguishes: a frame that follows the armed flag alone (it would sit on screen whenever a
    // workspace is armed, share or no share), and one that never appears at all.
    function test_frame_only_while_sharing_an_armed_workspace() {
        compare(strip("lockFrameTop").visible, false, "nothing armed, nothing shared")
        ctrlL()                                        // arms ws 1, the workspace this monitor shows
        compare(strip("lockFrameTop").visible, false, "armed, but no share is running")
        view.testLocks.setSharing(true)
        compare(strip("lockFrameTop").visible, true)
        compare(strip("lockFrameBottom").visible, true)
        compare(strip("lockFrameLeft").visible, true)
        compare(strip("lockFrameRight").visible, true)
        view.testLocks.setSharing(false)
        compare(strip("lockFrameTop").visible, false, "gone when the share ends")
    }
    // Distinguishes: a frame keyed to "some workspace is armed" rather than to the workspace this
    // monitor is actually showing. The positive control moves the monitor onto the armed one.
    function test_frame_hidden_for_an_unarmed_workspace_on_the_same_monitor() {
        keyClick(Qt.Key_Right)                         // select ws 2
        compare(view.selectedId, 2)
        ctrlL()                                        // arm ws 2; the monitor still shows ws 1
        view.testLocks.setSharing(true)
        compare(strip("lockFrameTop").visible, false, "ws 2 armed, ws 1 shown")
        mon.lastIpcObject = ipc(2, "")                 // the monitor switches to ws 2
        compare(strip("lockFrameTop").visible, true)
    }
    // Distinguishes: a frame read off the monitor's ACTIVE workspace while a special workspace
    // covers it (it would follow the workspace hidden underneath the scratchpad), and a
    // special-closed payload (`activespecialv2>>,,TEST`) that leaves the frame up.
    function test_frame_follows_an_open_special_workspace() {
        keyClick("s", Qt.ControlModifier)              // show the scratchpad row
        keyClick(Qt.Key_Down)
        compare(view.selectedId, -2)
        ctrlL()                                        // arm special:scratchpad
        view.testLocks.setSharing(true)
        compare(strip("lockFrameTop").visible, false, "armed, but the scratchpad is not up")
        mon.lastIpcObject = ipc(1, "special:scratchpad")
        view.compositor.rawEvent({ name: "activespecialv2", data: "-98,special:scratchpad,TEST" })
        compare(strip("lockFrameTop").visible, true, "up on this monitor: framed")
        mon.lastIpcObject = ipc(1, "")                 // closed again; ws 1 underneath is unarmed
        view.compositor.rawEvent({ name: "activespecialv2", data: ",,TEST" })
        compare(strip("lockFrameTop").visible, false)
    }
    // Distinguishes: strips that hard-code the default thickness/colour instead of reading the
    // config, and an alpha left at the end of the hex string (Qt reads `#rrggbbaa` as `#aarrggbb`,
    // so `rgba(3355ff80)` passed through unchanged would render as an opaque near-black).
    // The side strips run the full height and the top/bottom ones are inset by that width, so
    // every corner is painted exactly once — a doubled corner would read darker on a translucent
    // colour. The PAINTED rectangle is what `lockBorderSize` promises; the surface around it is
    // one logical pixel bigger (see the outset test below).
    function test_frame_thickness_and_colour_follow_the_config() {
        view.testConfig.lockBorder = "rgba(3355ff80)"
        view.testConfig.lockBorderSize = 4
        ctrlL(); view.testLocks.setSharing(true)
        compare(fillOf("lockFrameTop").height, 4)
        compare(fillOf("lockFrameBottom").height, 4)
        compare(fillOf("lockFrameLeft").width, 4)
        compare(fillOf("lockFrameRight").width, 4)
        compare(strip("lockFrameLeft").height, screenObj.height, "the side strips span the screen")
        compare(strip("lockFrameTop").width, screenObj.width - 8, "inset by the side strips")
        compare(fillOf("lockFrameTop").color, Qt.color("#803355ff"), "alpha moved to the front")
    }
    // The `no_screen_share` blanking box that hides a strip from every capture covers WHOLE DEVICE
    // pixels, so a surface whose logical size equals the paint leaks on a fractionally scaled
    // monitor: 6 logical px at scale 1.25 is 7.5 device px — 7 rows blanked, 8 painted, which is
    // the one-device-pixel hairline round 4's live capture measured (top band mean 0.0527). Each
    // strip's SURFACE is therefore one logical px thicker than its PAINT, with the extra pixel on
    // the inner side, so the blanked box spans floor((t+1)·s) ≥ ceil(t·s) device px from the edge
    // at any scale s ≥ 1 and the paint is strictly inside it however the rounding falls.
    // Distinguishes: the outset regressing (surface == paint: the hairline is back), the paint
    // growing with the surface (a thicker frame than configured), and an outset put on the OUTER
    // side, which would push the paint one pixel off the screen edge instead of covering it.
    function test_each_strip_surface_outsets_its_paint_by_one_logical_pixel() {
        view.testConfig.lockBorderSize = 4
        ctrlL(); view.testLocks.setSharing(true)
        compare(strip("lockFrameTop").height, 5, "top surface: paint + one px")
        compare(fillOf("lockFrameTop").height, 4, "top paint")
        compare(fillOf("lockFrameTop").y, 0, "the paint hugs the screen edge; the outset is inside it")
        compare(strip("lockFrameBottom").height, 5, "bottom surface")
        compare(fillOf("lockFrameBottom").height, 4, "bottom paint")
        compare(fillOf("lockFrameBottom").y, 1, "mirrored: the paint hugs the bottom edge")
        compare(strip("lockFrameLeft").width, 5, "left surface")
        compare(fillOf("lockFrameLeft").width, 4, "left paint")
        compare(fillOf("lockFrameLeft").x, 0, "the paint hugs the left edge")
        compare(strip("lockFrameRight").width, 5, "right surface")
        compare(fillOf("lockFrameRight").width, 4, "right paint")
        compare(fillOf("lockFrameRight").x, 1, "mirrored: the paint hugs the right edge")
    }
    // Distinguishes: a size of 0 drawing hairline strips (or full-screen ones) instead of
    // disabling the cue, which is what the documented `lockBorderSize: 0` promises.
    function test_frame_size_zero_hides_it() {
        ctrlL(); view.testLocks.setSharing(true)
        compare(strip("lockFrameTop").visible, true)
        view.testConfig.lockBorderSize = 0
        compare(strip("lockFrameTop").visible, false)
        compare(strip("lockFrameLeft").visible, false)
    }
    // `lastIpcObject` is a snapshot, so the frame is only right if the events that can move a
    // workspace between monitors ask for a fresh one. Distinguishes: no refresh at all (the frame
    // would lag a workspace switch until something else happened to refresh) and a refresh on
    // every raw event (an IPC round trip per window title change).
    function test_monitor_snapshot_refreshes_only_on_the_events_that_can_change_it() {
        var before = view.compositor.monitorRefreshes
        view.compositor.rawEvent({ name: "workspacev2", data: "2,2" })
        compare(view.compositor.monitorRefreshes, before + 1, "a workspace change refreshes once")
        view.compositor.rawEvent({ name: "windowtitlev2", data: "0xA,Some title" })
        compare(view.compositor.monitorRefreshes, before + 1, "an unrelated event does not")
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
