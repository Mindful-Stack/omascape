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

    // Re-read both files. Quickshell's FileView watches the file's *parent directory*, not the
    // file itself: if that directory does not exist at FileView creation (every fresh login,
    // before the compositor's install chunk has run `mkdir -p $XDG_RUNTIME_DIR/omyview`), the
    // watch never attaches, and no `fileChanged` ever fires for it later, even once the
    // directory and file show up. Overview.qml calls this once, ~400ms after every
    // lockInstall(), by which point the directory very likely exists.
    function refresh() { stateFile.reload(); locksFile.reload() }

    // Reduce a load result onto `armed` (see Logic.applyLocksTo): `status` is "ok" (raw holds
    // the file's fresh text), "missing" (resolves to [] once, on the first load only) or
    // "error:<text>" (keeps the previous value — still null on a first load — and reports it).
    function applyLocks(raw, status) {
        var r = Logic.applyLocksTo(armed, raw, status)
        armed = r.armed
        if (r.error) invalidFile(r.error)
        if (r.changed) loadedArmed()
    }
    // Memory first, then disk. Returns false while unresolved or the selector is invalid (the
    // caller skips the sync).
    function toggle(sel) {
        var next = Logic.toggleSelector(armed, sel)
        if (next === null) return false
        armed = next
        locksFile.setText(JSON.stringify({ armed: next }, null, 2) + "\n")
        return true
    }

    property FileView locksFile: FileView {
        path: locks.locksPath
        watchChanges: true
        atomicWrites: true
        printErrors: false
        onLoaded: locks.applyLocks(text(), "ok")
        // FileViewError distinguishes "no such file" (first run: resolves to []) from every
        // other failure (permission, a directory in its place, …): those must NOT be treated as
        // "missing", or a merely-unreadable file would silently reset armed to [] and disable
        // every rule the compositor holds.
        onLoadFailed: function (error) {
            locks.applyLocks("", error === FileViewError.FileNotFound
                                  ? "missing" : "error:" + FileViewError.toString(error))
        }
        onFileChanged: reload()
        onSaveFailed: function (error) { locks.writeFailed(FileViewError.toString(error)) }
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
