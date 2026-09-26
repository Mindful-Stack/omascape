import QtQuick

// Offscreen stand-in for the Omarchy shell's qs.Ui BarWidget
// (/usr/share/omarchy/shell/Ui/BarWidget.qml). Declares only what omascape's BarWidget.qml uses,
// with the host's semantics; tests/bar-widget-api.sh checks these members still exist on the
// host. CI has no Omarchy shell, so drift is caught locally only.
Item {
    id: root
    property QtObject bar: null
    property string moduleName: ""
    property var settings: ({})
    readonly property bool vertical: bar ? bar.vertical : false
    readonly property int barSize: bar ? bar.barSize : 26

    // Host semantics, verbatim: only undefined/null fall back; "" is returned as "".
    function setting(name, fallback) {
        var value = settings ? settings[name] : undefined
        return value === undefined || value === null ? fallback : value
    }
}
