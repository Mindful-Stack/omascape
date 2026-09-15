// Omyview — v2. Canvas + boxes + live tiles. See DESIGN.md / docs/specs, docs/plans.
import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import qs.Commons
import qs.Ui
import "logic.js" as Logic

Item {
    id: root
    property bool opened: false
    property var targetScreen: null

    property var boxes: []
    property var handleByAddress: ({})
    property int selectedIndex: -1
    readonly property int selectedId:
        (selectedIndex >= 0 && selectedIndex < boxes.length) ? boxes[selectedIndex].workspaceId : -1

    // Find (docs/specs/2026-09-11-find-design.md). There is no mode: a non-empty query is
    // what changes the keys. `matches` is the ranked result of Logic.findMatches over the last
    // buildInput() window list; `matchIndex` is the ranked selection.
    property string query: ""
    property var matches: []
    property int matchIndex: -1
    property int preQuerySelectedId: -1     // box selection to restore when the query clears
    readonly property string selectedMatchAddress:
        (matchIndex >= 0 && matchIndex < matches.length) ? matches[matchIndex].address : ""
    property var _windows: []               // buildInput().windows, layout order, for re-ranking

    // Scratchpad row (docs/specs/2026-09-12-scratchpad-design.md): shown on demand for this
    // summon only. buildInput() remaps Hyprland's dynamic special id onto Logic.SCRATCHPAD_ID.
    property bool scratchpadShown: false
    // Hide the row (toggle-off and every open()). A drop into the scratchpad still unacknowledged
    // must go with it: a window on a hidden scratchpad is not in the input, so nothing could
    // acknowledge it and applyTiles would keep the optimistic tile until the deadline. The next
    // rebuild removes the row, or returns the tile to its authoritative place if the move has
    // not landed yet.
    function hideScratchpad() {
        scratchpadShown = false
        for (var a in pendingMoves)
            if (pendingMoves[a].workspaceId === Logic.SCRATCHPAD_ID) delete pendingMoves[a]
    }
    function toggleScratchpad() {
        if (scratchpadShown) hideScratchpad(); else scratchpadShown = true
        // rebuild(), not scheduleRebuild(): a hidden scratchpad's toplevels already report live
        // geometry (Hyprland keeps tracking them off-screen), so there is no stale data here to
        // wait out with a refresh + settle.
        rebuild()
        if (scratchpadShown) {
            // Showing the row can append it below the fold on an overflowing layout: scroll it
            // fully into view without moving the keyboard selection (a different intent).
            var b = boxForWs(Logic.SCRATCHPAD_ID)
            if (b && b.y + b.h > flick.contentY + flick.height) flick.contentY = b.y + b.h - flick.height
        }
        // A mid-drag toggle changes what boxes/tiles exist under the pointer; without this the
        // drop preview would stay stale until the next pointer move.
        updateDropTarget()
    }

    // theme — tone steps, not lines (see docs/specs/2026-09-10-restyle-design.md)
    property color background: Color.menu.background
    property color foreground: Color.menu.text
    property color scrim: Color.menu.scrim
    property color selBackground: Color.menu.selectedBackground
    property color selText: Color.menu.selectedText
    function tone(a) { return Qt.rgba(foreground.r, foreground.g, foreground.b, a) }
    readonly property color wellColor: tone(Style.normalFillAlpha)      // occupied workspace well
    readonly property color emptyWellColor: tone(Style.normalFillAlpha / 2)   // one step lower
    // Typography follows the shell: the menu family and the theme's size tokens, so the picker
    // tracks `omarchy display text size` like every other summoned surface.
    readonly property string fontFamily: Style.font.menuFamily
    readonly property int labelSize: Style.font.bodySmall
    readonly property int captionSize: Style.font.caption
    // Well under a drag: the only workspace-level drop cue (tiled drops also preview the
    // insertion half on the anchor tile), so it must read even on the focused workspace.
    readonly property color dropWellColor: tone(Style.selectedFillAlpha)
    readonly property color hairline: tone(0.12)                          // between previews
    readonly property color accent: selText
    readonly property bool darkTheme:
        (0.299 * background.r + 0.587 * background.g + 0.114 * background.b) < 0.5
    // Badge chip: the card colour, nearly opaque, so the number reads over any preview.
    readonly property color badgeColor: Qt.rgba(background.r, background.g, background.b, 0.88)
    function wsLabel(id) { return Logic.isScratchpad(id) ? "S" : id === 10 ? "0" : String(id) }   // matches the 1–0 keys
    // The card owns its radius: Style.cornerRadius mirrors Hyprland rounding, which may be 0.
    readonly property int boxRadius: 8
    readonly property int cardRadius: boxRadius + card.pad

    OmyviewConfig { id: config }

    // Motion vocabulary. Every duration and easing in the picker comes from here; tiles get it
    // as a property (they never import the shell). `scale` is a test hook (0 = instant);
    // config `motion: "off"` (or "auto" with Hyprland animations disabled) zeroes everything.
    // Motion also stays off until the first probe has answered (config.motionResolved): with
    // the component kept loaded, a fresh summon can race a probe that hasn't landed yet, and
    // motion must never start on a guess.
    readonly property QtObject motion: QtObject {
        property real scale: 1
        readonly property bool enabled: config.motionEffective !== "off" && config.motionResolved && scale > 0
        readonly property int fast:   enabled ? Math.round(90 * scale) : 0
        readonly property int normal: enabled ? Math.round(160 * scale) : 0
        readonly property int enter:  enabled ? Math.round(200 * scale) : 0
        readonly property int exit:   enabled ? Math.round(120 * scale) : 0
        readonly property int move: Easing.OutCubic       // layout movement
        readonly property int hover: Easing.OutQuad       // hover, lift, release
        readonly property int entrance: Easing.OutBack    // overshoot is deliberately small; raise towards Qt's 1.70158 default if the entrance feels flat
        readonly property real overshoot: 1.2             // Qt default is 1.70158; "small"
        // Motion switched off while an open/close animation is in flight (a late probe result,
        // or a config edit): stop it and land on the final values at once. Layout Behaviors and
        // tile appear animations already in flight finish at their correct targets on their own
        // (≤ 160 ms) — only the enter/exit fade needs this nudge. Handled here rather than in a
        // Connections element: Connections has its own `enabled` property, so an
        // `onEnabledChanged` handler inside one is rejected by Qt 6.4 as a duplicate method.
        onEnabledChanged: if (!enabled) root._showVisuals(root.opened)
    }
    // Layout Behaviors (frame, tiles, boxes, card size) run only when motion is on and the
    // entrance is not playing: delegates are created at their final geometry, and the settle
    // rebuilds during the first 200 ms must place, not glide. And never while closed — reconcile
    // rebuilds keep running after close, and a glide started then would finish under the next entrance.
    // Also never during openSettle: mapping the surface can change panel.width and trigger a
    // synchronous rebuild before the entrance even starts, and that rebuild must place too.
    readonly property bool layoutMotion: motion.enabled && opened && !enterAnim.running && !openSettle.running

    // headerH is the chip band per monitor group; logic.js lays it out only when more than
    // one monitor has workspaces (see Logic.layout), so a single monitor gets no band.
    readonly property var params: ({
        maxCols: 5, minCellW: 140, maxCellW: 380, cellInset: 3, cellSpacing: 4,
        rowSpacing: 8, headerH: 22, groupInset: 6, minTileW: 8, minTileH: 6, slotGapTolerance: 24
    })
    // Backdrop behind the focused monitor's group: a whisper of accent, so which screen is
    // live reads peripherally without touching the three well shades.
    readonly property color groupBackdropColor: Qt.rgba(accent.r, accent.g, accent.b, 0.08)
    // Nerd Font glyphs (nf-md-laptop / nf-md-monitor); Omarchy's menu font carries them.
    // Internal panels are eDP/LVDS/DSI connectors, everything else is an external screen.
    function monitorIcon(name) { return /^(eDP|LVDS|DSI)/i.test(name) ? "\u{F0322}" : "\u{F0379}" }

    property var groups: []
    // Monitor chips and the focused-group backdrop key on how many *monitor* groups there are;
    // the scratchpad group is extra and always carries its own chip.
    readonly property bool multiMonitor: groups.filter(function (g) { return !g.special }).length > 1
    // Card interior logical width available to the canvas: panel.width (logical, not
    // screen.width*dpr) minus the card's own padding and a little breathing room.
    readonly property real availCanvasW: panel.width > 0 ? panel.width - 2 * card.pad - 16 : 1600
    onAvailCanvasWChanged: if (opened) rebuild()

    function focusedScreen() {
        var mon = Hyprland.focusedMonitor, screens = Quickshell.screens || []
        for (var i = 0; i < screens.length; i++)
            if (mon && screens[i].name === mon.name) return screens[i]
        return screens.length ? screens[0] : null
    }

    // Build handleByAddress from the wl toplevels (address <- HyprlandToplevel.address).
    function buildHandles() {
        var map = {}, tls = ToplevelManager.toplevels ? ToplevelManager.toplevels.values : []
        for (var i = 0; i < tls.length; i++) {
            var t = tls[i], h = t.HyprlandToplevel
            if (h && h.address) map["0x" + h.address] = t
        }
        root.handleByAddress = map
    }

    function buildInput() {
        var mons = [], hmons = Hyprland.monitors ? Hyprland.monitors.values : []
        for (var i = 0; i < hmons.length; i++) {
            var m = hmons[i]
            mons.push({ name: m.name, x: m.x, y: m.y, width: m.width, height: m.height,
                        scale: m.scale, reserved: m.lastIpcObject ? m.lastIpcObject.reserved : [0,0,0,0],
                        transform: m.lastIpcObject ? m.lastIpcObject.transform : 0 })
        }
        var monNames = {}
        for (var mi0 = 0; mi0 < mons.length; mi0++) monNames[mons[mi0].name] = true
        var focusedMonitorName = Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : ""
        var wss = [], hws = Hyprland.workspaces ? Hyprland.workspaces.values : []
        var focusedWsId = Hyprland.focusedWorkspace ? Hyprland.focusedWorkspace.id : -1
        var wins = [], haveScratch = false
        for (var j = 0; j < hws.length; j++) {
            var ws = hws[j]; if (!ws) continue
            var special = ""
            if (ws.id < 0) {
                // Special workspaces: only the scratchpad, only while shown, identified by name.
                if (!scratchpadShown || ws.name !== Logic.SCRATCHPAD_NAME) continue
                special = "scratchpad"; haveScratch = true
            }
            var wsId = special ? Logic.SCRATCHPAD_ID : ws.id
            var mon = ws.monitor
            // The scratchpad record only: Hyprland can report a monitor the layout will never
            // know about (already removed, or none at all), which for a numbered workspace's "?"
            // fallback means layout() silently skips it — but the scratchpad row must still
            // appear, so fall back to the focused monitor by name instead.
            var monName = special ? ((mon && monNames[mon.name]) ? mon.name : focusedMonitorName)
                                  : (mon ? mon.name : "?")
            wss.push({ id: wsId, monitorName: monName, special: special,
                       focused: ws.id === focusedWsId,
                       occupied: ws.toplevels && ws.toplevels.values.length > 0 })
            var tls = ws.toplevels ? ws.toplevels.values : []
            for (var t = 0; t < tls.length; t++) {
                var o = tls[t] ? tls[t].lastIpcObject : null
                if (!o || !o.at || !o.size || !o.address) continue
                wins.push({ address: o.address, cls: o["class"] || "", title: o.title || "",
                            ax: o.at[0], ay: o.at[1], sw: o.size[0], sh: o.size[1],
                            workspaceId: wsId,
                            // Reserved for the workspace-lock feature; nothing reads this yet.
                            special: special, floating: !!o.floating,
                            fullscreen: Logic.fullscreenMode(o),
                            grouped: !!(o.grouped && o.grouped.length) })
            }
        }
        // Hyprland drops an emptied special workspace; the row is still a place to drop windows.
        if (scratchpadShown && !haveScratch)
            wss.push({ id: Logic.SCRATCHPAD_ID, monitorName: focusedMonitorName, special: "scratchpad",
                       focused: false, occupied: false })
        return { monitors: mons,
                 workspaces: Logic.padWorkspaces(wss, config.workspaces, focusedMonitorName),
                 windows: wins, focusedMonitorName: focusedMonitorName,
                 availW: root.availCanvasW, params: root.params }
    }

    // Reconcile the tiles ListModel in place (drag-safe: never touch the dragged address).
    property string draggingAddress: ""
    property var pendingMoves: ({})
    // addr -> { mode, deadline }: an un-fullscreen was dispatched; the badge stays hidden until
    // fresh data reports that mode, or the deadline passes (rejected: badge returns).
    property var pendingFullscreen: ({})
    property var dragTile: null
    property int dropTargetWs: -1
    property string dropTargetAddress: ""
    property string dropTargetSide: ""   // "left"|"right"|"top"|"bottom" while a tiled drag hovers a tile
    property real dragViewportX: 0
    property real dragViewportY: 0
    Timer {
        id: reconcileTimer
        interval: 120; repeat: true
        onTriggered: root._reconcileStep()
    }
    function setTileRoles(addr, roles) {
        for (var i = 0; i < tilesModel.count; i++)
            if (tilesModel.get(i).address === addr) { tilesModel.set(i, roles); return }
    }
    // ---- Find -------------------------------------------------------------------------
    // Query edit: the best match for the *new* query is always the selection (a window that
    // won for "s" must not stay selected once "slack" ranks another first).
    function setQuery(q) {
        if (!query.length && q.length) preQuerySelectedId = selectedId
        query = q
        if (!q.length) {
            matches = []; matchIndex = -1
            applyMatchRoles()
            restorePreQuerySelection()
            return
        }
        matches = Logic.findMatches(q, _windows)
        matchIndex = matches.length ? 0 : -1
        applyMatchRoles()
        followMatch()
    }
    // Background rebuild while a query is active: keep the selected address if it still
    // matches; otherwise the old index clamped to the new last index (the successor rule).
    function rematchAfterRebuild() {
        if (!query.length) return
        var keep = selectedMatchAddress, oldIndex = matchIndex
        var next = Logic.findMatches(query, _windows)
        if (!sameAddresses(matches, next)) matches = next
        var idx = -1
        for (var i = 0; i < matches.length; i++) if (matches[i].address === keep) { idx = i; break }
        if (idx < 0 && matches.length) idx = Math.min(Math.max(oldIndex, 0), matches.length - 1)
        matchIndex = idx
        var changed = selectedMatchAddress !== keep
        applyMatchRoles()
        followMatch(changed)
    }
    // Arrows with a query: the normal spatial rule, restricted to workspaces that hold a match.
    function navigateMatch(dir) {
        if (!matches.length) return
        var ws = []
        for (var i = 0; i < matches.length; i++) {
            var win = _windowByAddress[matches[i].address]
            ws.push(win ? win.workspaceId : -1)
        }
        matchIndex = Logic.navigateMatches(boxes, ws, matchIndex, dir)
        applyMatchRoles()
        followMatch()
    }
    function cycleMatch(step) {
        if (!matches.length) return
        var i = matchIndex < 0 ? 0 : matchIndex
        matchIndex = (i + step + matches.length) % matches.length
        applyMatchRoles()
        followMatch()
    }
    function applyMatchRoles() {
        var isMatch = {}
        for (var i = 0; i < matches.length; i++) isMatch[matches[i].address] = true
        var sel = selectedMatchAddress
        for (var t = 0; t < tilesModel.count; t++) {
            var cur = tilesModel.get(t)
            var next = { matched: !!isMatch[cur.address], selectedMatch: cur.address === sel }
            if (rowDiffers(cur, next)) tilesModel.set(t, next)
        }
    }
    // Are two ranked match arrays the same sequence of addresses? Used to avoid reassigning
    // `matches` (and firing matchesChanged) on every settle tick when the ranking is unchanged.
    function sameAddresses(a, b) {
        if (a.length !== b.length) return false
        for (var i = 0; i < a.length; i++) if (a[i].address !== b[i].address) return false
        return true
    }
    // Move the box selection to the selected match's workspace, scrolling it into view unless
    // `scroll` is explicitly false AND the match stayed on the same box — a same-match settle
    // tick must not scroll (it would yank the viewport back on every tick), but a match that
    // moved to another workspace (a rule, another actor) must still be scrolled to, or the
    // frame is left stranded off-screen on an overflowing layout.
    function followMatch(scroll) {
        var addr = selectedMatchAddress; if (!addr) return
        var win = _windowByAddress[addr]; if (!win) return
        var idx = Logic.indexOfWorkspace(boxes, win.workspaceId)
        if (idx < 0) return
        var moved = idx !== selectedIndex          // the match changed workspace, or boxes shifted
        selectedIndex = idx
        if (scroll !== false || moved) ensureSelectedVisible()
    }
    // Query cleared: back to the pre-query workspace; if it is gone, the focused workspace,
    // then the first box. Deliberately not rebuild()'s nearest-position rule — after a search
    // there is no positional expectation to preserve.
    function restorePreQuerySelection() {
        var idx = Logic.hasWs(preQuerySelectedId) ? Logic.indexOfWorkspace(boxes, preQuerySelectedId) : -1
        if (idx < 0) for (var b = 0; b < boxes.length; b++) if (boxes[b].focused) { idx = b; break }
        if (idx < 0 && boxes.length) idx = 0
        preQuerySelectedId = -1
        selectedIndex = idx
        ensureSelectedVisible()
    }
    function acceptMatch() {
        var addr = selectedMatchAddress; if (!addr) return
        Hyprland.dispatch('hl.dsp.focus({ window = "address:' + addr + '" })'); root.close()
    }
    // open(): forget any query from the previous summon, without touching the selection
    // (open() resets that itself).
    function resetFind() {
        query = ""; matches = []; matchIndex = -1; preQuerySelectedId = -1
        applyMatchRoles()
    }
    // Badge click: turn fullscreen off for `addr` silently (no focus, no workspace switch, the
    // overview stays open). Optimistic: the badge hides now and the tile keeps its recovered
    // slot, which is where the window lands anyway.
    function unfullscreen(addr) {
        var win = _windowByAddress[addr]
        if (!win || !win.fullscreen) return
        pendingFullscreen[addr] = { mode: 0, deadline: Date.now() + 1800 }
        setTileRoles(addr, { fsPending: true })
        Hyprland.dispatch(Logic.unfullscreenLua(addr))
        scheduleRebuild()
        reconcileTimer.restart()
    }
    function reconcileFullscreen(windows) {
        var byAddress = {}
        for (var i = 0; i < windows.length; i++) byAddress[windows[i].address] = windows[i]
        for (var addr in pendingFullscreen) {
            var pending = pendingFullscreen[addr], win = byAddress[addr]
            if (win && win.fullscreen !== pending.mode && Date.now() < pending.deadline) continue
            delete pendingFullscreen[addr]
            setTileRoles(addr, { fsPending: false })
        }
    }
    // Tiles that can anchor a tiled insert inside workspace `workspaceId`: the tiled, settled
    // tiles other than the dragged one, in stacking order.
    function tiledAnchorCandidates(addr, workspaceId) {
        var out = []
        for (var i = 0; i < tilesModel.count; i++) {
            var tile = tilesModel.get(i), win = _windowByAddress[tile.address]
            if (tile.address === addr || tile.wsid !== workspaceId || !win ||
                win.floating || tile.layer === 0 || pendingMoves[tile.address]) continue
            out.push({ x: tile.wx, y: tile.wy, w: tile.ww, h: tile.wh, address: tile.address })
        }
        return out
    }
    // Where a tiled drop of `win` centred at (cx, cy) inside `targetWs` would insert, or null
    // when it should do nothing. One eligibility check shared by the drag preview and the
    // release, so what is highlighted is exactly what a release does (see Logic.tiledDropPlan).
    function tiledDropPlan(addr, win, targetWs, cx, cy) {
        var box = boxForWs(targetWs), mon = box ? _monByName[box.monitorName] : null
        if (!box || !mon) return null
        var same = targetWs === win.workspaceId
        var own = same ? tileRectFor(addr) : null       // the model rect: the recovered slot for a fullscreen window
        return Logic.tiledDropPlan(tiledAnchorCandidates(addr, targetWs), same, own, cx, cy)
    }
    function tileRectFor(addr) {
        for (var i = 0; i < tilesModel.count; i++) {
            var t = tilesModel.get(i)
            if (t.address === addr) return { x: t.wx, y: t.wy, w: t.ww, h: t.wh, wsid: t.wsid }
        }
        return null
    }
    // Tiled drop: re-tile the window at the drop point exactly as a native drag would (one
    // atomic Lua dispatch, see Logic.tiledInsertLua). Two windows end up swapped; more end up
    // re-organised around the hovered window. Returns false when nothing should happen: a
    // drop back onto its own slot, or a lone tiled window dropped inside its own workspace.
    function startTiledInsert(addr, win, targetWs, box, mon, cx, cy, dropX, dropY) {
        var plan = tiledDropPlan(addr, win, targetWs, cx, cy)
        if (!plan) return false
        // Only used when there is no anchor window to measure inside the compositor.
        var fallback = Logic.dropToWindowPos(cx, cy, box, mon, params)
        // Optimistic: the tile stays at the drop point until fresh geometry differs from the
        // pre-drop one (a cross-workspace insert differs by workspace at once). A fullscreen
        // window re-tiled in place reports the same fullscreen rect it started with, so the
        // anchor's geometry is recorded too: any change to it is a sufficient signal that the
        // insert happened (an unrelated anchor change acknowledges early too, but that window is
        // bounded by the deadline and the false-positive is harmless).
        var anchorWin = plan.anchor ? _windowByAddress[plan.anchor] : null
        pendingMoves[addr] = { workspaceId: targetWs, pos: null, deadline: Date.now() + 1800,
                               before: { ws: win.workspaceId, ax: win.ax, ay: win.ay, sw: win.sw, sh: win.sh,
                                         anchor: anchorWin ? { address: plan.anchor, ax: anchorWin.ax, ay: anchorWin.ay,
                                                               sw: anchorWin.sw, sh: anchorWin.sh } : null } }
        for (var i = 0; i < tilesModel.count; i++) {
            if (tilesModel.get(i).address !== addr) continue
            tilesModel.set(i, { wx: dropX, wy: dropY, wsid: targetWs })
            break
        }
        Hyprland.dispatch(Logic.tiledInsertLua(addr, targetWs,
            { anchor: plan.anchor, side: plan.side, x: fallback.x, y: fallback.y }))
        return true
    }
    function submitDrop(addr, targetWs, dropX, dropY, px, py) {
        var box = boxForWs(targetWs), mon = box ? _monByName[box.monitorName] : null
        var win = _windowByAddress[addr]
        if (!box || !mon || !win) return
        var sourceWs = win.workspaceId // model.wsid may still be optimistic
        var tile = tileRectFor(addr)
        if (!win.floating && !win.grouped && tile && !Logic.isScratchpad(targetWs)) {
            var cx = px === undefined ? dropX + tile.w / 2 : px
            var cy = py === undefined ? dropY + tile.h / 2 : py
            if (startTiledInsert(addr, win, targetWs, box, mon, cx, cy, dropX, dropY)) {
                scheduleRebuild()
                reconcileTimer.restart()
            }
            return
        }
        var pos = win.floating ? Logic.dropToWindowPos(dropX, dropY, box, mon, params, win) : null
        if (targetWs === sourceWs && !pos) return // grouped tiled: snap back in place
        var pending = { workspaceId: targetWs, pos: pos, deadline: Date.now() + 1800 }
        pendingMoves[addr] = pending
        // Publish the destination before restoring x/y bindings. Keep it until the
        // compositor acknowledges this move; refreshToplevels is asynchronous.
        for (var i = 0; i < tilesModel.count; i++) {
            if (tilesModel.get(i).address !== addr) continue
            // A floating fullscreen window has no slot: Logic._tileRect would span the whole
            // output and fill the cell until the next rebuild, so keep the tile's current size
            // and only move it to the drop point.
            var rect = (pos && !win.fullscreen) ? Logic._tileRect({ax:pos.x, ay:pos.y, sw:win.sw, sh:win.sh},
                                            mon, box, params) : null
            tilesModel.set(i, { wx: rect ? rect.x : dropX, wy: rect ? rect.y : dropY,
                                ww: rect ? rect.w : tilesModel.get(i).ww,
                                wh: rect ? rect.h : tilesModel.get(i).wh, wsid: targetWs })
            break
        }
        // Floating: transfer + exact position in one compositor-side chunk (nothing here has to
        // outlive the overlay to finish it). Grouped tiled windows only change workspace.
        if (pos) Hyprland.dispatch(Logic.floatingMoveLua(addr, targetWs, pos))
        else Hyprland.dispatch('hl.dsp.window.move({ workspace = "' + Logic.wsSelector(targetWs) +
                               '", follow = false, window = "address:' + addr + '" })')
        scheduleRebuild()
        reconcileTimer.restart()
    }
    function _reconcileStep() {
        if (typeof Hyprland.refreshToplevels === "function") Hyprland.refreshToplevels()
        if (typeof Hyprland.refreshWorkspaces === "function") Hyprland.refreshWorkspaces()
        root.rebuild()
    }
    function reconcileMoves(windows) {
        var byAddress = {}
        for (var i = 0; i < windows.length; i++) byAddress[windows[i].address] = windows[i]
        for (var addr in pendingMoves) {
            var pending = pendingMoves[addr], win = byAddress[addr]
            if (Date.now() >= pending.deadline) {
                delete pendingMoves[addr] // rejected move: return to authoritative geometry
                continue
            }
            if (!win || win.workspaceId !== pending.workspaceId) continue
            if (pending.before) {
                // A re-tile is acknowledged once the dragged window's workspace or geometry
                // differs from the pre-drop record, OR the anchor's geometry does: every insert
                // splits the anchor, and a fullscreen window re-tiled in place ends up
                // reporting the same fullscreen rect it started with.
                var b = pending.before, a = b.anchor, aw = a ? byAddress[a.address] : null
                var ownSame = b.ws === win.workspaceId && b.ax === win.ax && b.ay === win.ay &&
                              b.sw === win.sw && b.sh === win.sh
                var anchorSame = !a || !!(aw && aw.ax === a.ax && aw.ay === a.ay && aw.sw === a.sw && aw.sh === a.sh)
                                  // a vanished anchor acknowledges: the insert is moot
                if (ownSame && anchorSame) continue
                delete pendingMoves[addr]
                continue
            }
            if (!pending.pos || (Math.abs(win.ax - pending.pos.x) <= 1 &&
                                 Math.abs(win.ay - pending.pos.y) <= 1 &&
                                 (!pending.size || (Math.abs(win.sw - pending.size.w) <= 1 &&
                                                    Math.abs(win.sh - pending.size.h) <= 1))))
                delete pendingMoves[addr]
        }
    }
    // Pointer position in canvas coordinates during a drag (viewport point + scroll offset).
    function dragPointer() {
        return { x: dragViewportX + flick.contentX, y: dragViewportY + flick.contentY }
    }
    function updateDropTarget() {
        if (!dragTile) { dropTargetWs = -1; dropTargetAddress = ""; dropTargetSide = ""; return }
        // The pointer decides (as the cursor does in a native drag); the tile is only a ghost.
        var p = dragPointer(), cx = p.x, cy = p.y
        var ws = Logic.hitWorkspace(boxes, cx, cy)
        dropTargetWs = ws === null ? -1 : ws
        var win = _windowByAddress[draggingAddress]
        // The scratchpad takes a plain move (no tiled anchor to split): never plan an insertion.
        var tiledDrag = win && !win.floating && !win.grouped && ws !== null && !Logic.isScratchpad(ws)
        var plan = tiledDrag ? tiledDropPlan(draggingAddress, win, ws, cx, cy) : null
        dropTargetAddress = plan ? plan.anchor : ""
        dropTargetSide = plan ? plan.side : ""
    }
    function endDrag() {
        var tile = dragTile
        if (tile) tile.restoreDrag()        // Behaviors still off: park at the drop point
        dragTile = null
        draggingAddress = ""
        dropTargetWs = -1
        dropTargetAddress = ""
        dropTargetSide = ""
        if (tile) tile.rebindTargets()      // Behaviors on: glide to the model
    }
    Timer {
        id: edgeScroll
        interval: 16; repeat: true
        running: root.dragTile !== null && root.dragTile.dragMoved
        onTriggered: {
            var dx = Logic.edgeScrollDelta(root.dragViewportX, flick.width, flick.contentX,
                                           flick.contentWidth, interval)
            var dy = Logic.edgeScrollDelta(root.dragViewportY, flick.height, flick.contentY,
                                           flick.contentHeight, interval)
            flick.contentX += dx
            flick.contentY += dy
        }
    }
    function applyTiles(tiles) {
        var prev = []
        for (var i = 0; i < tilesModel.count; i++) prev.push(tilesModel.get(i).address)
        var d = Logic.diffByAddress(prev, tiles)
        function indexOf(addr) {
            for (var i = 0; i < tilesModel.count; i++)
                if (tilesModel.get(i).address === addr) return i
            return -1
        }
        for (var a = 0; a < d.adds.length; a++) {
            var t = d.adds[a]
            tilesModel.append({ address: t.address, wx: t.x, wy: t.y, ww: t.w, wh: t.h,
                                cls: clsFor(t.address), title: titleFor(t.address),
                                wsid: t.workspaceId, floating: floatingFor(t.address),
                                layer: t.layer, fullscreen: t.fullscreen, fsPending: false,
                                matched: false, selectedMatch: false })
        }
        for (var u = 0; u < d.updates.length; u++) {
            var tu = d.updates[u]
            if (root.draggingAddress === tu.address || pendingMoves[tu.address]) continue   // grab is authoritative
            var iu = indexOf(tu.address); if (iu < 0) continue
            var row = { wx: tu.x, wy: tu.y, ww: tu.w, wh: tu.h,
                        title: titleFor(tu.address), cls: clsFor(tu.address),
                        wsid: tu.workspaceId, floating: floatingFor(tu.address),
                        layer: tu.layer, fullscreen: tu.fullscreen }
            if (rowDiffers(tilesModel.get(iu), row)) tilesModel.set(iu, row)
        }
        for (var rmi = 0; rmi < d.removes.length; rmi++) {
            if (root.draggingAddress === d.removes[rmi] || pendingMoves[d.removes[rmi]]) continue // cancel handled elsewhere
            var ir = indexOf(d.removes[rmi]); if (ir >= 0) tilesModel.remove(ir)
        }
    }

    // Roles differ across two rows only by value: compare before `set`. On current Qt (6.11) an
    // identical partial `set` is already a no-op — this guard is not working around that, it
    // keeps the loop cheap (skips the compare-and-signal machinery entirely on a settle tick
    // where nothing changed) and documents the intent: callers rely on `set` only firing for a
    // genuine change.
    function rowDiffers(cur, next) {
        for (var k in next) if (cur[k] !== next[k]) return true
        return false
    }
    function boxIndex(workspaceId) {
        for (var i = 0; i < boxesModel.count; i++)
            if (boxesModel.get(i).workspaceId === workspaceId) return i
        return -1
    }
    // Reconcile the workspace boxes in place, keyed by workspace id (drag-safe by nature: a
    // box never owns a pointer grab). Roles are prefixed so `model.bx` cannot be confused
    // with the delegate's own x.
    function applyBoxes(boxes) {
        var seen = {}
        for (var i = 0; i < boxes.length; i++) {
            var b = boxes[i]
            var row = { workspaceId: b.workspaceId, bx: b.x, by: b.y, bw: b.w, bh: b.h,
                        focused: !!b.focused, occupied: !!b.occupied,
                        // Reserved for the workspace-lock feature; nothing reads this yet.
                        special: b.special || "" }
            seen[b.workspaceId] = true
            var idx = boxIndex(b.workspaceId)
            if (idx < 0) boxesModel.append(row)
            else if (rowDiffers(boxesModel.get(idx), row)) boxesModel.set(idx, row)
        }
        for (var r = boxesModel.count - 1; r >= 0; r--)
            if (!seen[boxesModel.get(r).workspaceId]) boxesModel.remove(r)
    }

    property var _clsByAddress: ({})
    property var _titleByAddress: ({})
    property var _floatingByAddress: ({})
    property var _monByName: ({})
    property var _windowByAddress: ({})
    function clsFor(addr) { return root._clsByAddress[addr] || "" }
    function titleFor(addr) { return root._titleByAddress[addr] || "" }
    function floatingFor(addr) { return !!root._floatingByAddress[addr] }
    function boxForWs(id) {
        for (var i = 0; i < boxes.length; i++) if (boxes[i].workspaceId === id) return boxes[i]
        return null
    }

    function rebuild() {
        var keepId = root.selectedId   // the workspace the user has selected, before layout
        buildHandles()
        var input = buildInput()
        root._windows = input.windows
        var cmap = {}, tmap = {}, fmap = {}, wmap = {}
        for (var i = 0; i < input.windows.length; i++) {
            wmap[input.windows[i].address] = input.windows[i]
            cmap[input.windows[i].address] = input.windows[i].cls
            tmap[input.windows[i].address] = input.windows[i].title
            fmap[input.windows[i].address] = input.windows[i].floating
        }
        root._windowByAddress = wmap
        if (draggingAddress && !wmap[draggingAddress]) endDrag()
        reconcileMoves(input.windows)
        reconcileFullscreen(input.windows)
        if (!Object.keys(pendingMoves).length && !Object.keys(pendingFullscreen).length) reconcileTimer.stop()
        root._clsByAddress = cmap
        root._titleByAddress = tmap
        root._floatingByAddress = fmap
        var monmap = {}
        for (var mi = 0; mi < input.monitors.length; mi++) monmap[input.monitors[mi].name] = input.monitors[mi]
        root._monByName = monmap
        var res = Logic.layout(input)
        root.boxes = res.boxes
        root.groups = res.groups
        applyBoxes(res.boxes)
        canvas.implicitWidth = res.canvasSize.w
        canvas.implicitHeight = res.canvasSize.h
        applyTiles(res.tiles)
        // Selection follows the workspace, not its position: workspaces come and go while the
        // overview is open (a drag can empty and destroy one), shifting every later box.
        var idx = Logic.hasWs(keepId) ? Logic.indexOfWorkspace(res.boxes, keepId) : -1
        if (idx < 0 && root.selectedIndex >= 0)   // selected workspace vanished: nearest position
            idx = res.boxes.length ? Math.min(root.selectedIndex, res.boxes.length - 1) : -1
        if (idx < 0 && res.boxes.length) {        // nothing selected yet: the focused workspace
            for (var b = 0; b < res.boxes.length; b++) if (res.boxes[b].focused) { idx = b; break }
            if (idx < 0) idx = 0
        }
        root.selectedIndex = idx
        rematchAfterRebuild()   // a query survives rebuilds; windows may have come or gone
    }

    function selectByNav(dir) {
        if (!boxes.length) return
        var i = selectedIndex < 0 ? 0 : selectedIndex
        selectedIndex = Logic.navigate(boxes, i, dir)
        ensureSelectedVisible()
    }

    // Nudge the Flickable minimally so the selected box is fully inside the viewport.
    function ensureSelectedVisible() {
        if (selectedIndex < 0 || selectedIndex >= boxes.length) return
        var b = boxes[selectedIndex]
        if (b.y < flick.contentY) flick.contentY = b.y
        else if (b.y + b.h > flick.contentY + flick.height) flick.contentY = b.y + b.h - flick.height
        if (b.x < flick.contentX) flick.contentX = b.x
        else if (b.x + b.w > flick.contentX + flick.width) flick.contentX = b.x + b.w - flick.width
    }
    function jump(id) {
        if (!Logic.hasWs(id)) return
        if (Logic.isScratchpad(id)) { Hyprland.dispatch(Logic.scratchpadShowLua()); root.close(); return }
        Hyprland.dispatch('hl.dsp.focus({ workspace = "' + id + '" })'); root.close()
    }
    function open() {
        if (opened) return                          // already open: not a second entrance
        openSettle.restart()                        // placement window: see layoutMotion
        if (typeof Hyprland.refreshMonitors === "function") Hyprland.refreshMonitors()
        config.probeMotion()                       // async; result lands for this or the next open
        targetScreen = focusedScreen(); hideScratchpad(); selectedIndex = -1; opened = true
        resetFind()
        _showVisuals(true)                         // before the first rebuild: layout motion is gated on it
        rebuild()          // instant paint from current data
        flick.contentX = 0; flick.contentY = 0   // fresh scroll every open (kept-loaded state would otherwise leak the last offset)
        ensureSelectedVisible()
        scheduleRebuild()  // then settle as fresh toplevel geometry lands
        Qt.callLater(function () { keyCatcher.forceActiveFocus() })
    }
    function close() {
        if (!opened) return                        // a click on the scrim mid-fade is not a second close
        endDrag()
        // settleTimer is open-only; reconcileTimer keeps running (bounded by the 1.8 s
        // deadlines): it clears optimistic display state (pendingMoves / fsPending) so a
        // re-summon inside that window shows authoritative geometry, and with keepLoaded the
        // component is alive to do it. No compositor operation depends on it — each one is a
        // single atomic chunk (logic.js).
        settleTimer.stop()
        opened = false                             // releases keyboard focus at once (see panel)
        _showVisuals(false)                        // the window unmaps when card.opacity reaches 0
    }
    function toggle() { if (opened) close(); else open() }
    // Card + scrim in or out. With motion off the values are set directly: nothing animates,
    // and `panel.visible` follows synchronously.
    function _showVisuals(on) {
        if (root.motion.enabled) {
            if (on) { exitAnim.stop(); enterAnim.restart() }
            else    { enterAnim.stop(); exitAnim.restart() }
            return
        }
        enterAnim.stop(); exitAnim.stop()
        card.scale = 1
        card.opacity = on ? 1 : 0
        scrimRect.opacity = on ? 1 : 0
    }
    ParallelAnimation {
        id: enterAnim
        NumberAnimation { target: scrimRect; property: "opacity"; to: 1
                          duration: root.motion.normal; easing.type: root.motion.move }
        NumberAnimation { target: card; property: "opacity"; to: 1
                          duration: root.motion.enter; easing.type: root.motion.move }
        NumberAnimation { target: card; property: "scale"; from: 0.96; to: 1
                          duration: root.motion.enter; easing.type: root.motion.entrance
                          easing.overshoot: root.motion.overshoot }
    }
    ParallelAnimation {
        id: exitAnim
        NumberAnimation { target: scrimRect; property: "opacity"; to: 0
                          duration: root.motion.exit; easing.type: root.motion.move }
        NumberAnimation { target: card; property: "opacity"; to: 0
                          duration: root.motion.exit; easing.type: root.motion.move }
        NumberAnimation { target: card; property: "scale"; to: 0.98
                          duration: root.motion.exit; easing.type: root.motion.move }
    }
    // Ask Hyprland for fresh client data, then rebuild every 60ms until five quiet ticks have
    // passed, so a window opened while the overview is visible appears once its async geometry
    // arrives — a single immediate rebuild would read stale/empty `lastIpcObject` geometry.
    // The first event of a burst refreshes at once (the data has a tick to land); events while
    // the timer runs extend the settle window and owe one refresh, paid on the next tick — so
    // every event is followed by a refresh, a stream faster than the interval still rebuilds
    // every tick, and there is at most one refresh per tick instead of one per event.
    function requestRefresh() {
        if (typeof Hyprland.refreshToplevels === "function") Hyprland.refreshToplevels()
        if (typeof Hyprland.refreshWorkspaces === "function") Hyprland.refreshWorkspaces()
    }
    function scheduleRebuild() {
        settleTimer.ticks = 0
        if (settleTimer.running) settleTimer.refreshOwed = true
        else { requestRefresh(); settleTimer.start() }
    }
    Timer {
        id: settleTimer
        interval: 60; repeat: true
        property int ticks: 0
        property bool refreshOwed: false   // an event arrived after the last refresh request
        onTriggered: {
            if (refreshOwed) { refreshOwed = false; root.requestRefresh() }
            if (root.opened) root.rebuild()
            if (++ticks >= 5) stop()
        }
        onRunningChanged: if (!running) refreshOwed = false
    }
    // The open settle window: from the first statement of open() until the settle rebuilds
    // are done, layout writes place rather than glide. Covers the gap before the entrance
    // starts (mapping the surface can change panel.width and rebuild synchronously) and runs
    // through the settle ticks (nominally 5 × 60 ms; the two timers are not ordered exactly,
    // but by then identical rebuilds emit nothing).
    Timer { id: openSettle; interval: 300 }
    ListModel { id: tilesModel }
    // Rows are in first-seen order, not layout order; address them by workspaceId, never by index.
    ListModel { id: boxesModel }

    // Window/workspace changes while open: refresh + settle (never an immediate stale rebuild).
    Connections {
        target: Hyprland
        function onRawEvent() { if (root.opened) root.scheduleRebuild() }
    }
    // The watched config file changing the padded workspace count while open: the compositor
    // data is not stale, so a plain rebuild re-lays the wells at once.
    Connections {
        target: config
        function onWorkspacesChanged() { if (root.opened) root.rebuild() }
    }

    PanelWindow {
        id: panel
        // Stays mapped through the exit fade (the pattern Omarchy's PopupCard uses); keyboard
        // focus is released the moment `opened` drops, not when the fade ends.
        visible: root.opened || card.opacity > 0
        screen: root.targetScreen
        anchors { top: true; bottom: true; left: true; right: true }
        color: "transparent"
        WlrLayershell.namespace: "omyview"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: root.opened ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
        // Pointer input is released the moment `opened` drops, like keyboard focus: an empty
        // input region makes the fading surface click-through.
        mask: root.opened ? null : emptyRegion
        Region { id: emptyRegion }
        exclusionMode: ExclusionMode.Ignore

        Rectangle { id: scrimRect; anchors.fill: parent; color: root.scrim; visible: config.scrim; opacity: 0 }
        MouseArea { anchors.fill: parent; enabled: root.opened; onClicked: root.close() }

        // A 28% shadow reads on light themes but vanishes on dark ones (Tokyo Night sweep),
        // so the alpha follows the card's luminance.
        SoftShadow { target: card; scale: card.scale; opacity: card.opacity
                     color: Qt.rgba(0, 0, 0, root.darkTheme ? 0.55 : 0.28) }
        Rectangle {
            id: card
            anchors.centerIn: parent
            radius: root.cardRadius
            color: root.background
            opacity: 0        // the entrance brings it in; panel.visible follows this
            readonly property int pad: Math.round(Style.space(12))
            // Space under the grid for the key hints or, while a query is active, the find
            // bar. Reserves the larger of the two whenever either could show, so swapping one
            // for the other on the first keystroke never resizes the card by the few pixels
            // their implicitHeights happen to differ by. Zero only when both are absent.
            readonly property bool findActive: root.query.length > 0
            readonly property real hintSpace:
                (findActive || config.hint) ? Math.max(findBar.implicitHeight, hint.implicitHeight) + 8 : 0
            // Cap the card to the screen so the Flickable viewport can be smaller than the
            // content (`availCanvasW` already keeps canvas width <= this, minus the degenerate
            // narrow-screen case, which is expected to 2-D scroll per the spec).
            readonly property real maxCardW: panel.width > 0 ? panel.width - 16 : 1616
            readonly property real maxCardH: panel.height > 0 ? panel.height - 64 : 900
            // The hint row never widens past the screen (maxCardW still caps it), but it does
            // widen a narrow card: a layout with few/narrow workspaces must not clip the seven
            // key hints against the card edge.
            implicitWidth: Math.min(Math.max(canvas.implicitWidth, config.hint ? hint.implicitWidth : 0) + pad * 2, maxCardW)
            implicitHeight: Math.min(canvas.implicitHeight + pad * 2 + hintSpace, maxCardH)
            // Card resize (workspaces added/removed, columns change) glides; the Flickable
            // viewport follows card.width, the canvas content is already at its new size.
            Behavior on implicitWidth  { enabled: root.layoutMotion
                NumberAnimation { duration: root.motion.normal; easing.type: root.motion.move } }
            Behavior on implicitHeight { enabled: root.layoutMotion
                NumberAnimation { duration: root.motion.normal; easing.type: root.motion.move } }
            MouseArea { anchors.fill: parent; onClicked: {} }

            Item {
                id: keyCatcher
                anchors.fill: parent
                focus: true
                Keys.priority: Keys.BeforeItem
                Keys.onPressed: function (e) {
                    var finding = root.query.length > 0
                    var chord = e.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier)
                    e.accepted = true
                    // Chords first: the only one with a meaning is Ctrl+Backspace (clear the
                    // query). Every other Ctrl/Alt/Meta combination is reserved for future
                    // actions and must reach no action below — a modified digit, Enter, Tab or
                    // arrow does nothing.
                    if (chord) {
                        if (chord === Qt.ControlModifier && e.key === Qt.Key_Backspace && finding) root.setQuery("")
                        else if (chord === Qt.ControlModifier && e.key === Qt.Key_S) root.toggleScratchpad()
                        return
                    }
                    if (e.key === Qt.Key_Escape) { if (finding) root.setQuery(""); else root.close(); return }
                    if (e.key === Qt.Key_Backspace) {
                        if (finding) root.setQuery(root.query.slice(0, -1))
                        return
                    }
                    if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) {
                        if (finding) root.acceptMatch()
                        else if (Logic.hasWs(root.selectedId)) root.jump(root.selectedId)
                        return
                    }
                    if (finding) {
                        if (e.key === Qt.Key_Tab) { root.cycleMatch(1); return }
                        if (e.key === Qt.Key_Backtab) { root.cycleMatch(-1); return }
                        if (e.key === Qt.Key_Left) { root.navigateMatch("left"); return }
                        if (e.key === Qt.Key_Right) { root.navigateMatch("right"); return }
                        if (e.key === Qt.Key_Up) { root.navigateMatch("up"); return }
                        if (e.key === Qt.Key_Down) { root.navigateMatch("down"); return }
                    } else {
                        if (e.key >= Qt.Key_1 && e.key <= Qt.Key_9) { root.jump(e.key - Qt.Key_0); return }
                        if (e.key === Qt.Key_0) { root.jump(10); return }
                        if (e.key === Qt.Key_Left) { root.selectByNav("left"); return }
                        if (e.key === Qt.Key_Right) { root.selectByNav("right"); return }
                        if (e.key === Qt.Key_Up) { root.selectByNav("up"); return }
                        if (e.key === Qt.Key_Down) { root.selectByNav("down"); return }
                    }
                    var next = Logic.appendQueryText(root.query, e.text)
                    if (next !== root.query) root.setQuery(next)
                }
            }

            Flickable {
                id: flick
                x: card.pad; y: card.pad
                width: card.width - card.pad * 2
                height: card.height - card.pad * 2 - card.hintSpace
                contentWidth: canvas.implicitWidth
                contentHeight: canvas.implicitHeight
                boundsBehavior: Flickable.StopAtBounds
                clip: true
                // Edge scrolling drives the viewport while a tile owns the pointer grab.
                interactive: !root.draggingAddress
                property real previousX: 0
                property real previousY: 0
                onContentXChanged: {
                    if (root.dragTile) root.dragTile.x += contentX - previousX
                    previousX = contentX
                    root.updateDropTarget()
                }
                onContentYChanged: {
                    if (root.dragTile) root.dragTile.y += contentY - previousY
                    previousY = contentY
                    root.updateDropTarget()
                }

                // Content shrinking (windows/workspaces closing) must never leave the viewport
                // scrolled past the new end.
                onContentWidthChanged: flick.contentX = Math.max(0, Math.min(flick.contentX, flick.contentWidth - flick.width))
                onContentHeightChanged: flick.contentY = Math.max(0, Math.min(flick.contentY, flick.contentHeight - flick.height))

                Item {
                    id: canvas
                    x: 0; y: 0
                    width: implicitWidth; height: implicitHeight
                    implicitWidth: 100; implicitHeight: 100

                    // group backdrop layer (lowest): only the focused monitor's group gets one.
                    // Keyed on panel.visible like the chips, so it fades out with the card
                    // instead of popping out the moment close() drops `opened`.
                    Repeater {
                        model: panel.visible && root.multiMonitor ? root.groups : []
                        Rectangle {
                            objectName: "groupBackdrop"
                            required property var modelData
                            visible: modelData.focused
                            x: modelData.x; y: modelData.y; width: modelData.w; height: modelData.h
                            radius: root.boxRadius + modelData.inset
                            color: root.groupBackdropColor
                        }
                    }

                    // boxes layer
                    Repeater {
                        model: boxesModel
                        Rectangle {
                            id: boxItem
                            required property var model
                            objectName: "wsBox"
                            readonly property bool isDrop: root.draggingAddress !== "" &&
                                                           model.workspaceId === root.dropTargetWs
                            x: model.bx; y: model.by; width: model.bw; height: model.bh
                            Behavior on x      { enabled: root.layoutMotion
                                NumberAnimation { duration: root.motion.normal; easing.type: root.motion.move } }
                            Behavior on y      { enabled: root.layoutMotion
                                NumberAnimation { duration: root.motion.normal; easing.type: root.motion.move } }
                            Behavior on width  { enabled: root.layoutMotion
                                NumberAnimation { duration: root.motion.normal; easing.type: root.motion.move } }
                            Behavior on height { enabled: root.layoutMotion
                                NumberAnimation { duration: root.motion.normal; easing.type: root.motion.move } }
                            radius: root.boxRadius
                            // a well sunk into the card; no outline
                            color: isDrop ? root.dropWellColor
                                 : model.focused ? root.selBackground
                                 : model.occupied ? root.wellColor : root.emptyWellColor

                            // big low-contrast numeral, only where nothing would hide it
                            Text {
                                objectName: "wsNumeral"
                                anchors.centerIn: parent
                                visible: !boxItem.model.occupied
                                text: root.wsLabel(boxItem.model.workspaceId)
                                color: root.foreground
                                opacity: 0.10
                                font.pixelSize: Math.round(boxItem.height * 0.45)
                                font.weight: Font.DemiBold
                            }
                            MouseArea {   // click empty area of a workspace => jump
                                anchors.fill: parent
                                enabled: root.opened
                                onClicked: root.jump(boxItem.model.workspaceId)
                            }
                        }
                    }

                    // monitor chips layer (siblings, above boxes) — an icon (laptop or external
                    // screen) plus the connector name, one per group; the focused monitor's
                    // chip is accented and sits on the group backdrop. The model is every group;
                    // visibility is per delegate (root.multiMonitor for a monitor group, always
                    // for the scratchpad group), so the scratchpad chip shows even with a single
                    // monitor.
                    Repeater {
                        model: panel.visible ? root.groups : []
                        Text {
                            objectName: "monitorChip"
                            required property var modelData
                            visible: !!modelData.special || root.multiMonitor
                            x: modelData.x + modelData.inset + 4; y: modelData.y + modelData.inset
                            height: modelData.headerH
                            verticalAlignment: Text.AlignVCenter
                            text: modelData.special ? "SCRATCHPAD"
                                                    : root.monitorIcon(modelData.monitorName) + "  " + modelData.monitorName
                            color: modelData.focused ? root.accent : root.foreground
                            opacity: modelData.focused ? 1.0 : 0.55
                            font.family: root.fontFamily
                            font.pixelSize: root.labelSize
                            font.weight: Font.DemiBold
                            font.capitalization: Font.AllUppercase
                            font.letterSpacing: 1
                        }
                    }

                    // tiles layer (siblings, above boxes)
                    Repeater {
                        model: tilesModel
                        WindowTile {
                            required property var model
                            // Layout motion runs on these glide targets, not on x/y: the drag breaks the x/y
                            // bindings and owns them directly, so a glide still in flight can never fight the
                            // pointer. Release parks the targets at the drop point (Behaviors off), rebinds x/y,
                            // then rebinds the targets to the model — that rebind is the settle glide.
                            property real targetX: model.wx
                            property real targetY: model.wy
                            x: targetX; y: targetY
                            width: model.ww; height: model.wh
                            Behavior on targetX { enabled: root.layoutMotion && !windowTile.dragging
                                NumberAnimation { duration: root.motion.normal; easing.type: root.motion.move } }
                            Behavior on targetY { enabled: root.layoutMotion && !windowTile.dragging
                                NumberAnimation { duration: root.motion.normal; easing.type: root.motion.move } }
                            cls: model.cls
                            tileLayer: model.layer
                            fullscreen: model.fullscreen
                            fullscreenPending: model.fsPending
                            title: model.title
                            matched: model.matched
                            selectedMatch: model.selectedMatch
                            dimmed: root.query.length > 0 && !model.matched && root.dropTargetAddress !== model.address
                            accent: root.accent
                            dragging: root.draggingAddress === model.address
                            handle: root.handleByAddress[model.address] || null
                            // Kept loaded while hidden (keepLoaded): captures run only while the
                            // surface is mapped.
                            capMode: panel.visible ? "live" : "icon"
                            borderColor: root.dropTargetAddress === model.address ? root.accent : root.hairline
                            dropTarget: root.dropTargetAddress === model.address
                            dropSide: root.dropTargetAddress === model.address ? root.dropTargetSide : ""
                            bg: root.background; fg: root.foreground
                            motion: root.motion
                            floating: model.floating
                            fontFamily: root.fontFamily
                            titleSize: root.captionSize
                            // Layout motion: reconcile moves and the post-drop settle glide;
                            // the drag itself writes x/y straight through (Behavior disabled),
                            // and a drag write stops any glide that was still running.
                            Behavior on width  { enabled: root.layoutMotion && !windowTile.dragging
                                NumberAnimation { duration: root.motion.normal; easing.type: root.motion.move } }
                            Behavior on height { enabled: root.layoutMotion && !windowTile.dragging
                                NumberAnimation { duration: root.motion.normal; easing.type: root.motion.move } }
                            id: windowTile
                            readonly property bool dragMoved: dragArea.moved
                            // Called while `dragging` is still true (Behaviors off): park the glide targets at the
                            // drop point and give x/y their bindings back, so nothing moves yet.
                            function restoreDrag() {
                                dragArea.drag.target = undefined
                                dragArea.moved = false
                                targetX = x; targetY = y
                                x = Qt.binding(function () { return targetX })
                                y = Qt.binding(function () { return targetY })
                            }
                            // Called after `dragging` is cleared (Behaviors on): rebinding the targets to the model
                            // glides from the drop point to wherever the model says — the settle, or the snap-back.
                            function rebindTargets() {
                                targetX = Qt.binding(function () { return model.wx })
                                targetY = Qt.binding(function () { return model.wy })
                            }
                            // New while showing → appear. Not at open (the entrance covers that,
                            // and layoutMotion already requires opened), not while closed
                            // (reconcile rebuilds can still add rows then).
                            Component.onCompleted: if (root.layoutMotion) appear()
                            Component.onDestruction: {
                                if (root.dragTile === windowTile) root.endDrag()
                            }
                            onUnfullscreenRequested: root.unfullscreen(model.address)
                            MouseArea {
                                id: dragArea
                                anchors.fill: parent
                                enabled: root.opened
                                acceptedButtons: Qt.LeftButton | Qt.MiddleButton
                                preventStealing: true
                                drag.target: undefined
                                property bool moved: false
                                onPressed: function (m) {
                                    if (m.button !== Qt.LeftButton) return
                                    // A second grab supersedes that address's pending visual state.
                                    delete root.pendingMoves[model.address]
                                    delete root.pendingFullscreen[model.address]
                                    root.setTileRoles(model.address, { fsPending: false })
                                    // Mark the drag first: the layout Behaviors are gated on
                                    // `dragging`, and beginGrab may offset x/y (re-grab during
                                    // the release animation), which must place, not glide.
                                    root.draggingAddress = model.address
                                    root.dragTile = windowTile
                                    windowTile.beginGrab(m.x, m.y)   // ghost shrinks around the grab point
                                    moved = false
                                    drag.target = windowTile
                                    var p = mapToItem(flick, m.x, m.y)
                                    root.dragViewportX = p.x; root.dragViewportY = p.y
                                    root.updateDropTarget()
                                }
                                onPositionChanged: function (m) {
                                    if (!pressed || root.dragTile !== windowTile) return
                                    if (drag.active) moved = true
                                    var p = mapToItem(flick, m.x, m.y)
                                    root.dragViewportX = p.x; root.dragViewportY = p.y
                                    root.updateDropTarget()
                                }
                                onCanceled: if (root.dragTile === windowTile) root.endDrag()
                                onReleased: function (m) {
                                    if (m.button === Qt.MiddleButton) {
                                        Hyprland.dispatch('hl.dsp.window.close({ window = "address:' + model.address + '" })')
                                        return
                                    }
                                    if (root.dragTile !== windowTile) return
                                    var addr = model.address, wasMoved = moved
                                    // Capture before rebinding. Never dispatch for a drop outside a box.
                                    root.updateDropTarget()
                                    var targetWs = root.dropTargetWs
                                    var dropX = windowTile.x, dropY = windowTile.y
                                    var ptr = root.dragPointer()
                                    if (wasMoved && Logic.hasWs(targetWs))
                                        root.submitDrop(addr, targetWs, dropX, dropY, ptr.x, ptr.y)
                                    root.endDrag()
                                    if (!wasMoved) {
                                        // A tile in the scratchpad row: focus alone raises the special
                                        // workspace but leaves the window under whichever floating
                                        // sibling was last on top (see Logic.scratchpadFocusLua).
                                        if (model.wsid === Logic.SCRATCHPAD_ID)
                                            Hyprland.dispatch(Logic.scratchpadFocusLua(addr))
                                        else
                                            Hyprland.dispatch('hl.dsp.focus({ window = "address:' + addr + '" })')
                                        root.close()
                                    }
                                }
                            }
                        }
                    }

                    // badge layer (above tiles): the workspace number stays readable no matter
                    // what the previews contain. One chip per box, top-left corner. Focused
                    // workspace = accent chip. No mouse handling, so clicks fall through.
                    Repeater {
                        model: boxesModel
                        Rectangle {
                            id: badge
                            required property var model
                            objectName: "wsBadge"
                            x: model.bx + 6; y: model.by + 6
                            Behavior on x { enabled: root.layoutMotion
                                NumberAnimation { duration: root.motion.normal; easing.type: root.motion.move } }
                            Behavior on y { enabled: root.layoutMotion
                                NumberAnimation { duration: root.motion.normal; easing.type: root.motion.move } }
                            z: 40   // above resting/hovered tiles, below the selection frame
                            height: badgeText.implicitHeight + 6
                            width: Math.max(height, badgeText.implicitWidth + 10)
                            radius: 5
                            color: model.focused ? root.accent : root.badgeColor
                            Text {
                                id: badgeText
                                anchors.centerIn: parent
                                text: root.wsLabel(badge.model.workspaceId)
                                color: badge.model.focused ? root.background : root.foreground
                                font.family: root.fontFamily
                                font.pixelSize: root.labelSize
                                font.weight: Font.DemiBold
                            }
                        }
                    }

                    // selection frame: the accent outline on the keyboard-selected box. Drags
                    // never move it (keyboard selection and "where I just dropped a window" are
                    // different intents); it only recedes while a drag is in progress.
                    Rectangle {
                        id: selectionFrame
                        readonly property var box:
                            (root.selectedIndex >= 0 && root.selectedIndex < root.boxes.length)
                                ? root.boxes[root.selectedIndex] : null
                        visible: box !== null
                        x: box ? box.x : 0; y: box ? box.y : 0
                        width: box ? box.w : 0; height: box ? box.h : 0
                        z: 50   // above resting/hovered tiles, below the drag ghost
                        radius: root.boxRadius
                        color: "transparent"
                        border.width: 2
                        border.color: root.accent
                        opacity: root.draggingAddress !== "" ? 0.4 : 1
                        Behavior on opacity { enabled: root.motion.enabled
                            NumberAnimation { duration: root.motion.fast; easing.type: root.motion.hover } }
                        Behavior on x      { enabled: root.layoutMotion
                            NumberAnimation { duration: root.motion.normal; easing.type: root.motion.move } }
                        Behavior on y      { enabled: root.layoutMotion
                            NumberAnimation { duration: root.motion.normal; easing.type: root.motion.move } }
                        Behavior on width  { enabled: root.layoutMotion
                            NumberAnimation { duration: root.motion.normal; easing.type: root.motion.move } }
                        Behavior on height { enabled: root.layoutMotion
                            NumberAnimation { duration: root.motion.normal; easing.type: root.motion.move } }
                    }

                    // drop wash: the workspace-level drop cue, drawn ABOVE the previews so a
                    // fullscreen or densely tiled workspace cannot hide it. Shown while dragging
                    // over a box whenever no tile-level insertion preview is showing (floating
                    // drags, empty targets, grouped/fullscreen sources); the tinted well
                    // underneath is only a secondary hint.
                    Rectangle {
                        id: dropWash
                        readonly property var box:
                            (root.draggingAddress !== "" && root.dropTargetAddress === "")
                                ? root.boxForWs(root.dropTargetWs) : null
                        // Geometry sticks to the last target so the fade-out stays in place.
                        property var shownBox: null
                        onBoxChanged: if (box) shownBox = box
                        visible: opacity > 0
                        opacity: box !== null ? 1 : 0
                        Behavior on opacity { enabled: root.motion.enabled
                            NumberAnimation { duration: root.motion.fast; easing.type: root.motion.hover } }
                        x: shownBox ? shownBox.x : 0; y: shownBox ? shownBox.y : 0
                        width: shownBox ? shownBox.w : 0; height: shownBox ? shownBox.h : 0
                        z: 60   // above resting/hovered tiles and the selection frame, below the ghost
                        radius: root.boxRadius
                        color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.22)
                        border.width: 2
                        border.color: root.accent
                    }
                }
            }

            // key hints: each binding as a small key cap plus a label; off via config.hint
            Row {
                id: hint
                visible: config.hint && !card.findActive
                anchors { horizontalCenter: parent.horizontalCenter; bottom: parent.bottom; bottomMargin: 8 }
                spacing: Math.round(Style.space(12))
                Repeater {
                    id: hintKeys
                    model: [ { k: "1–0", l: "jump" }, { k: "↑ ↓ ← →", l: "move" }, { k: "↵", l: "select" },
                             { k: "drag", l: "move window" }, { k: "type", l: "find" },
                             { k: "ctrl+s", l: "scratchpad" }, { k: "esc", l: "close" } ]
                    Row {
                        required property var modelData
                        spacing: 5
                        Rectangle {
                            radius: 4
                            color: root.wellColor
                            height: capText.implicitHeight + 4
                            width: capText.implicitWidth + 10
                            Text {
                                id: capText; anchors.centerIn: parent
                                text: modelData.k
                                color: root.foreground; opacity: 0.75
                                font.family: root.fontFamily; font.pixelSize: root.captionSize
                                font.weight: Font.DemiBold
                            }
                        }
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: modelData.l
                            color: root.foreground; opacity: 0.45
                            font.family: root.fontFamily; font.pixelSize: root.captionSize
                        }
                    }
                }
            }

            FindBar {
                id: findBar
                visible: card.findActive
                // Spans the card interior: the bar's width is the card's, never the query's.
                anchors { left: parent.left; right: parent.right; bottom: parent.bottom
                          leftMargin: card.pad; rightMargin: card.pad; bottomMargin: 8 }
                query: root.query
                count: root.matches.length
                index: root.matchIndex
                fg: root.foreground; accent: root.accent
                fontFamily: root.fontFamily; fontSize: root.captionSize
            }
        }
    }
}
