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

    // Distinguishes: open() not installing, or installing without syncing the loaded set.
    function test_open_installs_then_syncs_the_loaded_set() {
        verify(installs() >= 1, "install dispatched")
        verify(syncs().length >= 1, "sync dispatched after the file loaded")
        verify(lastSync().indexOf("local ARMED = {}") >= 0)
        verify(cmds().indexOf(lastSync()) > cmds().indexOf(cmds().filter(function (c) { return c.indexOf("omyview-lock-layer") >= 0 })[0]), "install before sync")
    }
    // Distinguishes: a sync dispatched while the locks file is still unresolved (would disable
    // rules the compositor holds). The view is created WITHOUT loadArmed().
    function test_no_sync_before_the_locks_file_has_loaded() {
        var v = createTemporaryObject(overview, tc); v.motion.scale = 0; seed(v)
        v.open(); wait(400)
        var s = v.compositor.commands.filter(function (c) { return c.indexOf("local ARMED = {") >= 0 })
        compare(s.length, 0, "no sync while armed is unresolved")
        verify(v.compositor.commands.some(function (c) { return c.indexOf("omyview-lock-layer") >= 0 }), "but install did run")
        ctrlLOn(v)
        compare(v.testLocks.writes.length, 0, "toggle is a no-op while unresolved")
        v.testLocks.loadArmed(["3"])
        var s2 = v.compositor.commands.filter(function (c) { return c.indexOf("local ARMED = {") >= 0 })
        compare(s2.length, 1, "the load itself triggers the sync"); verify(s2[0].indexOf('"3"') >= 0)
        v.close()
    }
    function ctrlLOn(v) { keyClick("l", Qt.ControlModifier) }
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
    // Distinguishes: the hint not advertising the key.
    function test_hint_mentions_ctrl_l() {
        var hints = view.testHintModel, found = false
        for (var i = 0; i < hints.length; i++) if (hints[i].k === "ctrl+l") found = true
        verify(found)
    }
}
