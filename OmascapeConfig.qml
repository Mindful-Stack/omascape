import QtQuick
import Quickshell
import Quickshell.Io
import "logic.js" as Logic

// User settings: ~/.config/omarchy/omascape.json (optional, watched). Every key has a default
// (Logic.parseConfig); a missing file, a parse error or an unknown key never changes behaviour.
QtObject {
    id: cfg
    property bool scrim: true        // dim the desktop behind the picker
    property bool hint: true         // key hints under the workspace grid
    property int workspaces: 10      // always show ids 1..N, even ones Hyprland has not created; 0 = off
    property string motion: "auto"   // "auto" follows Hyprland animations:enabled; "full" | "off"
    // "center" (default) keeps the centred card; "bar" hangs the picker off the top bar,
    // full-width. Bar mode needs an actual top bar to hang from — a side, bottom or hidden bar
    // reserves nothing at the top and falls back to centred on its own (Overview.qml barMode).
    property string anchor: "center"
    // Activation policy (docs/specs/2026-09-18-activate-select-design.md).
    // "enter"  — a digit jumps and a click focuses, both leaving the overview.
    // "select" — both select instead; Enter, the same digit again, or a double-click commits.
    property string activate: "enter"
    // Share-time reminder frame (docs/specs/2026-09-12-lock-design.md, addendum): the local-only
    // frame omascape draws around a monitor that is SHOWING an armed workspace while a share is
    // running (LockFrame.qml — four layer-shell strips, blanked in every capture). `lockBorder`
    // accepts only the `rgb(hhhhhh)` / `rgba(hhhhhhhh)` hex forms (Logic.parseConfig); anything
    // else falls back to the default. `lockBorderSize` is the strip thickness in px;
    // 0 turns the reminder off. The key names predate round 4's switch from window borders to
    // the frame and are kept so existing config files keep working.
    property string lockBorder: "rgb(ff4444)"
    property int lockBorderSize: 6

    // Hyprland's own animation switch, probed once per open (async, cheap) and cached. A
    // probe that cannot be read counts as enabled (Logic.hyprAnimationsEnabled).
    property bool hyprAnimations: true
    // True once the first Hyprland probe has answered (or given up): motion never starts on a guess.
    property bool motionResolved: false
    readonly property string motionEffective: Logic.motionPolicy(motion, hyprAnimations)
    function probeMotion() { hyprProc.running = true; probeFallback.restart() }

    // The wallpaper the shell is currently showing, as a file URL. Re-probed on every open so
    // a theme switch between summons is picked up; the picker is transient, so polling would
    // be waste. Empty until the first probe answers, which the view treats as "no wallpaper".
    property string wallpaperUrl: ""
    function probeWallpaper() { wallpaperProc.running = true }

    readonly property string path: Quickshell.env("HOME") + "/.config/omarchy/omascape.json"
    // The shell's own config, watched read-only for one key: whether the bar is transparent.
    // Not ours to write, and nothing here ever does.
    property bool barTransparent: false
    readonly property string shellPath: Quickshell.env("HOME") + "/.config/omarchy/shell.json"

    // Emitted when the file exists but could not be used. The settings still resolve to their
    // defaults -- parseConfig is total -- so this is purely how the user finds out.
    signal invalidFile(string why)

    // Emitted when the file could not be written. Mirrors OmascapeLocks: FileView raises
    // `onSaveFailed`, and this is the component's own signal on top of it.
    signal writeFailed(string why)

    // Emitted at the end of apply(), i.e. every reload (initial load, watcher-triggered
    // re-read, or a load failure). The settings panel's optimistic layer (Overview.qml's
    // settingsPending) listens for this to stop guessing a key once the file agrees with it.
    signal configChanged()

    // True once `file.text()` is something save() can trust: either a successful load, or a
    // load failure confirmed to be "no such file" (empty text is then the right starting point
    // -- Logic.configWithKey treats "" as {} and creates the file). Any other load failure
    // (permission denied, a directory sitting where the file should be, ...) leaves this false:
    // text() may be stale or empty while the real file on disk is neither, and writing would
    // destroy it. Same missing/error split as OmascapeLocks.qml:72-74, for the same reason --
    // apply("") is still fine for display, since parseConfig is total either way.
    property bool readableForSave: false

    function apply(raw) {
        var why = Logic.configParseError(raw)
        if (why.length > 0) cfg.invalidFile(why)
        var o = Logic.parseConfig(raw)
        cfg.scrim = o.scrim
        cfg.hint = o.hint
        cfg.workspaces = o.workspaces
        cfg.activate = o.activate
        cfg.motion = o.motion
        cfg.anchor = o.anchor
        cfg.lockBorder = o.lockBorder
        cfg.lockBorderSize = o.lockBorderSize
        cfg.configChanged()
    }

    // Persist every given setting in ONE write. Reads the file's CURRENT text rather than
    // rebuilding from the parsed properties, so keys this build does not know about are carried
    // through (see Logic.configWithKey). Refused, not overwritten, when the file is not known to
    // be either loaded or missing (readableForSave) or when any key fails to apply
    // (configWithKey returns ""): the user may be mid-edit, and replacing their work with a
    // guessed object would be worse than doing nothing.
    //
    // Always the WHOLE set the caller still has unconfirmed, not just the newest key. See the
    // caller's comment (Overview.qml applySettingChange): a second write cancels the first and
    // builds its payload from stale cached text (FileView.text() only updates on
    // operationFinished, and saveAsync captures its payload before cancelling an in-flight write
    // -- verified in Quickshell 0.3.1's src/io/fileview.cpp:321-338). So each payload must carry
    // every unconfirmed change rather than only the newest, making a cancelled write's payload a
    // subset of the next one's.
    function saveAll(values) {
        if (!readableForSave) {
            cfg.writeFailed("the file could not be read; fix that before changing settings here")
            return false
        }
        var next = file.text()
        for (var k in values) {
            next = Logic.configWithKey(next, k, values[k])
            if (next.length === 0) {
                cfg.writeFailed("the file could not be parsed; fix it before changing settings here")
                return false
            }
        }
        file.setText(next)
        return true
    }

    property FileView file: FileView {
        path: cfg.path
        watchChanges: true
        atomicWrites: true
        printErrors: false
        onLoaded: { cfg.apply(text()); cfg.readableForSave = true }
        // Our OWN write reaches the properties from here, not from the watcher. Verified
        // against Quickshell 0.3.1 on the live engine: the inotify event for an atomic write
        // lands while the writer is still FileView::liveOperation, so the `reload()` below runs
        // `loadAsync`, hits its `if (!liveOperation || pathInFlight != targetPath)` guard
        // (src/io/fileview.cpp:302) and starts no read at all. `operationFinished` then emits
        // `saved` -- never `loaded` -- and marks the view prepared again, so even a later
        // `text()` finds the cache fresh and never reloads either. Without this line a setting
        // changed from the panel is written to disk and NEVER reaches config.*: the picker keeps
        // the old value until an external edit or a shell restart. Observed as "changing a
        // setting doesn't work... or maybe it did after a while".
        //
        // text() here is the data the writer just committed (operationFinished calls
        // updateState with the writer's state before emitting), so this applies what is on
        // disk, not a guess -- and does it without a second read.
        onSaved: cfg.apply(text())
        onFileChanged: reload()
        // FileViewError distinguishes "no such file" (first run: text() == "" is genuinely the
        // whole file) from every other failure (permission, a directory in its place, ...): those
        // must NOT be treated as readable, or save() would trust an empty/stale text() and
        // silently replace content it never actually saw.
        onLoadFailed: function (error) {
            cfg.apply("")
            cfg.readableForSave = (error === FileViewError.FileNotFound)
        }
        onSaveFailed: function (error) { cfg.writeFailed(FileViewError.toString(error)) }
    }

    property FileView shellFile: FileView {
        path: cfg.shellPath
        watchChanges: true
        printErrors: false
        onLoaded: cfg.barTransparent = Logic.shellBarTransparent(text())
        onFileChanged: reload()
        onLoadFailed: cfg.barTransparent = false
    }

    property Process wallpaperProc: Process {
        command: ["readlink", "-f", Quickshell.env("HOME") + "/.local/state/omarchy/current/background"]
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: cfg.wallpaperUrl = Logic.wallpaperUrl(text)
        }
    }

    property Process hyprProc: Process {
        command: ["hyprctl", "-j", "getoption", "animations:enabled"]
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                cfg.hyprAnimations = Logic.hyprAnimationsEnabled(text)
                cfg.motionResolved = true
            }
        }
        onExited: cfg.motionResolved = true
    }

    // A missing/failing hyprctl must not leave motion off forever: give the probe 500ms, then
    // resolve anyway (a probe that never lands counts as enabled, per Logic.hyprAnimationsEnabled's
    // fail-open default).
    property Timer probeFallback: Timer { interval: 500; onTriggered: cfg.motionResolved = true }

    // Warm the cache so the very first open already follows the compositor.
    Component.onCompleted: { probeMotion(); probeWallpaper() }
}
