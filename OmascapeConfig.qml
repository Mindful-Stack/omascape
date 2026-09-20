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

    function apply(raw) {
        var o = Logic.parseConfig(raw)
        cfg.scrim = o.scrim
        cfg.hint = o.hint
        cfg.workspaces = o.workspaces
        cfg.motion = o.motion
        cfg.anchor = o.anchor
        cfg.lockBorder = o.lockBorder
        cfg.lockBorderSize = o.lockBorderSize
    }

    property FileView file: FileView {
        path: cfg.path
        watchChanges: true
        printErrors: false
        onLoaded: cfg.apply(text())
        onFileChanged: reload()
        onLoadFailed: cfg.apply("")
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
