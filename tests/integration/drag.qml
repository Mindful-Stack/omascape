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
            var t = overview.resolveTarget()
            if (!t) { overview.peekCancelled = true; return }
            overview.peekedKey = overview.peekKeyOf(t)
            overview.peeking = true
        }
        function peekRelease(): void { overview.peekRelease() }
        function selectWs(id: int): void { overview.selectedIndex = Logic.indexOfWorkspace(overview.boxes, id) }
        // The mini-map's rows for the currently peeked workspace, as the layer computes them.
        function peekRows(): string {
            // rebuild() first, like drop()/dropPoint()/unfullscreen() above: this IPC call is a
            // synchronous out-of-band read, and Overview's own auto-refresh (onRawEvent ->
            // scheduleRebuild()) is debounced against live Hyprland events. Without a synchronous
            // rebuild here, `overview._windows` can still be the pre-toggle snapshot the moment
            // this fires right after a `hc dispatch` — observed live: a fullscreen toggle plus
            // `wait_fs` (which polls hyprctl directly, not this model) reliably outran the
            // debounce, and peekRows() reported `fullscreen:0` for the window hyprctl already
            // showed as fullscreen. That silently downgraded case 2 to "two ordinary tiles don't
            // overlap" (trivially true) instead of exercising slot recovery at all.
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
    }
}
