import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import "logic.js" as Logic

ShellRoot {
    Overview { id: overview }
    IpcHandler {
        target: "dragtest"
        function drop(address: string, workspace: int, x: int, y: int): void {
            overview.rebuild()
            var win = overview._windowByAddress[address]
            var box = overview.boxForWs(workspace)
            var mon = overview._monByName[box.monitorName]
            var rect = Logic._tileRect({ax:x,ay:y,sw:win.sw,sh:win.sh},mon,box,overview.params)
            overview.submitDrop(address,workspace,rect.x,rect.y)
        }
        // Drop so that the dragged tile's CENTRE maps to real global point (gx, gy) in `workspace`.
        function dropPoint(address: string, workspace: int, gx: int, gy: int): void {
            overview.rebuild()
            var box = overview.boxForWs(workspace), mon = overview._monByName[box.monitorName]
            var t = overview.tileRectFor(address)
            var r = Logic._tileRect({ax:gx, ay:gy, sw:1, sh:1}, mon, box, overview.params)
            overview.submitDrop(address, workspace, r.x - t.w / 2, r.y - t.h / 2, r.x, r.y)
        }
        function openOverview(): void { overview.open() }
        function pending(): string { return JSON.stringify(overview.pendingMoves) }
        function unfullscreen(address: string): void { overview.rebuild(); overview.unfullscreen(address) }
        function pendingFullscreen(): string { return JSON.stringify(overview.pendingFullscreen) }

        // Peek (docs/specs/2026-09-18-peek-design.md). `peekHold` sets the hold state directly,
        // bypassing the key handler — so it can exercise the layer, the mini-map and the
        // cancellation paths, but NOT Space's routing, which is the UI suite's job and (for real
        // auto-repeat) wtype's. `peekState` is the probe's only window into the hold.
        function peekState(): string {
            return JSON.stringify({ peeking: overview.peeking, key: overview.peekedKey,
                                    cancelled: overview.peekCancelled })
        }
        function peekHold(): void {
            // rebuild() first (review round 2, item 4): resolveTarget() reads `boxes`, which only
            // rebuild() assigns. Called right after selectWs()/spawn_window() in the probe, whose
            // own polling only confirms hyprctl's view, never this model's — an un-rebuilt `boxes`
            // silently resolves no target here (fails loudly downstream, at worst turning a later
            // case UNVERIFIED instead of exercising what it claims to).
            overview.rebuild()
            var t = overview.resolveTarget()
            if (!t) { overview.peekCancelled = true; return }
            overview.peekedKey = overview.peekKeyOf(t)
            overview.peeking = true
        }
        function peekRelease(): void { overview.peekRelease() }
        // Same rebuild()-first reasoning as peekHold() above: indexOfWorkspace() reads `boxes`,
        // stale without it the instant this runs right after spawn_window() (which polls hyprctl,
        // not this model).
        function selectWs(id: int): void { overview.rebuild(); overview.selectedIndex = Logic.indexOfWorkspace(overview.boxes, id) }
        // Sets the keyboard cursor target directly — the probe's only way to peek a WINDOW rather
        // than the selected workspace (`Logic.target`: `cursorAddress` outranks `selectedId`), and
        // also how it exercises "navigation retargets a live hold" from outside a key handler.
        // rebuild() first so a just-spawned window's address is actually in `_windowByAddress`
        // before it is aimed at.
        function setCursor(a: string): void { overview.rebuild(); overview.setCursor(a) }
        // The mini-map's rows for the currently peeked workspace, as the layer computes them.
        function peekRows(): string {
            // requestRefresh() + rebuild(), not rebuild() alone (review round 2, item 3): rebuild()
            // only re-reads whatever Quickshell's Hyprland module currently has cached in each
            // toplevel's `lastIpcObject` — it is requestRefresh() (Hyprland.refreshToplevels(),
            // Overview.qml) that actually asks Hyprland for fresh data, and that fetch is
            // ASYNCHRONOUS (see Overview.qml's own settleTimer, which polls after requesting a
            // refresh rather than trusting one synchronous read). A single rebuild() closed the
            // race on this machine but is not guaranteed to on a slower one; the caller
            // (peek-probe.sh case 2) additionally polls peekRows() rather than trusting one call.
            overview.requestRefresh()
            overview.rebuild()
            var t = overview.resolveTarget()
            if (!t || t.kind !== "workspace") return "[]"
            var b = overview.boxForWs(t.id), mon = b ? overview._monByName[b.monitorName] : null
            if (!mon) return "[]"
            var wins = []
            for (var i = 0; i < overview._windows.length; i++)
                if (overview._windows[i].workspaceId === t.id) wins.push(overview._windows[i])
            return JSON.stringify(Logic.peekTiles(wins, mon, 1200, 750, overview.params))
        }
        // The peek's fitted box in GLOBAL compositor pixel coordinates, for a `grim -g` crop
        // (review round 2, item 1: cropping to the peek is what makes case 3 discriminate at all —
        // an uncropped capture of the whole nested screen picks up tile-appear animations and the
        // peek's own scrim/backdrop churn regardless of whether the capture inside it is live).
        // Replicates PeekLayer.qml's own geometry (`boxW`/`boxH` = 60% of the panel, `frame`
        // centred inside it, `fit` from Logic.peekFit against the window's own size or the target
        // monitor's logical size) from data already exposed to this handler — `_monByName`,
        // `_windowByAddress`, `boxForWs`, `Logic.peekFit` — rather than exposing PeekLayer's
        // internal ids through Overview.qml just for this reporter. The panel is a PanelWindow
        // anchored to all four edges of `targetScreen` (Overview.qml ~1592-1598), so its local
        // origin IS the monitor's own top-left; global = the monitor's Hyprland-reported x/y
        // (buildInput()) plus that local offset. Assumes scale 1, true of every monitor
        // `start_nested` creates — PeekLayer's own `fit` binding divides by scale for exactly the
        // case where that does not hold, which this reporter does not need to handle for this rig.
        function peekBox(): string {
            overview.rebuild()
            var t = overview.resolveTarget()
            if (!t) return "null"
            var mon, win = null
            if (t.kind === "window") {
                win = overview._windowByAddress[t.address]
                if (!win) return "null"
                var wb = overview.boxForWs(win.workspaceId)
                mon = wb ? overview._monByName[wb.monitorName] : null
            } else {
                var box = overview.boxForWs(t.id)
                mon = box ? overview._monByName[box.monitorName] : null
            }
            if (!mon) return "null"
            var boxW = Math.round(mon.width * 0.6), boxH = Math.round(mon.height * 0.6)
            var fit
            if (t.kind === "window") {
                fit = Logic.peekFit(win.sw, win.sh, boxW, boxH)
            } else {
                var s = mon.scale > 0 ? mon.scale : 1
                fit = Logic.peekFit(mon.width / s, mon.height / s, boxW, boxH)
            }
            var x = mon.x + (mon.width - fit.w) / 2, y = mon.y + (mon.height - fit.h) / 2
            return JSON.stringify({ x: Math.round(x), y: Math.round(y),
                                    w: Math.round(fit.w), h: Math.round(fit.h) })
        }
    }
}
