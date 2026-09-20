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
    function seed(top, perMon, anchor, panelW) {
        view = createTemporaryObject(overview, tc)
        verify(view)
        screenA = createTemporaryObject(screenStub, tc, { name: "A" })
        view.testConfig.anchor = anchor === undefined ? "bar" : anchor
        view.testPanel.width = panelW === undefined ? 1920 : panelW
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
        // implicitHeight, not height: `height` is the UNFURL's animated value in bar mode, and
        // the subject here is the resting size that maxCardH caps. Both are asserted -- the cap
        // binds, and the unfurl actually reaches it -- which is strictly more than the single
        // assertion this replaced, back when the two were always equal.
        var cap = 1080 - 26 - Logic.screenMargin(1080)
        compare(view.testCard.implicitHeight, cap, "the cap binds")
        wait(300)
        compare(view.testCard.height, cap, "and the unfurl opens all the way to it")
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

    // Every seed() above sets anchor ONCE before open() -- nothing flips the mode on an
    // already-open picker, which is exactly why a ternary pair that yields `undefined` for the
    // unused anchor (see Overview.qml) passed all of them: it survives its FIRST flip and only
    // corrupts on the second. `barMode` can flip live in practice -- hiding the bar while the
    // picker is open drops `reservedTop` to 0 -- and `card` is never recreated across
    // open()/close(), so a corrupt anchor stays corrupt for the rest of that picker's life,
    // including centred mode, the default every existing user is on. Two full cycles, because one
    // cycle alone can pass against a partially-broken implementation.
    function test_the_card_returns_to_centre_after_a_live_bar_mode_flip() {
        seed(26, 10, "center")
        var centredY = view.testCard.y
        verify(centredY > 0, "precondition: a centred card is not flush with the top")
        // 250ms clears the width/height Behavior on the card (motion.normal, ~160ms scaled) that
        // the mode switch also triggers -- unrelated to the anchor bug, but a short wait here
        // would flake on that settle time regardless of which anchor implementation is under test.
        for (var i = 0; i < 2; i++) {
            view.testConfig.anchor = "bar"
            wait(250)
            compare(view.testCard.y, 26, "cycle " + i + ": attaches to the bar")
            view.testConfig.anchor = "center"
            wait(250)
            compare(view.testCard.y, centredY, "cycle " + i + ": returns to centre")
        }
    }

    // Sampled DURING the animation, not at rest. At rest a scaled and an unscaled card are
    // identical, so an end-state assertion passes against exactly the bug it should catch.
    //
    // mapToItem gives the card's REAL rendered edges: it applies the full transform chain, so
    // this states the property (the card's painted bounds stay pinned to the screen edges) and
    // not the mechanism. A later switch to a vertical-only Scale transform would still pass;
    // reinstating the uniform `scale` property would not.
    //
    // enterAnim scales 0.96 -> 1 about the top CENTRE: transformOrigin changes the pivot but
    // not the fact that scaling is uniform, so on a 1920 panel the sides would travel 38.4px
    // inward on entrance and 19.2px on exit -- with a full-width card, visibly off both edges.
    function test_the_card_stays_pinned_to_the_screen_edges_while_animating() {
        view = createTemporaryObject(overview, tc)
        verify(view)
        screenA = createTemporaryObject(screenStub, tc, { name: "A" })
        // Stretch the entrance so sampling is not a race: durations are Math.round(200 * scale).
        view.motion.scale = 10
        view.testConfig.anchor = "bar"
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
        for (var i = 0; i < 4; i++) {
            wait(120)
            var l = view.testCard.mapToItem(view.testPanel, 0, 0).x
            var r = view.testCard.mapToItem(view.testPanel, view.testCard.width, 0).x
            fuzzyCompare(l, 0, 0.5, "left edge during entrance, sample " + i)
            fuzzyCompare(r, 1920, 0.5, "right edge during entrance, sample " + i)
        }
        view.close()
        for (var j = 0; j < 3; j++) {
            wait(120)
            var l2 = view.testCard.mapToItem(view.testPanel, 0, 0).x
            var r2 = view.testCard.mapToItem(view.testPanel, view.testCard.width, 0).x
            fuzzyCompare(l2, 0, 0.5, "left edge during exit, sample " + j)
            fuzzyCompare(r2, 1920, 0.5, "right edge during exit, sample " + j)
        }
    }

    // ...and the centred card must KEEP its scale entrance. Without this, "fix" the bug by
    // deleting the scale animation outright and every other test still passes.
    function test_the_centred_card_still_scales_on_entry() {
        view = createTemporaryObject(overview, tc)
        verify(view)
        screenA = createTemporaryObject(screenStub, tc, { name: "A" })
        view.motion.scale = 10
        view.testConfig.anchor = "center"
        view.testPanel.width = 1920
        view.testPanel.height = 1080
        var monA = monitor("A", 0, 26)
        view.compositor.monitors = { values: [monA] }
        view.compositor.focusedMonitor = monA
        view.compositor.focusedWorkspace = { id: 1 }
        view.compositor.workspaces = { values: [{ id: 1, monitor: monA, toplevels: { values: [] } }] }
        view.testScreens = [screenA]
        view.open()
        wait(120)
        verify(view.testCard.scale < 1,
               "the centred entrance still scales, got " + view.testCard.scale)
    }

    // The direction that stayed buggy under the mode-dependent-animation-values fix: flipping
    // INTO bar mode while the entrance is still running. A running animation's interpolation is
    // fixed at start and only re-reads its from/to on its next loop, so animating card.scale
    // directly kept riding the stale 0.96->1 trajectory after the flip, while width and the
    // anchors -- ordinary live bindings, ungated by the animation -- snapped to bar geometry
    // instantly: the exact edge-detachment this task exists to prevent, for the rest of that run.
    function test_the_card_stays_pinned_after_a_mid_entrance_flip_into_bar_mode() {
        view = createTemporaryObject(overview, tc)
        verify(view)
        screenA = createTemporaryObject(screenStub, tc, { name: "A" })
        // Stretched so the flip below lands reliably inside the entrance, not by luck.
        view.motion.scale = 10
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
        wait(60)                             // partway through the stretched centred entrance
        view.testConfig.anchor = "bar"        // flip mid-flight: the direction under test
        for (var i = 0; i < 4; i++) {
            wait(120)
            var l = view.testCard.mapToItem(view.testPanel, 0, 0).x
            var r = view.testCard.mapToItem(view.testPanel, view.testCard.width, 0).x
            fuzzyCompare(l, 0, 0.5, "left edge after mid-entrance flip, sample " + i)
            fuzzyCompare(r, 1920, 0.5, "right edge after mid-entrance flip, sample " + i)
        }
    }

    // The stagger's observable contract, asserted on the delegates rather than on the pure
    // function (which tst_layout.qml already covers): rows must differ from one another
    // THE unfurl. Sampled mid-animation, because at rest an unfurled and a never-animated
    // card are identical. Three things have to hold at once, and each catches a different
    // mistake: the card is genuinely shorter than its content (it is opening), the Flickable
    // keeps its RESTING height (it is uncovered, not squashed), and contentY has not moved
    // (the viewport never shrank enough for onContentHeightChanged's clamp to scroll it).
    function test_the_card_unfurls_downward_from_the_bar() {
        view = createTemporaryObject(overview, tc)
        verify(view)
        screenA = createTemporaryObject(screenStub, tc, { name: "A" })
        view.motion.scale = 10                 // stretch the entrance so sampling is not a race
        view.testConfig.anchor = "bar"
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
        wait(200)

        var resting = view.testCard.implicitHeight
        verify(resting > 0, "precondition: the card has a resting height")
        verify(view.testCard.height < resting,
               "mid-unfurl the card must be shorter than its content, got "
               + view.testCard.height + " of " + resting)
        verify(view.testCard.y === 26, "and its top stays pinned to the bar throughout")
        compare(view.testFlick.height, resting - view.testCard.pad * 2 - view.testCard.hintSpace,
                "the viewport keeps its resting height — revealed, not squashed")
        compare(view.testFlick.contentY, 0, "the clamp must not have scrolled the grid")

        wait(3000)
        compare(view.testCard.height, resting, "and it ends fully open")
    }

    // A rebuild mid-session must not replay the entrance. boxesModel/tilesModel are reconciled
    // in place so the delegates persist; an entrance keyed to anything a rebuild re-triggers
    // would re-close and re-open the card every time a window moved.
    function test_a_rebuild_does_not_replay_the_unfurl() {
        seed(26, 10)
        wait(400)
        compare(view.entranceOpen, 1, "precondition: the unfurl has finished")
        view.compositor.rawEvent({ name: "openwindow", data: "" })
        view.rebuild()
        wait(30)
        compare(view.entranceOpen, 1, "a rebuild must not restart the unfurl")
        compare(view.testCard.height, view.testCard.implicitHeight, "and the card stays open")
    }

    // Motion off means open, not closed. The opposite default would leave a zero-height card
    // on a surface that still holds keyboard focus.
    function test_motion_off_opens_the_card_at_once() {
        view = createTemporaryObject(overview, tc)
        verify(view)
        screenA = createTemporaryObject(screenStub, tc, { name: "A" })
        view.motion.scale = 0                  // disables root.motion.enabled
        view.testConfig.anchor = "bar"
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
        wait(30)
        compare(view.entranceOpen, 1, "set directly, never animated")
        compare(view.testCard.height, view.testCard.implicitHeight, "fully open immediately")
    }

    // A transparent bar shows the wallpaper, so the card paints the wallpaper rather than a
    // colour. The alignment is the whole point: the image is sized to the PANEL and lifted by
    // the bar's height, so it is the same crop at the same screen position as the real
    // wallpaper behind the bar. Off-by-anything here and the seam reappears, worse than before
    // because the two halves would be the same picture at different offsets.
    function test_a_transparent_bar_makes_the_card_paint_the_wallpaper() {
        seed(26, 10)
        view.testConfig.wallpaperUrl = "file:///tmp/does-not-exist.png"
        view.testConfig.barTransparent = true
        wait(60)
        verify(view.wallpaperBacked, "precondition: the card should be wallpaper-backed")
        compare(view.testCard.color.a, 0, "the Rectangle paints nothing; the image is the ground")
        compare(view.testWallpaper.visible, true, "the wallpaper is shown")
        compare(view.testWallpaper.y, -26, "lifted by the bar's height, so it aligns with the real one")
        compare(view.testWallpaper.x, 0, "and flush with the screen's left edge")
        compare(view.testWallpaper.width, view.testPanel.width, "sized to the panel, not the card")
        compare(view.testWallpaper.height, view.testPanel.height, "in both axes")
    }

    // ...and it must fall back rather than paint nothing. An unresolvable wallpaper -- the probe
    // has not answered yet, or readlink found nothing -- would otherwise leave a transparent
    // Rectangle with no image behind it, i.e. an invisible card over the desktop.
    function test_an_unresolved_wallpaper_falls_back_to_a_painted_ground() {
        seed(26, 10)
        view.testConfig.barTransparent = true
        view.testConfig.wallpaperUrl = ""
        wait(60)
        verify(!view.wallpaperBacked, "no wallpaper means no wallpaper backing")
        compare(view.testWallpaper.visible, false, "nothing to show")
        verify(view.testCard.color.a > 0, "so the card must paint an opaque ground instead")
    }

    // The card must not cast its shadow onto the bar it hangs from. This surface is
    // WlrLayer.Overlay and the bar is WlrLayer.Top, so a halo above the card's top edge is
    // painted straight onto the bar -- darkening it, and making the two read as different
    // colours whatever the bar is showing. The halo reaches `blur - offset.y` upward, so the
    // offset has to be at least the blur.
    //
    // Asserted as a RELATIONSHIP, not against 28 and 6: the point is that the two can never
    // drift apart, and pinning literals here would pass while someone raised blur alone.
    function test_the_card_casts_no_shadow_onto_the_bar() {
        seed(26, 10)
        verify(view.testShadow.blur > 0, "precondition: there is a shadow to reason about")
        verify(view.testShadow.offset.y >= view.testShadow.blur,
               "in bar mode the halo must not reach above the card: offset.y "
               + view.testShadow.offset.y + " must be >= blur " + view.testShadow.blur)
    }

    // ...and the centred card must KEEP its shadow all round. Without this, "fix" the bar-mode
    // halo by pushing the offset out unconditionally and every other test still passes while
    // the default picker grows a lopsided shadow.
    function test_the_centred_card_keeps_its_shadow_above() {
        seed(26, 10, "center")
        verify(view.testShadow.offset.y < view.testShadow.blur,
               "centred, the shadow still haloes above the card: offset.y "
               + view.testShadow.offset.y + " should be < blur " + view.testShadow.blur)
    }

    // The grid must sit in the middle of a full-width card, not hug its left edge. layout()
    // places boxes from x = 0 and the canvas is exactly the grid's width, so on a panel where
    // maxCellW caps the cells before the width runs out the remainder is pure slack. 2048
    // logical is the real case that reported this: cells cap at 380, the grid is 1916, and
    // 108 px were being dumped on the right.
    function test_the_grid_is_centred_when_narrower_than_the_card() {
        seed(26, 10, "bar", 2048)
        var avail = view.testCard.width - view.testCard.pad * 2
        var slack = avail - view.testFlick.width
        verify(slack > 20,
               "precondition: this panel must actually leave slack, got " + slack)
        compare(view.testFlick.x, view.testCard.pad + Math.round(slack / 2),
                "the slack must be split evenly, not left on one side")
        // ...and the grid still fits, i.e. centring did not shrink the viewport below content.
        verify(view.testFlick.contentWidth <= view.testFlick.width,
               "content " + view.testFlick.contentWidth + " must fit " + view.testFlick.width)
    }

    // is the one property that makes this test able to tell the bug from the fix.
    function test_focus_moving_to_another_monitor_does_not_move_the_card() {
        view = createTemporaryObject(overview, tc)
        verify(view)
        screenA = createTemporaryObject(screenStub, tc, { name: "A" })
        screenB = createTemporaryObject(screenStub, tc, { name: "B" })
        view.testConfig.anchor = "bar"
        view.testPanel.width = 1920
        view.testPanel.height = 1080
        var monA = monitor("A", 0, 26)          // the picker's screen: a 26px bar
        var monB = monitor("B", 1080, 52)       // a 2x-scaled screen: a 52px bar
        view.compositor.monitors = { values: [monA, monB] }
        view.compositor.focusedMonitor = monA
        view.compositor.focusedWorkspace = { id: 1 }
        view.compositor.workspaces = { values: [
            { id: 1, monitor: monA, toplevels: { values: [] } },
            { id: 2, monitor: monB, toplevels: { values: [] } } ] }
        view.testScreens = [screenA, screenB]
        view.open()
        wait(120)
        compare(view.targetScreen, screenA, "precondition: opened on A")
        compare(view.reservedTop, 26, "precondition: A's bar")
        // implicitHeight, not height: `height` animates during the unfurl, so sampling it
        // before and after would compare two points on an animation rather than the card's
        // size, and would be timing-dependent whichever way the focus binding behaved.
        var y = view.testCard.y, h = view.testCard.implicitHeight

        // Focus moves to B without the picker closing.
        view.compositor.focusedMonitor = monB
        view.monitorEpoch++
        wait(60)
        compare(view.reservedTop, 26, "still A's reservation, not B's 52")
        compare(view.testCard.y, y, "the card must not re-anchor")
        compare(view.testCard.implicitHeight, h, "nor resize")

        // ...and a focused monitor with NO top bar must not drop bar mode either.
        view.compositor.monitors = { values: [monA, monitor("B", 1080, 0)] }
        view.compositor.focusedMonitor = view.compositor.monitors.values[1]
        view.monitorEpoch++
        wait(60)
        verify(view.barMode, "bar mode must survive focus landing on a bar-less monitor")
        compare(view.testCard.y, y, "and the card stays put")
    }
}
