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
    spacing: 5
    Rectangle {
        radius: 4
        color: cap.fill
        height: capText.implicitHeight + 4
        width: capText.implicitWidth + 10
        Text {
            id: capText; anchors.centerIn: parent
            text: cap.modelData.k
            color: cap.foreground; opacity: 0.75
            font.family: cap.fontFamily; font.pixelSize: cap.fontSize
            font.weight: Font.DemiBold
        }
    }
    Text {
        anchors.verticalCenter: parent.verticalCenter
        text: cap.modelData.l
        color: cap.foreground; opacity: 0.45
        font.family: cap.fontFamily; font.pixelSize: cap.fontSize
    }
}
