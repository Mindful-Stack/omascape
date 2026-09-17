import QtQuick

// Right-click menu (docs/specs/2026-09-15-actions-design.md). Display only: Overview's keyCatcher
// owns every key and writes `index`; this emits `activated` and `hoverRow` and draws.
// Deliberately no Qt Quick Controls — the rest of the plugin has none, a Popup's own focus scope
// would fight Keys.priority: BeforeItem on the key catcher, and the offscreen fixture would then
// need Controls too.
Item {
    id: menu

    property var items: []
    property int index: -1                  // keyboard highlight, -1 = none
    property bool open: false

    property color background: "#222"
    property color foreground: "#ddd"
    property color selBackground: "#444"
    property color selText: "#fff"
    property string fontFamily: ""
    property int fontSize: 11
    property int cornerRadius: 8
    required property QtObject motion

    signal activated(string id)
    signal hoverRow(int row)

    readonly property int rowH: Math.round(fontSize * 2.2)
    readonly property int padV: 5
    readonly property int padH: 10

    // Fades in/out on motion.fast with the hover curve, the same treatment the drop wash and the
    // match ring already get, so the menu appears the way everything else in the overview does.
    // `visible` tied to `opacity > 0` means the component takes no input once faded out — the
    // same trick the drop wash uses. Driven by `open`, not by `items` — the parent knows whether
    // the menu is open and says so explicitly, rather than the component inferring it from
    // whether data happens to be present. That also means the parent is free to leave stale
    // `items` in place while this fades out, so the rows/width/height below (which bind straight
    // to `items`, no cache) stay put instead of collapsing to an empty sliver first.
    opacity: open ? 1 : 0
    visible: opacity > 0
    Behavior on opacity { enabled: menu.motion.enabled
        NumberAnimation { duration: menu.motion.fast; easing.type: menu.motion.hover } }

    // Width follows the longest rendered row, plus the fixed 150 floor so a menu with a couple of
    // short items still reads as a menu rather than a stub.
    width: Math.max(150, measure.implicitWidth + 2 * padH)
    height: items.length * rowH + 2 * padV

    // Hidden twin of the visible row's Text below: one child per item, each carrying the SAME
    // text expression, font.family and font.pixelSize as the visible row — including the glyph,
    // which a plain character-count comparison over `.label` would miss (the glyph-bearing items,
    // "Move to"/"Swap with", are exactly the longest labels, so undercounting them elides the row
    // meant to fit). A Column's implicitWidth is the max of its children's, so this gives the true
    // rendered maximum for free: no manual loop, no character-count proxy, no fudge factor. If the
    // two Text expressions/fonts are ever allowed to drift apart, the measurement silently stops
    // matching what is drawn.
    Column {
        id: measure
        visible: false
        Repeater {
            model: menu.items
            Text {
                required property var modelData
                font.family: menu.fontFamily; font.pixelSize: menu.fontSize
                text: (modelData.glyph ? modelData.glyph + "  " : "") + modelData.label
            }
        }
    }

    SoftShadow { target: plate; color: Qt.rgba(0, 0, 0, 0.45); radius: menu.cornerRadius; blur: 18 }
    Rectangle {
        id: plate
        anchors.fill: parent
        radius: menu.cornerRadius
        color: menu.background
        border.width: 1
        border.color: Qt.rgba(menu.foreground.r, menu.foreground.g, menu.foreground.b, 0.12)
    }

    Column {
        x: 0; y: menu.padV
        width: parent.width
        Repeater {
            model: menu.items
            Rectangle {
                id: row
                objectName: "menuRow"
                required property var modelData
                // This delegate's own `index` (its position in `menu.items`) and `menu.index`
                // (the keyboard highlight) are two different things that happen to share a name.
                // Every reference below is qualified (`row.index` vs `menu.index`) on purpose —
                // an unqualified `index` inside this delegate would silently resolve to the
                // delegate's own, not the highlight.
                required property int index
                width: menu.width; height: menu.rowH
                color: row.index === menu.index ? menu.selBackground : "transparent"
                radius: 4
                Text {
                    anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter
                              leftMargin: menu.padH; rightMargin: menu.padH }
                    text: (row.modelData.glyph ? row.modelData.glyph + "  " : "") + row.modelData.label
                    color: row.index === menu.index ? menu.selText : menu.foreground
                    font.family: menu.fontFamily; font.pixelSize: menu.fontSize
                    elide: Text.ElideRight
                }
                MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    // Rows activate on press. Right AND left accepted: right because the menu
                    // itself is opened with a right press, left because that is the ordinary way
                    // to pick a context-menu item.
                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                    onEntered: menu.hoverRow(row.index)
                    onPressed: menu.activated(String(row.modelData.id))
                }
            }
        }
    }
}
