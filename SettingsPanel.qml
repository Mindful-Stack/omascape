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
    // The last row is not a setting: it opens `filePath` in the user's editor, which is the only
    // way to reach the keys this panel cannot edit (lockBorder) and the only way to see the file
    // it has been rewriting. Overview owns the launch, as it owns every other side effect.
    signal openRequested()
    // Enter means "I am done here". The panel cannot close itself -- Overview owns `settingsOpen`
    // and the dismiss-key swallow that stops a HELD key closing the panel and then reaching the
    // picker behind it -- so it asks.
    signal closeRequested()

    // The action row sits one past the last setting, so navigation is a single 0..actionIndex
    // range and nothing has to special-case "the bottom".
    readonly property int actionIndex: rows.length
    // The selection's description, always visible rather than behind a key: this panel is where
    // a user first meets names like "lock frame", and a description you have to discover does
    // not answer the question they already have. Never undefined -- a binding that evaluates to
    // undefined is destroyed, and the line would then stay blank for the rest of the session.
    readonly property string currentHelp: {
        if (panel.index >= panel.actionIndex) return "opens the file in your editor"
        var r = panel.rows[panel.index]
        return (r && r.help) ? String(r.help) : ""
    }
    // Two lines, reserved whether or not the text needs them. A help line that sized itself to
    // its text would resize the panel under the selection on every Up/Down, which reads as the
    // panel twitching rather than as the description changing.
    readonly property int helpHeight: Math.round((panel.fontSize + 4) * 2)

    radius: 8
    color: background
    // Wide enough that the descriptions and the config path fit without eliding on a normal
    // theme; both degrade gracefully (wrap, elide) if a larger font pushes them over.
    implicitWidth: 520
    implicitHeight: 12 + list.implicitHeight + 10 + helpHeight + 12

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

        // The action row. Same shape as a setting row so the selection ring moves through it
        // without a seam, and it carries the path it will open rather than naming it abstractly.
        Rectangle {
            id: actionRow
            width: list.width
            height: 26
            radius: 4
            color: panel.index === panel.actionIndex ? panel.rowFill : "transparent"
            Text {
                id: actionLabel
                anchors { left: parent.left; leftMargin: 8; verticalCenter: parent.verticalCenter }
                text: "edit the file"
                color: panel.foreground; opacity: 0.85
                font.family: panel.fontFamily; font.pixelSize: panel.fontSize
            }
            Text {
                anchors { left: actionLabel.right; leftMargin: 12; right: parent.right
                          rightMargin: 8; verticalCenter: parent.verticalCenter }
                horizontalAlignment: Text.AlignRight
                // Elided in the MIDDLE: the interesting halves of a config path are its start
                // and its filename, and a tail elide would hide the latter.
                elide: Text.ElideMiddle
                text: panel.filePath + "   ↵"
                color: panel.index === panel.actionIndex ? panel.accent : panel.foreground
                opacity: panel.index === panel.actionIndex ? 1 : 0.5
                font.family: panel.fontFamily; font.pixelSize: panel.fontSize
            }
        }
    }

    Text {
        id: helpLabel
        anchors { left: parent.left; leftMargin: 20; right: parent.right; rightMargin: 20
                  top: list.bottom; topMargin: 10 }
        height: panel.helpHeight
        verticalAlignment: Text.AlignTop
        wrapMode: Text.WordWrap
        text: panel.currentHelp
        color: panel.foreground; opacity: 0.55
        font.family: panel.fontFamily; font.pixelSize: panel.fontSize - 1
    }

    // The panel is modal for the pointer as well as the keyboard. Without this the workspace
    // boxes and window tiles UNDERNEATH it keep their own MouseAreas, so a click on the panel's
    // centre activates whatever workspace happens to be behind it and closes the picker. The
    // wheel matters too: otherwise scrolling over the panel scrolls the grid behind it.
    //
    // Placed last so it sits on top of everything else declared here -- correct today because the
    // panel has no interactive children (it is keyboard-driven, via handleKey below), not because
    // this MouseArea was placed carefully around them. A future row-level control (a click target
    // inside a row, say) would need to sit BELOW this in stacking order, or above it in z, to
    // still receive events.
    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.AllButtons
        onClicked: {}          // swallow
        onWheel: {}            // swallow
    }

    // Key handling lives here so Overview routes ONE call rather than reimplementing the rows'
    // semantics. Returns true when the key was consumed.
    function handleKey(e) {
        // Wraps in both directions: the list is short and closed, and the row people reach for
        // most (edit the file) is the LAST one -- so one Up from the top is the fast way to it.
        // actionIndex, not rows.length - 1, is the bottom: Down must be able to reach it.
        if (e.key === Qt.Key_Up)   { panel.index = panel.index <= 0 ? panel.actionIndex : panel.index - 1; return true }
        if (e.key === Qt.Key_Down) { panel.index = panel.index >= panel.actionIndex ? 0 : panel.index + 1; return true }
        var enter = e.key === Qt.Key_Return || e.key === Qt.Key_Enter
        if (panel.index >= panel.actionIndex) {
            // The action row has no value to step through, so Left/Right/Space are consumed and
            // do nothing rather than editing whatever row happens to be above it. Enter here
            // performs the row instead of closing the panel -- which still ends the session, as
            // opening the editor closes the whole picker.
            //
            // Autorepeat is refused: a held Enter would otherwise launch an editor per repeat.
            if (enter && !e.isAutoRepeat) panel.openRequested()
            return true
        }
        var row = panel.rows[panel.index]
        // Enter is checked BEFORE the row's editability: "done" must work from the one row that
        // cannot be edited here (lockBorder) as much as from any other.
        if (enter) { panel.closeRequested(); return true }
        if (!row || !row.editable) return true          // consumed: the panel is modal
        if (e.key === Qt.Key_Left)  { panel.changeRequested(row.key, -1); return true }
        // Space steps forward like Right. Not a peek: the picker's own Space is suppressed for
        // as long as a modal is up (Overview.qml's settings branch), so this takes nothing away.
        if (e.key === Qt.Key_Right || e.key === Qt.Key_Space) { panel.changeRequested(row.key, 1); return true }
        return true
    }
}
