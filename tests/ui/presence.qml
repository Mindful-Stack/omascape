import QtQuick
import QtTest
// NOT "../logic.js". prepare.py writes logic.js into the fixture root beside the copied suite
// (prepare.py:129), so the parent directory is /tmp and the import fails with
// `Script file:///tmp/logic.js unavailable`. The flat form is what prepare.py's own config stub
// uses (prepare.py:203). This suite is the FIRST UI suite to import logic.js, which is why the
// path had never been exercised.
import "logic.js" as Logic

// Offscreen UI suite for the card-presence spec (docs/specs/2026-09-18-card-presence-design.md).
// The fixture (tests/ui/prepare.py) runs the real Overview with the compositor replaced by a
// stub, so buildInput(), Logic.layout() and the card's own sizing bindings are production code
// here. That is the entire point of this suite: Logic.screenMargin() is unit-tested in
// tests/tst_layout.qml and proves nothing about whether Overview.qml actually uses it.
TestCase {
    id: tc
    name: "Presence"
    when: windowShown
    width: 1920; height: 1080; visible: true
    property var view

    Component { id: overview; Overview {} }

    function client(addr, cls, x) {
        return { address: addr, at: [x, 1500], size: [400, 400], floating: false,
                 title: cls, "class": cls, fullscreen: 0 }
    }
    function wsRow(id, monitor, clients) {
        return { id: id, monitor: monitor,
                 toplevels: { values: clients.map(function (c) { return { lastIpcObject: c } }) } }
    }
    function makeMon(name, y) {
        return { name: name, x: 0, y: y, width: 1920, height: 1080, scale: 1,
                 lastIpcObject: { reserved: [0, 26, 0, 0], transform: 0,
                                  activeWorkspace: { id: 1 }, specialWorkspace: { id: 0, name: "" } } }
    }

    // `mons` is a list of monitors; each gets `perMon` workspaces, numbered consecutively.
    // The panel is sized BEFORE open() so the first rebuild already sees the real width:
    // availCanvasW is what feeds Logic.layout's availW, and open() rebuilds once immediately.
    // panelW/panelH default to 1920x1080; the width-cap test overrides them.
    function seed(mons, perMon, panelW, panelH) {
        view = createTemporaryObject(overview, tc)
        verify(view)
        view.testPanel.width = panelW === undefined ? 1920 : panelW
        view.testPanel.height = panelH === undefined ? 1080 : panelH
        var wss = [], id = 1
        for (var m = 0; m < mons.length; m++)
            for (var k = 0; k < perMon; k++, id++)
                wss.push(wsRow(id, mons[m], id === 1 ? [client("0xA", "alpha", 100)] : []))
        view.compositor.monitors = { values: mons }
        view.compositor.focusedMonitor = mons[0]
        view.compositor.focusedWorkspace = { id: 1 }
        view.compositor.workspaces = { values: wss }
        view.open()
        wait(120)
    }

    // THE regression. On the pre-fix code the card is 1900 wide on a 1920 panel: 10 px of air.
    function test_the_card_keeps_a_real_margin_from_the_screen_edge() {
        seed([makeMon("eDP-1", 0)], 5)
        var margin = Logic.screenMargin(1920)
        compare(margin, 96, "guard: the suite's arithmetic assumes a 96 px margin")
        verify(view.testCard.width <= 1920 - 2 * margin,
               "card is " + view.testCard.width + ", must be <= " + (1920 - 2 * margin))
    }

    // Isolates the availCanvasW binding from the maxCardW one. If only the CARD cap learned
    // about the margin, cw stays 372, the canvas stays 1876, and the card clamps to 1728 — so
    // the assertion above would pass while the grid scrolls sideways on a screen with 195 px
    // of unused room. This is the only assertion that can tell those two states apart.
    function test_the_grid_fits_without_scrolling_sideways() {
        seed([makeMon("eDP-1", 0)], 5)
        verify(view.testFlick.contentWidth <= view.testFlick.width,
               "content " + view.testFlick.contentWidth + " must fit viewport " + view.testFlick.width)
    }

    // maxCardW's ONLY coverage. The two tests above cannot reach it: canvas.implicitWidth is
    // bounded by availCanvasW, which is itself maxCardW - 2*pad, so the width cap can never bind
    // from grid width alone — leave maxCardW at its old `- 16` and both assertions above still
    // pass (verified by review, 2026-09-18). The one thing that CAN push the card past the cap
    // is the hint row, which has its own implicitWidth and is deliberately allowed to widen a
    // narrow card so the eight key hints are not clipped.
    //
    // 520 is a starting point, not a measured constant: it assumes the hint row is wider than a
    // 3-column grid at this size. The precondition below is what makes the test honest — if the
    // hints do not actually exceed the canvas, this test proves nothing and says so, rather than
    // passing for the wrong reason. If it trips, lower the panel width until they do.
    function test_the_card_width_cap_binds_and_still_respects_the_margin() {
        var panelW = 520
        seed([makeMon("eDP-1", 0)], 5, panelW, 1080)
        var margin = Logic.screenMargin(panelW)          // max(16, 26) = 26
        // Fixture precondition: the cap path must genuinely be the one under test. testHintRow is
        // the first hint tier (prepare.py:88); with hintsExpanded false the Column's implicitWidth
        // is that row's, so it is the right proxy for what pushes card.implicitWidth.
        verify(view.testHintRow.implicitWidth > view.testCanvas.implicitWidth,
               "hints (" + view.testHintRow.implicitWidth + ") must exceed canvas ("
               + view.testCanvas.implicitWidth + ") or this test exercises nothing")
        // The margin claim…
        verify(view.testCard.width <= panelW - 2 * margin,
               "card is " + view.testCard.width + ", must be <= " + (panelW - 2 * margin))
        // …and the discriminator: the card must sit EXACTLY on the cap. With maxCardW left at
        // `panel.width - 16` the card would be 504 here, not 468.
        compare(view.testCard.width, panelW - 2 * margin, "maxCardW must be what is binding")
    }

    // The vertical margin's only coverage. maxCardH does not bind in ordinary layouts, so an
    // unwired height binding would go unnoticed until someone docked a third monitor.
    function test_a_tall_layout_respects_the_vertical_margin() {
        seed([makeMon("eDP-1", 0), makeMon("HDMI-A-1", 1080), makeMon("DP-1", 2160)], 10)
        // Fixture precondition: this case is worthless unless the content genuinely overflows.
        // Three monitors x 10 workspaces is two sub-rows each; if a params change ever made that
        // fit, the assertions below would pass without exercising the cap at all.
        verify(view.testCanvas.implicitHeight > 1080 - 2 * Logic.screenMargin(1080),
               "fixture must produce a layout taller than the cap, got " + view.testCanvas.implicitHeight)
        verify(view.testCard.height <= 1080 - 2 * Logic.screenMargin(1080),
               "card is " + view.testCard.height + ", must be <= " + (1080 - 2 * Logic.screenMargin(1080)))
        verify(view.testFlick.contentHeight > view.testFlick.height,
               "a capped card must still scroll, not clip")
    }
}
