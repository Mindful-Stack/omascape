import QtQuick

// Offscreen stand-in for qs.Ui WidgetButton (/usr/share/omarchy/shell/Ui/WidgetButton.qml).
// The click path mirrors the host: MouseArea (Left|Right|Middle) → onClicked → triggerPress →
// pressed(button). See the note in BarWidget.qml about drift.
Item {
    id: root
    property var bar: null
    property string text: ""
    property string fontFamily: "sans-serif"
    property real horizontalMargin: 8.5
    property string tooltipText: ""
    signal pressed(int button)

    implicitWidth: 28
    implicitHeight: 26

    function triggerPress(button) {
        if (root.bar && typeof root.bar.hideTooltip === "function") root.bar.hideTooltip(root)
        root.pressed(button)
    }

    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
        onClicked: function(mouse) { root.triggerPress(mouse.button) }
    }
}
