import QtQuick
import qs.Ui

// Omascape's bar button (docs/specs/2026-09-24-bar-icon-design.md, ADR-0011). It does exactly
// what the SUPER+TAB bind does, through the same command, so both routes run the overlay's one
// open() path (ADR-0008). Static on purpose: no state, no timers, no compositor calls, so an
// always-visible icon keeps "nothing runs until you summon it" true. Where it sits is the
// shell's business (shell.json bar.layout); nothing here reads or writes it.
BarWidget {
    id: root
    moduleName: "se.mindfulstack.omascape"

    // nf-md-view_grid. `omarchy bar set se.mindfulstack.omascape icon <glyph>` overrides it; an
    // empty or non-string value falls back, because the host's setting() returns "" as-is.
    readonly property string defaultGlyph: "\u{F0570}"
    readonly property string glyph: {
        var v = root.setting("icon", "")
        return (typeof v === "string" && v !== "") ? v : defaultGlyph
    }

    implicitWidth: button.implicitWidth
    implicitHeight: button.implicitHeight

    WidgetButton {
        id: button
        objectName: "omascapeBarButton"
        anchors.fill: parent
        bar: root.bar
        text: root.glyph
        tooltipText: "Workspace overview"
        horizontalMargin: 7.5
        onPressed: function(button) {
            if (!root.bar || button !== Qt.LeftButton) return
            root.bar.run("omarchy-shell shell toggle se.mindfulstack.omascape")
        }
    }
}
