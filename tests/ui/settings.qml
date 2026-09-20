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
        // Correction 2's actual subject. A QML `var` holding an object does not re-evaluate
        // dependent bindings when the object is mutated internally -- only when it is
        // REASSIGNED. Mutating settingsPending in place leaves settingValue() correct (it reads
        // fresh) while settingsRows never updates, so the panel computes the right next value
        // and displays the old one. Asserting on writes[] cannot see that; this can.
        var anchorRow = null
        for (var i = 0; i < view.settingsRows.length; i++)
            if (view.settingsRows[i].key === "anchor") anchorRow = view.settingsRows[i]
        compare(anchorRow.value, "bar", "the row must show the new value, not the old one")
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
        for (var d = 0; d < 5; d++) keyClick(Qt.Key_Down)   // workspaces (stub default 0, not parseConfig's 10)
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

    // A refused save must drop ONLY that key's optimistic value, so the panel shows what the
    // file still says for it -- while any other pending change stays pending.
    function test_a_refused_save_reverts_only_that_key() {
        seed()
        keyClick(Qt.Key_Comma, Qt.ControlModifier)
        keyClick(Qt.Key_Right)                       // anchor -> bar, accepted
        view.testConfig.failSaves = true
        for (var d = 0; d < 5; d++) keyClick(Qt.Key_Down)   // workspaces
        keyClick(Qt.Key_Right)                       // refused
        var rows = view.settingsRows, anchorRow = null, wsRow = null
        for (var i = 0; i < rows.length; i++) {
            if (rows[i].key === "anchor") anchorRow = rows[i]
            if (rows[i].key === "workspaces") wsRow = rows[i]
        }
        // Stub default (tests/ui/prepare.py) is 0, not parseConfig's 10 -- the fixture shows
        // exactly the compositor's workspaces unless a test opts into padding.
        compare(wsRow.value, 0, "the refused key reverts to what the file says")
        compare(anchorRow.value, "bar", "but the earlier accepted change stays pending")
    }

    // A write that fails AFTER dispatch must not leave the panel showing a value the file does
    // not have. saveAll returns true on dispatch, so only the signal can report this.
    function test_a_failed_write_reverts_and_notifies() {
        seed()
        keyClick(Qt.Key_Comma, Qt.ControlModifier)
        keyClick(Qt.Key_Right)                        // anchor -> bar, dispatched
        var before = view.compositor.commands.length
        view.testConfig.emitWriteFailed("Permission denied")
        var rows = view.settingsRows, anchorRow = null
        for (var i = 0; i < rows.length; i++) if (rows[i].key === "anchor") anchorRow = rows[i]
        compare(anchorRow.value, "center", "the row falls back to what the file still says")
        compare(view.compositor.commands.length, before + 1, "and the user is told")
    }

    // The panel is modal for the POINTER too. The workspace boxes and tiles underneath keep
    // their own MouseAreas, so without a barrier a click on the panel's centre activates the
    // workspace behind it and closes the picker.
    function test_a_click_on_the_panel_does_not_reach_the_grid() {
        seed()
        keyClick(Qt.Key_Comma, Qt.ControlModifier)
        verify(view.settingsOpen, "precondition: the panel is open")
        var before = view.compositor.commands.length
        var p = view.testSettingsPanel
        mouseClick(p, p.width / 2, p.height / 2)
        compare(view.compositor.commands.length, before,
                "a click on the panel must dispatch nothing to the compositor")
        verify(view.opened, "and must not close the picker")
        verify(view.settingsOpen, "and the panel stays open")
    }

    // Every row the panel can land on describes itself, with no key to press. The panel is
    // where a user first meets names like "lock frame", so the description has to be there when
    // they arrive, not behind a shortcut they would have to already know about.
    function test_the_description_follows_the_selection() {
        seed()
        keyClick(Qt.Key_Comma, Qt.ControlModifier)
        var panel = view.testSettingsPanel
        var first = panel.currentHelp
        verify(first.length > 0, "the top row describes itself")
        compare(first, String(view.settingsRows[0].help), "with ITS row's description")
        keyClick(Qt.Key_Down)
        verify(panel.currentHelp !== first,
               "and moving the selection changes it: still showing " + panel.currentHelp)
        compare(panel.currentHelp, String(view.settingsRows[1].help), "to the new row's")
    }

    // The panel must not resize under the selection as the description changes: a two-line
    // description on one row and a one-line description on the next would otherwise make the
    // whole panel jump every time you press Down.
    function test_the_panel_height_does_not_move_with_the_selection() {
        seed()
        keyClick(Qt.Key_Comma, Qt.ControlModifier)
        var panel = view.testSettingsPanel
        var h = panel.implicitHeight
        for (var d = 0; d < panel.actionIndex; d++) {
            keyClick(Qt.Key_Down)
            compare(panel.implicitHeight, h,
                    "row " + panel.index + " changed the panel height")
        }
    }

    // Down must REACH the action row -- a `rows.length - 1` ceiling stops one short of it.
    function test_down_reaches_the_open_row() {
        seed()
        keyClick(Qt.Key_Comma, Qt.ControlModifier)
        var panel = view.testSettingsPanel
        compare(panel.actionIndex, view.settingsRows.length, "the action row is one past the settings")
        for (var d = 0; d < panel.actionIndex; d++) keyClick(Qt.Key_Down)
        compare(view.settingsIndex, panel.actionIndex, "Down lands on it")
        verify(panel.currentHelp.length > 0, "and it describes itself like any other row")
    }

    // The selection wraps. Up from the top is the short way to `edit the file`, which is the
    // bottom row and the one most often wanted -- a clamped list makes it the longest trip.
    function test_the_selection_wraps_in_both_directions() {
        seed()
        keyClick(Qt.Key_Comma, Qt.ControlModifier)
        var panel = view.testSettingsPanel
        compare(view.settingsIndex, 0, "precondition: at the top")
        keyClick(Qt.Key_Up)
        compare(view.settingsIndex, panel.actionIndex, "Up from the top lands on the last row")
        keyClick(Qt.Key_Down)
        compare(view.settingsIndex, 0, "and Down from the last row comes back to the top")
        // ...and the wrap is a single step, not a slide through every row in between: a loop
        // that clamped and then jumped would pass the two checks above while firing every row's
        // change handler on the way. Asserted by the writes it must NOT have requested.
        compare(view.testConfig.writes.length, 0, "wrapping changes no setting")
    }

    // The action row launches the editor on the file the panel has been writing -- config.path,
    // not a guess -- and closes the picker, which would otherwise cover the editor it opened.
    function test_the_open_row_launches_the_editor_and_closes_the_picker() {
        seed()
        keyClick(Qt.Key_Comma, Qt.ControlModifier)
        for (var d = 0; d < view.testSettingsPanel.actionIndex; d++) keyClick(Qt.Key_Down)
        compare(view.testExec.length, 0, "precondition: nothing launched yet")
        keyClick(Qt.Key_Return)
        compare(view.testExec.length, 1, "Enter launches exactly one process")
        var argv = view.testExec[0]
        compare(String(argv[argv.length - 1]), String(view.testConfig.path),
                "on the path the panel actually reads and writes")
        verify(!view.opened, "and the picker gets out of the editor's way")
    }

    // Left/Right on the action row must be consumed and do nothing -- NOT fall through to the
    // last setting above it, which is what an index-clamped implementation does.
    function test_the_open_row_steps_no_setting() {
        seed()
        keyClick(Qt.Key_Comma, Qt.ControlModifier)
        for (var d = 0; d < view.testSettingsPanel.actionIndex; d++) keyClick(Qt.Key_Down)
        var before = view.testConfig.writes.length
        keyClick(Qt.Key_Right)
        keyClick(Qt.Key_Left)
        compare(view.testConfig.writes.length, before, "neither arrow writes anything")
        compare(view.testExec.length, 0, "and neither launches anything")
        verify(view.settingsOpen, "and the keys did not escape to the picker")
    }

    // `workspaces` is the one setting the view does not reach through a live binding: it is read
    // inside buildInput(), and only rebuild() calls that. Overview.qml's `onWorkspacesChanged`
    // handler is what re-lays the grid for it -- this pins that handler down, because nothing
    // else covered it and the panel now gives users a way to change the value every time they
    // open the picker. Fails with "10 to stay 10" if that handler is dropped.
    function test_changing_the_workspace_count_relays_out_the_grid() {
        seed()
        compare(view.boxes.length, 10, "precondition: the compositor's ten workspaces")
        view.testConfig.workspaces = 14        // what a reload's apply() does to this property
        compare(view.boxes.length, 14,
                "the padded count must re-lay the grid without a compositor event")
    }

    // ctrl+, is only discoverable if something says so. The second tier, not the first: the
    // primary hint row already carries nine caps and is the width budget for a narrow card.
    function test_the_hints_name_the_settings_key() {
        seed()
        var caps = view.testHintModel2, found = ""
        for (var i = 0; i < caps.length; i++)
            if (String(caps[i].k).indexOf(",") >= 0) found = String(caps[i].k) + "/" + String(caps[i].l)
        compare(found, "ctrl+,/settings", "the ? tier must name the settings key")
    }

    // Closing the picker must not leave the panel armed. Otherwise the next summon opens with
    // settings still intercepting every navigation key, with nothing on screen explaining why.
    function test_the_panel_does_not_survive_a_picker_session() {
        seed()
        keyClick(Qt.Key_Comma, Qt.ControlModifier)
        verify(view.settingsOpen, "precondition: the panel is open")
        view.close()
        view.open()
        wait(120)
        verify(!view.settingsOpen, "a fresh summon must start with the panel closed")
        // ...and the keyboard must genuinely be back with the picker, not merely the flag cleared.
        keyClick(Qt.Key_Down)
        verify(!view.settingsOpen, "Down must not be intercepted by a stale panel")
    }
}
