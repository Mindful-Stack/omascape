import QtQuick
import Quickshell
import Quickshell.Io
import "logic.js" as Logic

// Workspace lock state (docs/specs/2026-09-12-lock-design.md). Two watched files, one owner each:
//   ~/.config/omarchy/omyview-locks.json  — written HERE (atomically): { "armed": ["3", "special:scratchpad"] }
//   $XDG_RUNTIME_DIR/omyview/share-state  — written by the compositor observer: "1" | "0"
// `armed` is null until the first load resolves: the Overview must never sync an unresolved set
// (it would disable rules the compositor still holds after a shell restart).
QtObject {
    id: locks
    property var armed: null
    property bool sharing: false
    signal loadedArmed()                       // first successful load, and every accepted change
    signal writeFailed(string why)
    signal invalidFile(string why)

    readonly property string locksPath: Quickshell.env("HOME") + "/.config/omarchy/omyview-locks.json"
    readonly property string statePath: Quickshell.env("XDG_RUNTIME_DIR") + "/omyview/share-state"

    function isArmed(sel) { return armed !== null && armed.indexOf(sel) >= 0 }
    function placeholder(sel) { return isArmed(sel) && sharing }

    // Parse the locks file. A malformed file keeps the previous value (still null on a first
    // load) and is reported; a missing file resolves to [] (first run).
    function applyLocks(raw, missing) {
        if (missing) { if (armed === null) { armed = []; loadedArmed() } return }
        var parsed = Logic.parseLocks(raw)
        if (!parsed.ok) { invalidFile(parsed.error); return }
        armed = parsed.armed
        loadedArmed()
    }
    // Memory first, then disk. Returns false while unresolved (the caller skips the sync).
    function toggle(sel) {
        if (armed === null || !Logic.validLockSelector(sel)) return false
        var next = armed.slice(); var i = next.indexOf(sel)
        if (i >= 0) next.splice(i, 1); else next.push(sel)
        armed = next
        locksFile.setText(JSON.stringify({ armed: next }, null, 2) + "\n")
        return true
    }

    property FileView locksFile: FileView {
        path: locks.locksPath
        watchChanges: true
        atomicWrites: true
        printErrors: false
        onLoaded: locks.applyLocks(text(), false)
        onLoadFailed: function (error) { locks.applyLocks("", true) }
        onFileChanged: reload()
        onSaveFailed: function (error) { locks.writeFailed(String(error)) }
    }
    property FileView stateFile: FileView {
        path: locks.statePath
        watchChanges: true
        printErrors: false
        onLoaded: locks.sharing = (text().trim() === "1")
        onLoadFailed: locks.sharing = false
        onFileChanged: reload()
    }
}
