import QtQuick

// The settings panel: rows, a selection, and a request to change one value. It reads no config
// and writes no file -- Overview owns both -- so every claim it makes can be checked by handing
// it a model and reading back what it emits.
Rectangle {
    id: panel
    // Everything visual is injected, exactly as FindBar and HintCap do it: this component never
    // imports the shell, which is what lets the offscreen fixture copy it verbatim.
    property var rows: []
    property int index: 0
    property color background: "#222"
    property color foreground: "#ddd"
    property color accent: "#8ab"
    property color rowFill: "#333"
    property string fontFamily: ""
    property int fontSize: 11
    property string filePath: ""
    signal changeRequested(string key, int dir)

    radius: 8
    color: background
    implicitWidth: 420
    implicitHeight: list.implicitHeight + pathLabel.implicitHeight + 34

    Column {
        id: list
        x: 12; y: 12
        width: parent.width - 24
        spacing: 2
        Repeater {
            model: panel.rows
            Rectangle {
                required property var modelData
                required property int index
                width: list.width
                height: 26
                radius: 4
                color: index === panel.index ? panel.rowFill : "transparent"
                Text {
                    anchors { left: parent.left; leftMargin: 8; verticalCenter: parent.verticalCenter }
                    text: modelData.label
                    color: panel.foreground
                    opacity: modelData.editable ? 0.85 : 0.5
                    font.family: panel.fontFamily; font.pixelSize: panel.fontSize
                }
                Text {
                    anchors { right: parent.right; rightMargin: 8; verticalCenter: parent.verticalCenter }
                    // The non-editable row says WHY it cannot be changed here, rather than
                    // looking like a control that does not respond.
                    text: modelData.editable
                          ? ("‹ " + String(modelData.value) + " ›")
                          : (String(modelData.value) + "   (edit the file)")
                    color: index === panel.index && modelData.editable ? panel.accent : panel.foreground
                    opacity: modelData.editable ? 1 : 0.5
                    font.family: panel.fontFamily; font.pixelSize: panel.fontSize
                }
            }
        }
    }
    Text {
        id: pathLabel
        anchors { left: parent.left; leftMargin: 20; bottom: parent.bottom; bottomMargin: 10 }
        text: panel.filePath
        color: panel.foreground; opacity: 0.45
        font.family: panel.fontFamily; font.pixelSize: panel.fontSize - 1
    }

    // Key handling lives here so Overview routes ONE call rather than reimplementing the rows'
    // semantics. Returns true when the key was consumed.
    function handleKey(e) {
        if (e.key === Qt.Key_Up)   { panel.index = Math.max(0, panel.index - 1); return true }
        if (e.key === Qt.Key_Down) { panel.index = Math.min(panel.rows.length - 1, panel.index + 1); return true }
        var row = panel.rows[panel.index]
        if (!row || !row.editable) return true          // consumed: the panel is modal
        if (e.key === Qt.Key_Left)  { panel.changeRequested(row.key, -1); return true }
        if (e.key === Qt.Key_Right) { panel.changeRequested(row.key, 1); return true }
        if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) { panel.changeRequested(row.key, 1); return true }
        return true
    }
}
