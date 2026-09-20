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
    // the query, and only then closes (Overview.qml:2150-2153).
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
}
