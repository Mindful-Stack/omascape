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

        function make(settings) {
            fakeBar.runs = []
            var w = createTemporaryObject(widgetC, host, settings === undefined ? {} : { settings: settings })
            verify(w, "BarWidget.qml instantiates (no recursive self-instantiation)")
            return w
        }
        function button(w) { return findChild(w, "omascapeBarButton") }

        // Catches: wrong or missing command, wrong plugin id, press not wired.
        function test_left_click_toggles_once() {
            var w = make()
            mouseClick(button(w), 5, 5, Qt.LeftButton)
            compare(fakeBar.runs.length, 1)
            compare(fakeBar.runs[0], toggleCmd)
        }
        // Catches: the button filter missing, so every button toggles.
        function test_other_buttons_do_nothing() {
            var w = make()
            mouseClick(button(w), 5, 5, Qt.RightButton)
            mouseClick(button(w), 5, 5, Qt.MiddleButton)
            compare(fakeBar.runs.length, 0)
        }
        // Catches: a missing `!root.bar` guard. Without the guard the click only logs
        // "TypeError: Cannot call method 'run' of null" (runs stays empty either way, since with
        // bar null nothing can record), so the warning is the failure signal. failOnWarning is
        // Qt 6.3+, so it is inside the 6.9 floor.
        function test_no_bar_no_run() {
            failOnWarning(/TypeError/)
            var w = make()
            w.bar = null
            mouseClick(button(w), 5, 5, Qt.LeftButton)
            compare(fakeBar.runs.length, 0)
        }
        // Catches: a wrong default glyph. The expected value is written out here, not read back
        // from the code.
        function test_default_glyph() {
            compare(button(make()).text, "󰕰")   // U+F0570 written literally, independent of the code's escape
        }
        // Catches: a glyph that is read once and never re-evaluated. The host applies
        // `omarchy bar set` to a running widget by REPLACING `settings` (Bar.qml).
        function test_icon_setting_is_live() {
            var w = make()
            w.settings = { icon: "Y" }
            compare(button(w).text, "Y")
        }
        // Catches: the per-entry override not being read.
        function test_icon_setting_overrides() {
            compare(button(make({ icon: "X" })).text, "X")
        }
        // Catches: the naive `setting("icon", default)`, which returns "" and renders nothing.
        function test_empty_or_bad_icon_falls_back() {
            compare(button(make({ icon: "" })).text, "󰕰")
            compare(button(make({ icon: 42 })).text, "󰕰")
        }
        // Catches: a moduleName that doesn't match the manifest id, which the host uses for
        // settings lookup and moduleWidgets().
        function test_module_name_is_plugin_id() {
            compare(make().moduleName, "se.mindfulstack.omascape")
        }
        function test_tooltip() {
            compare(button(make()).tooltipText, "Workspace overview")
        }
    }
}
