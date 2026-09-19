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

    // Full width is what makes the attachment read: Omarchy's bar is edge-to-edge and flush
    // (Bar.qml:1027), so a card inset from the screen edges always looks like a separate object
    // hanging underneath rather than an extension of the bar.
    function test_the_card_spans_the_screen_exactly() {
        seed(26, 10)
        compare(view.testCard.x, 0, "flush with the left edge")
        compare(view.testCard.width, 1920, "and the right")
    }

    // Isolates the availCanvasW binding from the card's width. Wire only the card and the grid
    // still lays out for a 96px-margin canvas, leaving unused room inside a full-width card --
    // which the assertion above cannot see.
    function test_the_grid_uses_the_full_width() {
        seed(26, 10)
        verify(view.testFlick.contentWidth <= view.testFlick.width,
               "content " + view.testFlick.contentWidth + " must fit " + view.testFlick.width)
        verify(view.testFlick.contentWidth > 1700,
               "the grid must actually use the new room, got " + view.testFlick.contentWidth)
    }

    function test_the_card_squares_off_against_the_bar() {
        seed(26, 10)
        compare(view.testCard.radius, 0, "no rounded corners in bar mode")
        compare(view.testCard.border.width, 0, "the card's own border is off; the rule is a child")
    }

    // The bottom cap. Only bites on overflow -- the card is content-sized -- so the fixture
    // must genuinely overflow or this proves nothing.
    function test_a_tall_layout_stops_short_of_the_bottom_edge() {
        seed(26, 40)
        verify(view.testCanvas.implicitHeight > 1080 - 26 - Logic.screenMargin(1080),
               "fixture must overflow, got " + view.testCanvas.implicitHeight)
        compare(view.testCard.height, 1080 - 26 - Logic.screenMargin(1080), "the cap binds")
        verify(view.testFlick.contentHeight > view.testFlick.height, "a capped card still scrolls")
    }

    // The scrim must not dim the bar the card is supposed to be continuous with.
    function test_the_scrim_starts_below_the_bar() {
        seed(26, 10)
        compare(view.testScrim.y, 26, "the scrim begins where the bar ends")
    }

    // Two stacked 50% fills composite to 75%, and the result looks deliberate unless something
    // measures it. Sampled at x=5 -- inside card.pad, so left of the Flickable -- where the only
    // thing painted is the card's own background.
    //
    // Limitation, stated so nobody reads more into a pass than is there: the fixture rewrites
    // Color.bar.* to a literal, so this proves uniformity of the fill, NOT that the colour equals
    // the bar's. That claim is live-check only.
    function test_a_translucent_card_composites_to_a_single_fill() {
        seed(26, 10)
        // Breaks the colour binding deliberately: the fixture's literal is opaque, and an
        // opaque card cannot show the doubling this guards against.
        view.testCard.color = Qt.rgba(0.5, 0.5, 0.5, 0.5)
        wait(60)
        var img = grabImage(view.testCard)
        var top = img.pixel(5, 3)
        var mid = img.pixel(5, 300)
        verify(Qt.colorEqual(top, mid),
               "the top edge must be the same fill as the body, got " + top + " vs " + mid)
    }
}
