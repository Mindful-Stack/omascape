import QtQuick

// Find bar — display only. Replaces the key-hint row while a query is active: a magnifier
// glyph, the query, and "n of m", laid out as one group centred where the hints sit. The
// caller sets the width (the card interior); the query elides at its start so the newest
// characters stay visible, and the group never grows past the bar. No key handling and no
// focus: Overview's keyCatcher stays the single focus item (docs/specs/2026-09-11-find-design.md).
Item {
    id: bar
    property string query: ""
    property int count: 0
    property int index: -1            // 0-based rank of the selection, -1 when none
    property color fg: "#ddd"
    property color accent: "#88f"
    property string fontFamily: ""
    property int fontSize: 11
    implicitHeight: Math.max(glyph.implicitHeight, queryText.implicitHeight, countText.implicitHeight) + 4

    readonly property real gapA: 8
    readonly property real gapB: 12
    // The query takes what the glyph and count leave, capped at its natural width.
    readonly property real queryWidth: Math.max(0, Math.min(queryText.implicitWidth,
        width - glyph.implicitWidth - gapA - gapB - countText.implicitWidth))
    readonly property real groupWidth: glyph.implicitWidth + gapA + queryWidth + gapB + countText.implicitWidth
    readonly property real groupX: Math.max(0, (width - groupWidth) / 2)

    Text {   // nf-md-magnify; Omarchy's menu font carries the Nerd glyphs
        id: glyph
        objectName: "findGlyph"
        textFormat: Text.PlainText
        x: bar.groupX
        anchors.verticalCenter: parent.verticalCenter
        text: "\u{F0349}"
        color: bar.accent
        font.family: bar.fontFamily; font.pixelSize: bar.fontSize
    }
    Text {
        id: queryText
        objectName: "findQuery"
        x: glyph.x + glyph.implicitWidth + bar.gapA
        width: bar.queryWidth
        anchors.verticalCenter: parent.verticalCenter
        text: bar.query
        textFormat: Text.PlainText        // the query is matched literally, so show it literally
        elide: Text.ElideLeft             // the end of the query is what the user just typed
        color: bar.fg
        opacity: bar.count > 0 ? 1 : 0.5      // muted when nothing matches
        font.family: bar.fontFamily; font.pixelSize: bar.fontSize
        font.weight: Font.DemiBold
    }
    Text {
        id: countText
        objectName: "findCount"
        textFormat: Text.PlainText
        x: queryText.x + queryText.width + bar.gapB
        anchors.verticalCenter: parent.verticalCenter
        text: bar.count > 0 ? (bar.index + 1) + " of " + bar.count : "0 matches"
        color: bar.fg; opacity: 0.55
        font.family: bar.fontFamily; font.pixelSize: bar.fontSize
    }
}
