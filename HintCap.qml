import QtQuick

// One key hint: a key cap and its label. Shared by both hint tiers (Overview.qml); the colours
// and fonts come from the Overview root, which is the only thing that knows the theme.
Row {
    id: cap
    required property var modelData
    property color foreground: "#ddd"
    property color fill: "#333"
    property string fontFamily: ""
    property int fontSize: 10
    // The cap/label contrast is a hierarchy, not decoration: the cap is what you press, the
    // label only says what it does. Both are properties because the right values depend on
    // what is BEHIND them -- these defaults suit a flat card, and a photograph needs more.
    // Whatever they are set to, the cap must stay above the label or the hierarchy inverts.
    property real capOpacity: 0.75
    property real labelOpacity: 0.45
    spacing: 5
    Rectangle {
        radius: 4
        color: cap.fill
        height: capText.implicitHeight + 4
        width: capText.implicitWidth + 10
        Text {
            id: capText; anchors.centerIn: parent
            text: cap.modelData.k
            color: cap.foreground; opacity: cap.capOpacity
            font.family: cap.fontFamily; font.pixelSize: cap.fontSize
            font.weight: Font.DemiBold
        }
    }
    Text {
        anchors.verticalCenter: parent.verticalCenter
        text: cap.modelData.l
        color: cap.foreground; opacity: cap.labelOpacity
        font.family: cap.fontFamily; font.pixelSize: cap.fontSize
    }
}
