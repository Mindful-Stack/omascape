import QtQuick
import Quickshell
import Quickshell.Io
import "logic.js" as Logic

// User settings: ~/.config/omarchy/omyview.json (optional, watched). Every key has a default
// (Logic.parseConfig); a missing file, a parse error or an unknown key never changes behaviour.
QtObject {
    id: cfg
    property bool scrim: true        // dim the desktop behind the picker
    property bool hint: true         // key hints under the workspace grid
    property int workspaces: 10      // always show ids 1..N, even ones Hyprland has not created; 0 = off
    property string motion: "auto"   // "auto" follows Hyprland animations:enabled; "full" | "off"
    // Share-time reminder border (docs/specs/2026-09-12-lock-design.md, addendum): local-only
    // cue on an armed workspace's windows while a share is active. `lockBorder` accepts only the
    // `rgb(hhhhhh)` / `rgba(hhhhhhhh)` hex forms (Logic.parseConfig); anything else falls back to
    // the default. `lockBorderSize` 0 keeps the user's own border size (no `border_size` field).
    property string lockBorder: "rgb(ff4444)"
    property int lockBorderSize: 6

    // Hyprland's own animation switch, probed once per open (async, cheap) and cached. A
    // probe that cannot be read counts as enabled (Logic.hyprAnimationsEnabled).
    property bool hyprAnimations: true
    // True once the first Hyprland probe has answered (or given up): motion never starts on a guess.
    property bool motionResolved: false
    readonly property string motionEffective: Logic.motionPolicy(motion, hyprAnimations)
    function probeMotion() { hyprProc.running = true; probeFallback.restart() }

    readonly property string path: Quickshell.env("HOME") + "/.config/omarchy/omyview.json"

    function apply(raw) {
        var o = Logic.parseConfig(raw)
        cfg.scrim = o.scrim
        cfg.hint = o.hint
        cfg.workspaces = o.workspaces
        cfg.motion = o.motion
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
    Component.onCompleted: probeMotion()
}
