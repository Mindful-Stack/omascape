import QtQuick
import QtTest

// Closing the overview from a monitor it is NOT on.
//
// The overview is a single layer surface on the focused monitor, so the scrim MouseArea inside it
// only ever sees clicks on that monitor; a click anywhere on another monitor goes to whatever
// window is under the cursor there and the overview stays up. The fix is a transparent
// click-catcher surface on every OTHER screen while the overview is open.
//
// The fixture (tests/ui/prepare.py) turns both per-screen `Variants` blocks into `Repeater`s over
// `root.testScreens` and every `PanelWindow` into a plain `Item`, so the catchers here are sibling
// Items under the overview root rather than surfaces on their own monitors. Two consequences the
// suite relies on: `modelData` is the screen object the catcher was created for (what the shell
// binds `screen:` to), and prepare.py stacks the catchers above the overview's own panel — on real
// hardware a click on another monitor cannot reach the overview's surface at all, and without that
// stacking the panel would swallow every press here and the suite could not tell a working catcher
// from a missing one.
TestCase {
    id: tc
    name: "CloseOtherScreen"
    when: windowShown
    width: 1200; height: 800; visible: true
    property var view
    property var screenA
    property var screenB
    Component { id: overview; Overview {} }
    // Stands in for a Quickshell ShellScreen. `focusedScreen()` matches Hyprland's focused monitor
    // to one of these BY NAME and returns the object itself, so `root.targetScreen` is identity-
    // comparable with a delegate's `modelData` here exactly as it is in the shell.
    Component {
        id: screenStub
        QtObject { property string name: ""; property int width: 1920; property int height: 1080 }
    }
    function monitor(name, y) {
        return { name: name, x: 0, y: y, width: 1920, height: 1080, scale: 1,
                 lastIpcObject: { reserved: [0, 0, 0, 0], transform: 0 } }
    }
    // Two monitors, A focused: the overview opens on A and must be closable from B.
    function seed(v) {
        var monA = monitor("A", 0), monB = monitor("B", 1080)
        v.compositor.monitors = { values: [monA, monB] }
        v.compositor.focusedMonitor = monA
        v.compositor.focusedWorkspace = { id: 1 }
        v.compositor.workspaces = { values: [
            { id: 1, monitor: monA, toplevels: { values: [] } },
            { id: 2, monitor: monB, toplevels: { values: [] } } ] }
        v.testScreens = [screenA, screenB]
    }
    function init() {
        view = createTemporaryObject(overview, tc)
        verify(view !== null)
        view.motion.scale = 0                 // no entrance/exit fade to wait for
        screenA = createTemporaryObject(screenStub, tc, { name: "A" })
        screenB = createTemporaryObject(screenStub, tc, { name: "B" })
        seed(view)
        view.open()
        compare(view.targetScreen, screenA, "precondition: the overview opened on screen A")
    }
    function cleanup() { view.close() }

    function catchers() {
        var out = [], ch = view.children
        for (var i = 0; i < ch.length; i++)
            if (ch[i].objectName === "omyviewCatcher") out.push(ch[i])
        return out
    }
    function catcherFor(screen) {
        var all = catchers()
        for (var i = 0; i < all.length; i++) if (all[i].modelData === screen) return all[i]
        fail("no catcher instance for screen " + (screen ? screen.name : screen))
    }

    // Red if `visible` stops gating on `root.opened`: the catcher would then be a permanent
    // transparent overlay on every non-focused monitor, swallowing clicks with nothing open.
    function test_no_catcher_is_on_screen_while_the_overview_is_closed() {
        view.close()
        compare(view.opened, false)
        var all = catchers()
        compare(all.length, 2, "one instance per screen, mapped or not")
        for (var i = 0; i < all.length; i++)
            verify(!all[i].visible,
                   "catcher for " + all[i].modelData.name + " must not be on screen while closed")
    }

    // Red if the `modelData !== root.targetScreen` guard is dropped or inverted: a catcher on the
    // overview's own screen would sit above the card and eat every click meant for it.
    function test_catcher_covers_only_the_other_screen() {
        compare(catchers().length, 2)
        verify(!catcherFor(screenA).visible, "never on the overview's own screen")
        verify(catcherFor(screenB).visible, "on the screen the overview is not on")
    }

    // The assertion lands between press and release: red if the catcher carries no MouseArea, if
    // `visible` is hard-coded false (nothing to press), or if it closed on CLICK instead of PRESS —
    // a drag begun on the other monitor would then leave the overview open.
    function test_press_on_another_screen_closes_the_overview() {
        var b = catcherFor(screenB)
        verify(b.visible, "precondition: the catcher is up on screen B")
        var p = b.mapToItem(tc, b.width / 2, b.height / 2)
        mousePress(tc, p.x, p.y, Qt.LeftButton)
        compare(view.opened, false, "a press on another monitor closes the overview")
        mouseRelease(tc, p.x, p.y, Qt.LeftButton)
    }

    // Red if closing latched the catcher off (e.g. gating on something the close path never
    // restores) — the second summon would be uncloseable from B again.
    function test_catcher_returns_on_the_next_open() {
        var b = catcherFor(screenB), p = b.mapToItem(tc, b.width / 2, b.height / 2)
        mousePress(tc, p.x, p.y, Qt.LeftButton)
        mouseRelease(tc, p.x, p.y, Qt.LeftButton)
        compare(view.opened, false)
        view.open()
        compare(view.targetScreen, screenA)
        verify(catcherFor(screenB).visible, "no stale state: B is catchable again")
        verify(!catcherFor(screenA).visible)
    }

    // Red if the exclusion stopped being "the target screen" (the lone screen IS the target, so a
    // catcher there would cover the card on a single-monitor machine — the common setup).
    function test_single_screen_never_gets_a_catcher() {
        view.close()
        var monA = monitor("A", 0)
        view.compositor.monitors = { values: [monA] }
        view.compositor.focusedMonitor = monA
        view.compositor.workspaces = { values: [{ id: 1, monitor: monA, toplevels: { values: [] } }] }
        view.testScreens = [screenA]
        view.open()
        compare(view.targetScreen, screenA)
        var all = catchers()
        compare(all.length, 1, "one screen, one instance")
        verify(!all[0].visible, "the only screen is the overview's own: nothing to catch")
    }
}
