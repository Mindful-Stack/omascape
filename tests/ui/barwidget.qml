import QtQuick
import QtTest
import "plugin" as Plugin

// Bar button (docs/specs/2026-09-24-bar-icon-design.md). Loads the production BarWidget.qml
// against the qs.Ui stubs (tests/ui/stubs).
Item {
    id: host
    width: 200; height: 40

    QtObject {
        id: fakeBar
        property var runs: []
        property string fontFamily: "sans-serif"
        property bool vertical: false
        property int barSize: 26
        function run(cmd) { runs = runs.concat([cmd]) }
        function hideTooltip(item) { }
    }

    Component { id: widgetC; Plugin.BarWidget { bar: fakeBar } }

    TestCase {
        name: "BarWidget"
        when: windowShown

        readonly property string toggleCmd: "omarchy-shell shell toggle se.mindfulstack.omascape"

        SignalSpy {
            id: pressedSpy
            signalName: "pressed"
        }

        function make(settings) {
            fakeBar.runs = []
            var w = createTemporaryObject(widgetC, host, settings === undefined ? {} : { settings: settings })
            verify(w, "BarWidget.qml instantiates (no recursive self-instantiation)")
            return w
        }
        function button(w) { return findChild(w, "omascapeBarButton") }

        // Distinguishes: wrong or missing command, wrong plugin id, press not wired.
        function test_left_click_toggles_once() {
            var w = make()
            mouseClick(button(w), 5, 5, Qt.LeftButton)
            compare(fakeBar.runs.length, 1)
            compare(fakeBar.runs[0], toggleCmd)
        }
        // Distinguishes: the button filter missing, so every button toggles. The spy proves the
        // click reached WidgetButton.pressed at all — without it, a synthetic click that never
        // reaches the button (e.g. acceptedButtons narrowed to Left only) would also leave
        // fakeBar.runs empty, and this test would pass vacuously.
        function test_other_buttons_do_nothing() {
            var w = make()
            pressedSpy.target = button(w)
            pressedSpy.clear()
            mouseClick(button(w), 5, 5, Qt.RightButton)
            mouseClick(button(w), 5, 5, Qt.MiddleButton)
            compare(pressedSpy.count, 2)
            compare(fakeBar.runs.length, 0)
        }
        // Distinguishes: a missing `!root.bar` guard. Without the guard the click only logs
        // "TypeError: Cannot call method 'run' of null" (runs stays empty either way, since with
        // bar null nothing can record), so the warning is the failure signal. failOnWarning is
        // Qt 6.3+, so it is inside the 6.9 floor. The spy proves the click itself reached
        // WidgetButton.pressed, so a silently-vacuous click can't hide behind the empty runs list.
        function test_no_bar_no_run() {
            failOnWarning(/TypeError/)
            var w = make()
            pressedSpy.target = button(w)
            pressedSpy.clear()
            w.bar = null
            mouseClick(button(w), 5, 5, Qt.LeftButton)
            compare(pressedSpy.count, 1)
            compare(fakeBar.runs.length, 0)
        }
        // Distinguishes: a wrong default glyph. The expected value is written out here, not read
        // back from the code.
        function test_default_glyph() {
            compare(button(make()).text, "󰕰")   // U+F0570 written literally, independent of the code's escape
        }
        // Distinguishes: a glyph that is read once and never re-evaluated. The host applies
        // `omarchy bar set` to a running widget by REPLACING `settings` (Bar.qml).
        function test_icon_setting_is_live() {
            var w = make()
            w.settings = { icon: "Y" }
            compare(button(w).text, "Y")
        }
        // Distinguishes: the per-entry override not being read.
        function test_icon_setting_overrides() {
            compare(button(make({ icon: "X" })).text, "X")
        }
        // Distinguishes: the naive `setting("icon", default)`, which returns "" and renders nothing.
        function test_empty_or_bad_icon_falls_back() {
            compare(button(make({ icon: "" })).text, "󰕰")
            compare(button(make({ icon: 42 })).text, "󰕰")
        }
        // Distinguishes: a moduleName that doesn't match the manifest id, which the host uses for
        // settings lookup and moduleWidgets().
        function test_module_name_is_plugin_id() {
            compare(make().moduleName, "se.mindfulstack.omascape")
        }
        // Distinguishes: a missing or wrong tooltip string on the button.
        function test_tooltip() {
            compare(button(make()).tooltipText, "Workspace overview")
        }
    }
}
