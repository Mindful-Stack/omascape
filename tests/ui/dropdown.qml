import QtQuick
import QtTest
// NOT "../logic.js": prepare.py writes logic.js into the fixture root beside the copied suite,
// so the parent directory is /tmp and the import fails with `Script file:///tmp/logic.js
// unavailable`. The flat form is what prepare.py's own config stub uses.
import "logic.js" as Logic

// Offscreen UI suite for the bar drop-down (docs/specs/2026-09-19-bar-dropdown-design.md).
// The fixture runs the real Overview against a stubbed compositor, so buildInput(),
// Logic.layout() and every binding under test here is production code.
TestCase {
    id: tc
    name: "Dropdown"
    when: windowShown
    width: 1920; height: 1080; visible: true
    property var view
    property var screenA
    property var screenB

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

    // One monitor, `perMon` workspaces, bar reserving `top`. The panel is sized BEFORE open()
    // so the first rebuild already sees the real width.
    function seed(top, perMon, anchor) {
        view = createTemporaryObject(overview, tc)
        verify(view)
        screenA = createTemporaryObject(screenStub, tc, { name: "A" })
        view.testConfig.anchor = anchor === undefined ? "bar" : anchor
        view.testPanel.width = 1920
        view.testPanel.height = 1080
        var monA = monitor("A", 0, top)
        var wss = []
        for (var k = 1; k <= perMon; k++) wss.push({ id: k, monitor: monA, toplevels: { values: [] } })
        view.compositor.monitors = { values: [monA] }
        view.compositor.focusedMonitor = monA
        view.compositor.focusedWorkspace = { id: 1 }
        view.compositor.workspaces = { values: wss }
        view.testScreens = [screenA]
        view.open()
        wait(120)
    }

    function cleanup() { if (view) view.close() }

    function test_the_card_hangs_from_the_reserved_top_strip() {
        seed(26, 10)
        compare(view.testCard.y, 26, "the card's top edge meets the bar's bottom edge")
    }

    // The fallback. A side, bottom or hidden bar reserves nothing at the top, and the picker
    // must return to the centred card rather than anchoring to an edge with nothing on it.
    function test_no_top_reservation_falls_back_to_centred() {
        seed(0, 10)
        verify(!view.barMode, "barMode must be false with nothing reserved")
        verify(view.testCard.x > 0, "a centred card keeps a side margin, got x=" + view.testCard.x)
    }

    // The other half of `barMode`. The sibling test above seeds top=0, so reservedTop is 0
    // there regardless of anchor — it cannot tell "no bar" from "bar mode turned off", because
    // the reservedTop term alone already forces barMode false. This one seeds a REAL top
    // reservation (asserted as a precondition, so it can't pass by accidentally having nothing
    // reserved either) with the default "center" anchor, and pins that barMode still requires
    // the user to have opted in via config.anchor === "bar" — not just a bar being present.
    function test_a_reservation_alone_does_not_enable_bar_mode() {
        seed(26, 10, "center")
        compare(view.reservedTop, 26, "precondition: a real reservation must be present")
        verify(!view.barMode, "barMode must stay off without anchor: \"bar\", even with a real reservation")
        verify(view.testCard.x > 0, "a centred card keeps a side margin, got x=" + view.testCard.x)
    }
}
