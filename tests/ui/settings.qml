import QtQuick
import QtTest
// NOT "../logic.js": prepare.py writes logic.js into the fixture root beside the copied suite,
// so the parent directory is /tmp and the import fails with `Script file:///tmp/logic.js
// unavailable`. The flat form is what prepare.py's own config stub uses.
import "logic.js" as Logic

// Offscreen UI suite for the in-picker settings panel (docs/specs/2026-09-20-settings-panel-
// design.md). The fixture runs the real Overview against a stubbed compositor, exactly as
// dropdown.qml does -- the seed()/monitor()/screenStub trio below is copied verbatim from it,
// since it is the established fixture shape for this component.
TestCase {
    id: tc
    name: "Settings"
    when: windowShown
    width: 1920; height: 1080; visible: true
    property var view
    property var screenA

    Component { id: overview; Overview {} }
    // focusedScreen() hands one of these back and open() stores it as targetScreen; the fixture
    // resolves monitorFor() against compositor.monitors BY NAME, exactly as the real one does.
    Component {
        id: screenStub
        QtObject { property string name: ""; property int width: 1920; property int height: 1080 }
    }

    // `top` is the monitor's reserved TOP strip — the bar. 26 is Omarchy's default bar height
    // (Style.qml:342, size-horizontal).
    function monitor(name, y, top) {
        return { name: name, x: 0, y: y, width: 1920, height: 1080, scale: 1,
                 lastIpcObject: { reserved: [0, top, 0, 0], transform: 0,
                                  activeWorkspace: { id: 1 },
                                  specialWorkspace: { id: 0, name: "" } } }
    }

    // One monitor, 10 workspaces, no bar reservation -- this suite is about key routing, not
    // placement, so the plain centred card is enough.
    function seed() {
        view = createTemporaryObject(overview, tc)
        verify(view)
        screenA = createTemporaryObject(screenStub, tc, { name: "A" })
        view.testConfig.anchor = "center"
        view.testPanel.width = 1920
        view.testPanel.height = 1080
        var monA = monitor("A", 0, 26)
        var wss = []
        for (var k = 1; k <= 10; k++) wss.push({ id: k, monitor: monA, toplevels: { values: [] } })
        view.compositor.monitors = { values: [monA] }
        view.compositor.focusedMonitor = monA
        view.compositor.focusedWorkspace = { id: 1 }
        view.compositor.workspaces = { values: wss }
        view.testScreens = [screenA]
        view.open()
        wait(120)
    }

    function cleanup() { if (view) view.close() }

    function test_ctrl_comma_opens_the_panel() {
        seed()
        verify(!view.settingsOpen, "precondition: closed")
        keyClick(Qt.Key_Comma, Qt.ControlModifier)
        verify(view.settingsOpen, "ctrl+, opens it")
    }

    // THE interaction most likely to be got wrong. Esc must close the PANEL and leave the
    // picker up.
    function test_escape_closes_the_panel_not_the_picker() {
        seed()
        keyClick(Qt.Key_Comma, Qt.ControlModifier)
        verify(view.settingsOpen, "precondition: open")
        keyClick(Qt.Key_Escape)
        verify(!view.settingsOpen, "the panel closes")
        verify(view.opened, "and the picker is still up")
    }

    // ...and the companion, which stops the fix being "Esc never closes the picker". It must
    // first establish that no EARLIER branch owns Esc: today Esc clears the window cursor, then
    // the query, and only then closes (Overview.qml:2198-2202).
    function test_escape_still_closes_the_picker_with_no_panel() {
        seed()
        compare(view.cursorAddress, "", "precondition: no window cursor")
        compare(view.query, "", "precondition: no query")
        verify(!view.menuOpen, "precondition: no menu")
        verify(!view.confirmOpen, "precondition: no confirmation dialog")
        verify(!view.settingsOpen, "precondition: no panel")
        keyClick(Qt.Key_Escape)
        verify(!view.opened, "Esc still closes the picker")
    }

    // Esc's existing sequence must survive the new branch being added ahead of it.
    function test_escape_still_clears_the_query_before_closing() {
        seed()
        view.setQuery("fire")
        keyClick(Qt.Key_Escape)
        compare(view.query, "", "the query clears first")
        verify(view.opened, "without closing the picker")
    }

    // Esc-Esc must fully close: the panel, then the picker. The dismiss-key swallow exists to
    // stop a HELD Esc doing both at once, and it is easy to build so that it also eats the next
    // independent press — which needs a third press to close and feels broken.
    function test_two_separate_escapes_close_the_panel_then_the_picker() {
        seed()
        keyClick(Qt.Key_Comma, Qt.ControlModifier)
        verify(view.settingsOpen, "precondition: the panel is open")
        keyClick(Qt.Key_Escape)
        verify(!view.settingsOpen, "the first Esc closes the panel")
        verify(view.opened, "and leaves the picker up")
        keyClick(Qt.Key_Escape)
        verify(!view.opened, "a second, independent Esc closes the picker")
    }

    function test_arrows_move_and_cycle() {
        seed()
        keyClick(Qt.Key_Comma, Qt.ControlModifier)
        compare(view.settingsIndex, 0, "starts at the top")
        keyClick(Qt.Key_Down)
        compare(view.settingsIndex, 1, "down moves")
        keyClick(Qt.Key_Up)
        compare(view.settingsIndex, 0, "up moves back")
        var before = view.testConfig.writes.length
        keyClick(Qt.Key_Right)
        compare(view.testConfig.writes.length, before + 1, "right requests a change")
        // The panel's first row is `anchor`, whose cycle is center -> bar.
        compare(String(view.testConfig.writes[before]), "anchor=bar",
                "and asks for the NEXT value, not an arbitrary one")
    }

    // A non-editable row consumes its keys rather than falling through to the picker beneath.
    function test_a_non_editable_row_changes_nothing() {
        seed()
        keyClick(Qt.Key_Comma, Qt.ControlModifier)
        // lockBorder is last by SETTING_ORDER; step to it with real presses.
        for (var d = 0; d < view.settingsRows.length - 1; d++) keyClick(Qt.Key_Down)
        var before = view.testConfig.writes.length
        keyClick(Qt.Key_Right)
        compare(view.testConfig.writes.length, before, "no write is requested")
        verify(view.settingsOpen, "and the key did not escape to the picker")
    }

    // The panel does not open mid-search. Deliberate: a query has its own Esc semantics, and a
    // modal on top would give Esc three meanings. Fails against a ctrl+, that simply inherits
    // the chord branch's behaviour, which fires during a query like every other ctrl shortcut.
    function test_the_panel_does_not_open_during_a_search() {
        seed()
        view.setQuery("fire")
        keyClick(Qt.Key_Comma, Qt.ControlModifier)
        verify(!view.settingsOpen, "a query owns the screen; clear it first")
        compare(view.query, "fire", "and the chord did not disturb the query")
    }

    // A clamped stepper must not rewrite the file on every press.
    function test_a_clamped_stepper_writes_nothing() {
        seed()
        keyClick(Qt.Key_Comma, Qt.ControlModifier)
        // Navigate with real presses: `settingsIndex` is a read-back mirror now, not a
        // control, so writing it would move nothing. SETTING_ORDER puts workspaces at index 5.
        for (var d = 0; d < 5; d++) keyClick(Qt.Key_Down)
        for (var i = 0; i < 25; i++) keyClick(Qt.Key_Right)   // drive it to the 20 ceiling
        var atCeiling = view.testConfig.writes.length
        keyClick(Qt.Key_Right)
        compare(view.testConfig.writes.length, atCeiling,
                "at the ceiling a further press must write nothing")
    }

    // Two quick presses must produce two DIFFERENT values. This is the lost-update case: read
    // each next value off `config` -- which only updates when the watcher reloads -- and both
    // presses compute from the same stale number and request the same one twice.
    function test_two_quick_presses_do_not_collapse_into_one_value() {
        seed()
        keyClick(Qt.Key_Comma, Qt.ControlModifier)
        for (var d = 0; d < 5; d++) keyClick(Qt.Key_Down)   // workspaces, default 10
        var before = view.testConfig.writes.length
        keyClick(Qt.Key_Right)
        keyClick(Qt.Key_Right)                        // no reload in between: the stub never writes a file
        compare(view.testConfig.writes.length, before + 2, "both presses request a change")
        verify(String(view.testConfig.writes[before]) !== String(view.testConfig.writes[before + 1]),
               "and they must differ: got " + view.testConfig.writes[before]
               + " then " + view.testConfig.writes[before + 1])
        // The second write must carry the first change too, or a cancelled write loses it.
        verify(String(view.testConfig.writes[before + 1]).indexOf("workspaces") >= 0,
               "the second save still carries workspaces")
    }

    // Opening the panel aborts an in-flight peek: a modal and a peek are never both up.
    function test_opening_the_panel_aborts_a_peek() {
        seed()
        keyPress(Qt.Key_Space)
        wait(60)
        verify(view.peeking, "precondition: a peek is up")
        keyClick(Qt.Key_Comma, Qt.ControlModifier)
        verify(!view.peeking, "opening settings aborts it")
        keyRelease(Qt.Key_Space)
    }
}
