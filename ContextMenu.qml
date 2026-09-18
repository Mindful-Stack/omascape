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
    // The separator is a border, not a row: thin, no label, not hoverable or activatable (see
    // the Repeater delegate below — it gets no MouseArea at all, not just a disabled one).
    readonly property int sepH: 9
    function rowHeight(it) { return (it && it.separator) ? sepH : rowH }

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
    height: {
        var h = 2 * padV
        for (var i = 0; i < items.length; i++) h += rowHeight(items[i])
        return h
    }

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
            // The separator carries no label — it contributes nothing to the width measurement,
            // only to the row Repeater below (as a border, not a row).
            model: menu.items.filter(function (it) { return !it.separator })
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
            // One delegate per item, separator included — the SAME array Logic.menuNavigate and
            // Overview's highlight-preservation fallback walk, so a separator's position is
            // never counted differently here than it is there. Only a non-separator gets the
            // interactive "menuRow" Rectangle (a real one, not merely hidden): the separator's
            // border below is the whole of its visual, with no MouseArea at all — not hoverable,
            // not activatable, and never a keyboard landing place (Logic.menuNavigate skips it).
            Item {
                id: cell
                required property var modelData
                // This delegate's own `index` (its position in `menu.items`) and `menu.index`
                // (the keyboard highlight) are two different things that happen to share a name.
                // Every reference below is qualified (`cell.index` vs `menu.index`) on purpose —
                // an unqualified `index` inside this delegate would silently resolve to the
                // delegate's own, not the highlight.
                required property int index
                width: menu.width
                height: menu.rowHeight(cell.modelData)

                Rectangle {
                    // A border, not a row: a thin hairline centred in the separator's slot.
                    visible: cell.modelData.separator === true
                    anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter
                              leftMargin: menu.padH; rightMargin: menu.padH }
                    height: 1
                    color: Qt.rgba(menu.foreground.r, menu.foreground.g, menu.foreground.b, 0.16)
                }

                Rectangle {
                    id: row
                    objectName: cell.modelData.separator === true ? "" : "menuRow"
                    visible: cell.modelData.separator !== true
                    anchors.fill: parent
                    color: cell.index === menu.index ? menu.selBackground : "transparent"
                    radius: 4
                    Text {
                        anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter
                                  leftMargin: menu.padH; rightMargin: menu.padH }
                        text: (cell.modelData.glyph ? cell.modelData.glyph + "  " : "") + cell.modelData.label
                        color: cell.index === menu.index ? menu.selText : menu.foreground
                        font.family: menu.fontFamily; font.pixelSize: menu.fontSize
                        elide: Text.ElideRight
                    }
                    MouseArea {
                        // Only instantiated under the non-separator Rectangle, and that
                        // Rectangle is invisible for a separator slot — invisible items take no
                        // part in hit testing, so a separator cannot be hovered or pressed.
                        anchors.fill: parent
                        hoverEnabled: true
                        // Rows activate on press. Right AND left accepted: right because the menu
                        // itself is opened with a right press, left because that is the ordinary
                        // way to pick a context-menu item.
                        acceptedButtons: Qt.LeftButton | Qt.RightButton
                        onEntered: menu.hoverRow(cell.index)
                        onPressed: menu.activated(String(cell.modelData.id))
                    }
                }
            }
        }
    }
}
