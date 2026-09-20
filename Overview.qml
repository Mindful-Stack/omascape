// Omascape — v2. Canvas + boxes + live tiles. See DESIGN.md / docs/specs, docs/plans.
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
    // The entrance/exit animations drive THIS, not card.scale directly, so that card.scale can
    // carry a live binding (barMode ? 1 : entranceScale) instead. A running animation's
    // interpolation is fixed at start and only re-reads from/to on its next loop -- so animating
    // card.scale directly left a flip INTO bar mode mid-entrance still riding out the stale
    // 0.96->1 trajectory while width/anchors (ordinary live bindings) snapped to bar geometry
    // instantly, detaching the card from the screen edges for the rest of that run. Gating
    // through a live binding on card.scale itself removes that window: the binding re-reads on
    // every dependency change, not just on the animation's next loop.
    property real entranceScale: 1

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
    // The bar's own ground, a DIFFERENT token from the menu one (Bar.qml:71). Both fall through
    // to the same base background on a theme without a shell.toml, so they match by accident
    // there; a theme that sets [bar] background diverges them, and an attached card must follow
    // the bar.
    property color barBackground: Color.bar.background
    property color selBackground: Color.menu.selectedBackground
    property color selText: Color.menu.selectedText
    function tone(a) { return Qt.rgba(foreground.r, foreground.g, foreground.b, a) }
    // Tinted glass, used for the wells and the hint ground while the card is wallpaper-backed.
    // tone() is foreground at 0.04, and 0.02 for an empty well: a lift you can only see against
    // a flat card. Over a photograph both vanish, and with them the only cue that an empty
    // workspace is there at all.
    //
    // Built on `background` with the accent mixed in at 12%, rather than being accent. Most
    // themes' accents are LIGHT -- rose-pine's is #ebbcba, luminance 0.78 against a background
    // of 0.10 -- so an accent-dominant glass would wash the photograph instead of darkening it,
    // and the numerals (foreground at 0.10 alpha) would come out harder to read, not easier.
    // 12% is enough to read as a deliberate tint and not enough to stop it working.
    function glass(a) {
        var m = Logic.glassMix(background, accent)
        return Qt.rgba(m.r, m.g, m.b, a)
    }
    readonly property color wellColor: wallpaperBacked ? glass(0.55) : tone(Style.normalFillAlpha)
    readonly property color emptyWellColor: wallpaperBacked ? glass(0.40)
                                                            : tone(Style.normalFillAlpha / 2)
    // Typography follows the shell: the menu family and the theme's size tokens, so the picker
    // tracks `omarchy display text size` like every other summoned surface.
    readonly property string fontFamily: Style.font.menuFamily
    readonly property int labelSize: Style.font.bodySmall
    readonly property int captionSize: Style.font.caption
    // Well under a drag: the only workspace-level drop cue (tiled drops also preview the
    // insertion half on the anchor tile), so it must read even on the focused workspace.
    readonly property color dropWellColor: wallpaperBacked ? glass(0.75) : tone(Style.selectedFillAlpha)
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

    OmascapeConfig { id: config }
    OmascapeLocks { id: locks }
    // "Reported once per open": a toggle attempted while the locks file is still unresolved
    // (never loaded, or stuck on a malformed file) is a no-op; without feedback the user just
    // sees Ctrl+L do nothing. Reset in open() so a later, working open() can warn again.
    property bool lockUnresolvedNotified: false
    // Same idea for a malformed/unreadable file's own report: a stuck FileView can re-emit
    // `loaded` (a watcher firing on an unrelated directory event, a repeated reload) without the
    // file's content changing, and Logic.applyLocksTo re-reports the same error every time
    // (unlike the armed set, "still malformed" has no "unchanged" case to suppress it against).
    // Without this guard that would toast on every such echo, not just the first.
    property bool lockInvalidNotified: false
    // Bumped wherever the monitor snapshots are refreshed, purely so the reminder frame's
    // `Hyprland.monitorFor(screen)` binding re-resolves. That call is a C++ invokable returning a
    // one-shot value: nothing notifies QML when Hyprland REPLACES the HyprlandMonitor object for a
    // screen (a monitor reconfigure across `configreloaded` does exactly that, without
    // `Quickshell.screens` changing), so the binding would keep a stale — or null — pointer and
    // that screen's frame would stay hidden for good.
    property int monitorEpoch: 0
    // Enforcement lives in the compositor; these keep it in step with the armed set. Install is
    // idempotent and cheap; sync is sent only once `armed` has resolved (never an unresolved set).
    function lockInstall() {
        Hyprland.dispatch(Logic.lockInstallLua())
        lockRefreshTimer.restart()
    }
    function lockSync() {
        if (locks.armed === null) return
        Hyprland.dispatch(Logic.lockSyncLua(locks.armed))
    }
    // Ctrl+L: flip the SELECTED workspace, whatever the pointer is doing. The cursor and the
    // pointer never change what Ctrl+L acts on — it is a workspace key, not a target action.
    function lockToggleSelected() {
        if (!Logic.hasWs(selectedId)) return
        lockSet(selectedId, !locks.isArmed(Logic.wsSelector(selectedId)))
    }
    // Explicit state, so the menu's Lock/Unlock row cannot invert if the set changed under it.
    function lockSet(wsId, armed) {
        if (!Logic.hasWs(wsId)) return
        if (locks.armed === null) {
            if (!lockUnresolvedNotified) {
                lockUnresolvedNotified = true
                Hyprland.dispatch(Logic.notifyLua(
                    "omascape: locks file unreadable — fix or delete ~/.config/omarchy/omascape-locks.json"))
            }
            return
        }
        var sel = Logic.wsSelector(wsId)
        if (locks.isArmed(sel) === armed) return         // already in the requested state
        if (!locks.toggleInMemory(sel)) return
        lockSync()          // the compositor is the enforcement; it must not wait for disk
        locks.persist()
        rebuild()
    }
    // Close all windows on a workspace. Everything the chunk will close gets the same optimistic
    // treatment Ctrl+W gives one window — including a window dropped there a moment ago, which the
    // compositor already lists on that workspace even though the overview still holds its
    // pre-drop row.
    function closeAllOn(wsId) {
        if (!Logic.hasWs(wsId)) return
        var now = Date.now()
        for (var i = 0; i < tilesModel.count; i++) {
            var t = tilesModel.get(i)
            if (t.wsid !== wsId) continue
            supersedePending(t.address)
            pendingCloses[t.address] = now + 1800
        }
        for (var a in pendingMoves)
            if (pendingMoves[a].workspaceId === wsId) { supersedePending(a); pendingCloses[a] = now + 1800 }
        if (cursorAddress && pendingCloses[cursorAddress]) setCursor("")
        applyClosingRoles()
        Hyprland.dispatch(Logic.closeAllLua(wsId))
        scheduleRebuild()
        reconcileTimer.restart()
    }
    // A pending move's coordinates are meaningless once its workspace changes monitor, so drop
    // every optimistic row bound to that workspace in either direction.
    function clearPendingForWorkspace(wsId) {
        for (var a in pendingMoves) {
            var win = _windowByAddress[a]
            if (pendingMoves[a].workspaceId === wsId || (win && win.workspaceId === wsId))
                delete pendingMoves[a]
        }
    }
    function moveWorkspace(wsId, monitorName) {
        if (!Logic.validMonitorName(monitorName)) return
        clearPendingForWorkspace(wsId)
        Hyprland.dispatch(Logic.workspaceMoveLua(wsId, monitorName))
        scheduleRebuild()
    }
    function swapWorkspace(wsId, monitorName) {
        if (!Logic.validMonitorName(monitorName)) return
        var b = boxForWs(wsId)
        if (!b || !Logic.validMonitorName(b.monitorName)) return
        if (monitorName === b.monitorName) return
        clearPendingForWorkspace(wsId)
        Hyprland.dispatch(Logic.workspaceSwapLua(wsId, b.monitorName, monitorName))
        scheduleRebuild()
    }
    Connections {
        target: locks
        function onLoadedArmed() { root.lockSync(); if (root.opened) root.rebuild() }
        function onSharingChanged() { if (root.opened) root.rebuild() }
        function onWriteFailed(why) { Hyprland.dispatch(Logic.notifyLua("omascape: could not save locks: " + why)) }
        function onInvalidFile(why) {
            if (root.lockInvalidNotified) return
            root.lockInvalidNotified = true
            Hyprland.dispatch(Logic.notifyLua("omascape: locks file ignored: " + why))
        }
    }
    // Quickshell's FileView watches the file's *parent directory*, not the file itself: if
    // $XDG_RUNTIME_DIR/omascape does not exist yet (every fresh login, before the compositor's
    // install chunk has run its `mkdir -p`), the watch never attaches, and share-state changes
    // go unseen for the rest of the session — reload() is the only thing that re-attaches it.
    // Restarting this timer on every lockInstall() re-reads both files ~400ms later, by which
    // point the directory has had time to appear, so watchChanges starts working from then on.
    Timer { id: lockRefreshTimer; interval: 400; onTriggered: locks.refresh() }
    Component.onCompleted: lockInstall()           // shell start, before any open

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
    // ---- Bar attachment ------------------------------------------------------------------
    // The reserved TOP strip of the screen the picker is ON. The overlay is an Overlay-layer
    // surface with exclusionMode Ignore, so panel.height is the WHOLE screen and the bar sits
    // underneath it; `reserved` is the only thing that says where the bar ends.
    //
    // Resolved through targetScreen, NOT through Hyprland.focusedMonitor. open() captures
    // targetScreen once, but focus keeps moving: focus landing on a monitor that reserves a
    // different amount — or nothing — would otherwise re-anchor the card, resize its height cap
    // and flip bar mode off underneath an open picker.
    //
    // monitorEpoch is the dependency, exactly as the reminder frame's binding uses it:
    // monitorFor() is a one-shot C++ invokable and nothing notifies QML when Hyprland REPLACES
    // the monitor object for a screen, so without it this keeps a stale or null pointer.
    readonly property int reservedTop: {
        var m = (root.monitorEpoch,
                 root.targetScreen ? Hyprland.monitorFor(root.targetScreen) : null)
        var r = m && m.lastIpcObject ? m.lastIpcObject.reserved : null
        return (r && r.length > 1 && isFinite(r[1]) && r[1] > 0) ? Math.round(r[1]) : 0
    }
    // No top bar to hang from (a side, bottom or hidden bar) means no attachment: the picker
    // keeps the centred card rather than squaring itself against nothing.
    readonly property bool barMode: config.anchor === "bar" && reservedTop > 0
    // A transparent bar shows the WALLPAPER, because its exclusion zone keeps windows out of
    // that strip. The card covers a region full of windows, so it cannot be transparent in the
    // same way -- you would read the grid over the very windows it depicts. It paints the
    // wallpaper instead: what the bar SHOWS, rather than what happens to be behind us.
    readonly property bool wallpaperBacked:
        barMode && config.barTransparent && config.wallpaperUrl !== ""

    // Key-hint contrast. HintCap's defaults (cap 0.75, label 0.45) are tuned for a flat card,
    // where the label being quiet is the point. Over a wallpaper -- especially a bright one --
    // 0.45 of the foreground washes out entirely and the hints stop being readable. Both are
    // raised together so the cap stays louder than the label it belongs to; raising only the
    // label would invert the hierarchy and make the words shout over the keys.
    readonly property real hintCapOpacity: wallpaperBacked ? 0.95 : 0.75
    readonly property real hintLabelOpacity: wallpaperBacked ? 0.78 : 0.45
    // One progress for the whole bar-mode entrance; every row derives its own phase from it.
    // Root-level and not per-delegate: tilesModel and boxesModel are reconciled IN PLACE, so
    // delegates persist across rebuilds and a per-delegate Component.onCompleted would fire once
    // at startup and never again. It also means a mid-session rebuild cannot replay the
    // entrance — progress is already 1 by then.
    // How far the bar-mode card has unfurled, 0..1. Its top stays pinned to the bar and its
    // HEIGHT grows, so the rows are uncovered from the top down, the way a blind comes down.
    //
    // A rigid slide was the obvious alternative and is wrong: a card translating down from
    // above the bar shows its BOTTOM edge first (content is visible only where local
    // y >= (1 - p) * height), so the LAST row would appear before the first and the reveal
    // would read upside down.
    //
    // Nothing is painted above the bar either way, so this needs no clipping wrapper -- which
    // matters, because this surface is WlrLayer.Overlay and the bar is WlrLayer.Top, so
    // anything drawn above the bar's edge would be drawn OVER the bar.
    property real entranceOpen: 1
    NumberAnimation {
        id: openAnim
        // motion.move, not motion.entrance: the entrance easing carries an overshoot, and an
        // overshoot on a HEIGHT would open past the content and snap back.
        target: root; property: "entranceOpen"
        from: 0; to: 1; duration: root.motion.enter; easing.type: root.motion.move
    }
    // Backdrop behind the focused monitor's group: a whisper of accent, so which screen is
    // live reads peripherally without touching the three well shades.
    readonly property color groupBackdropColor: Qt.rgba(accent.r, accent.g, accent.b, 0.08)
    function monitorIcon(name) { return Logic.monitorGlyph(name) }

    property var groups: []
    // Monitor chips and the focused-group backdrop key on how many *monitor* groups there are;
    // the scratchpad group is extra and always carries its own chip.
    readonly property bool multiMonitor: groups.filter(function (g) { return !g.special }).length > 1
    // Card interior logical width available to the canvas: panel.width (logical, not
    // screen.width*dpr) minus the card's own padding and the screen margin. Shares
    // Logic.screenMargin with the card's own caps below so the two cannot drift apart — they
    // previously disagreed by 2 * card.pad, which is how the grid came to sit 10 px from the
    // edge of a 1920-logical screen (a 4K panel at 2x).
    readonly property real availCanvasW:
        panel.width > 0
            ? panel.width - 2 * card.pad - (root.barMode ? 0 : 2 * Logic.screenMargin(panel.width))
            : 1600
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
        var activeByMon = {}
        for (var i = 0; i < hmons.length; i++) {
            var m = hmons[i]
            // Not every entry in Hyprland.monitors is a screen. A workspace Hyprland reports on
            // no monitor ("monitor": "?" — a persistent rule whose monitor is absent, or one left
            // behind by an unplugged display) makes Quickshell materialise a placeholder monitor
            // of that name with every field zeroed, and it arrives here the moment a refresh
            // touches that workspace. Admitted as a screen it turns a one-display machine
            // multi-monitor (chip bands, group insets) and, worse, its 0x0 logical size divides
            // 0 by 0 for the group's cell aspect: the NaN reaches the canvas and the card, and a
            // card with a NaN height paints NOTHING — the overview mapped its surface, took
            // focus, drew the scrim and showed no picture (found on a real desktop, 2026-09-18).
            // Skipped here rather than filtered in layout() so `monNames`, `activeByMon` and the
            // menu's monitor list all agree on what a monitor is; workspaces naming one then take
            // the "?" path buildInput already has, and layout() leaves them out.
            if (!(m.width > 0 && m.height > 0)) continue
            mons.push({ name: m.name, x: m.x, y: m.y, width: m.width, height: m.height,
                        scale: m.scale, reserved: m.lastIpcObject ? m.lastIpcObject.reserved : [0,0,0,0],
                        transform: m.lastIpcObject ? m.lastIpcObject.transform : 0 })
            // Which workspace each monitor is SHOWING — the same snapshot field the lock frame
            // reads, refreshed by the same events (Logic.lockFrameRefreshEvent).
            activeByMon[m.name] = (m.lastIpcObject && m.lastIpcObject.activeWorkspace &&
                                   typeof m.lastIpcObject.activeWorkspace.id === "number")
                                  ? m.lastIpcObject.activeWorkspace.id : -1
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
            // Hyprland can name a monitor the layout will never know about: one already removed,
            // the zeroed placeholder it reports for a workspace on no monitor at all (the monitor
            // loop above drops those), or no monitor field whatsoever. Such a workspace belongs in
            // the focused monitor's group, never in one of its own — it still has a key, and
            // `workspaces: N` promises a well for every key whether or not Hyprland has created
            // that workspace. Dropping it takes more than itself down: padWorkspaces leans each
            // synthetic id on the nearest lower REAL one's monitor, so a homeless workspace 6
            // silently swallows the wells for 7, 8 and 9 too (found on a real desktop,
            // 2026-09-18). The scratchpad row has always taken this same fallback.
            var monName = (mon && monNames[mon.name]) ? mon.name : focusedMonitorName
            var wsSel = Logic.wsSelector(wsId)
            var wsArmed = locks.isArmed(wsSel), wsPlaceholder = locks.placeholder(wsSel)
            wss.push({ id: wsId, monitorName: monName, special: special,
                       focused: ws.id === focusedWsId,
                       occupied: ws.toplevels && ws.toplevels.values.length > 0,
                       // Close all is offered only above ONE window (see Logic.workspaceMenuRows):
                       // on a single-window workspace it is Close by another name. Counted from
                       // the same toplevel list `occupied` comes from, so the two can never
                       // disagree, and counted even behind a lock placeholder — the placeholder
                       // hides the windows from find and drag, not from the compositor.
                       windowCount: ws.toplevels ? ws.toplevels.values.length : 0,
                       armed: wsArmed, placeholder: wsPlaceholder,
                       // Compared against the REAL id, before the scratchpad remap: a special
                       // workspace is reported as `specialWorkspace`, never `activeWorkspace`.
                       active: !special && activeByMon[monName] === ws.id })
            var tls = ws.toplevels ? ws.toplevels.values : []
            for (var t = 0; t < tls.length; t++) {
                var o = tls[t] ? tls[t].lastIpcObject : null
                if (!o || !o.at || !o.size || !o.address) continue
                if (wsPlaceholder) continue          // find/drag never see a placeholder's windows
                wins.push({ address: o.address, cls: o["class"] || "", title: o.title || "",
                            ax: o.at[0], ay: o.at[1], sw: o.size[0], sh: o.size[1],
                            workspaceId: wsId,
                            // Not read by the overview yet.
                            special: special, floating: !!o.floating,
                            fullscreen: Logic.fullscreenMode(o),
                            grouped: !!(o.grouped && o.grouped.length) })
            }
        }
        // Hyprland drops an emptied special workspace; the row is still a place to drop windows.
        if (scratchpadShown && !haveScratch) {
            wsSel = Logic.wsSelector(Logic.SCRATCHPAD_ID)
            wss.push({ id: Logic.SCRATCHPAD_ID, monitorName: focusedMonitorName, special: "scratchpad",
                       focused: false, occupied: false, windowCount: 0,
                       armed: locks.isArmed(wsSel), placeholder: locks.placeholder(wsSel), active: false })
        }
        // padWorkspaces() fills gaps with synthetic (empty) records that carry no armed/
        // placeholder flags: without this, arming an empty workspace shows no badge, and a
        // formerly-armed workspace loses its badge the instant its last window closes and it
        // becomes a pad slot instead of a real record.
        var padded = Logic.padWorkspaces(wss, config.workspaces, focusedMonitorName)
        for (var pi = 0; pi < padded.length; pi++) {
            var pw = padded[pi]
            if (pw.armed === undefined) {
                var pwSel = Logic.wsSelector(pw.id)
                pw.armed = locks.isArmed(pwSel); pw.placeholder = locks.placeholder(pwSel)
                pw.active = false           // a workspace Hyprland has not created shows nowhere
            }
        }
        return { monitors: mons, workspaces: padded, windows: wins,
                 focusedMonitorName: focusedMonitorName,
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
    // ---- Actions: pointer liveness and target resolution ---------------------------------
    // "Most recent input device wins." Liveness is tracked in SCENE coordinates, never canvas
    // ones: an edge/wheel scroll, a card resize or the entrance scale all move the canvas under a
    // stationary pointer, and none of those is the user pointing at something new.
    property bool pointerLive: false
    // The first hover report of a summon is the surface mapping under wherever the pointer already
    // rests: a position, not a move. Its coordinates need not match the ones left from the last
    // summon — the first summon after start-up has none, and between summons the overview is
    // unmapped and is told nothing about the pointer — so the same-position early return below
    // cannot recognise it on its own. Without this, a keyboard summon armed the pointer and Ctrl+W
    // acted on whatever the resting cursor happened to cover. Only the FIRST report of a summon,
    // and only while the surface is still mapping (`pointerPrime`), establishes the position that
    // way; a real move emits a stream of reports, so one made during that window still arms
    // liveness a pixel later, and one made after it arms immediately.
    property bool pointerPrimed: false
    property real pointerSceneX: 0
    property real pointerSceneY: 0
    Timer { id: pointerPrime; interval: 300 }   // the mapping window; restarted by open()
    function notePointerMove(sp) {
        if (sp.x === pointerSceneX && sp.y === pointerSceneY) { pointerPrimed = true; return }
        pointerSceneX = sp.x; pointerSceneY = sp.y
        if (!pointerPrimed && pointerPrime.running) { pointerPrimed = true; return }
        pointerLive = true
    }
    // The pointer in canvas coordinates, derived only here and only at resolve time.
    function pointerPoint() {
        var p = flick.mapFromItem(null, pointerSceneX, pointerSceneY)
        return { x: p.x + flick.contentX, y: p.y + flick.contentY,
                 inView: p.x >= 0 && p.y >= 0 && p.x <= flick.width && p.y <= flick.height }
    }
    // Displayed tile rects for the hit test: each delegate's own geometry expanded about its
    // centre by `scale`, so the hovered tile's 1.03 lift and an in-flight appear animation are
    // hit-tested at the size they are painted. The drag ghost's separate Scale transform is not
    // folded in because actions are ignored while a drag is in flight.
    function tileCandidates() {
        var out = []
        for (var i = 0; i < tileRepeater.count; i++) {
            var t = tileRepeater.itemAt(i)
            if (!t) continue
            var s = t.scale
            out.push({ address: t.tileAddress, z: t.z,
                       x: t.x + t.width * (1 - s) / 2, y: t.y + t.height * (1 - s) / 2,
                       w: t.width * s, h: t.height * s })
        }
        return out
    }
    function resolveTarget() {
        var live = false, tileAddr = "", wsId = -1
        if (pointerLive) {
            var p = pointerPoint()
            if (p.inView) {
                live = true
                tileAddr = Logic.tileAt(tileCandidates(), p.x, p.y)
                if (!tileAddr) {
                    var hit = Logic.hitWorkspace(boxes, p.x, p.y)
                    wsId = hit === null ? -1 : hit
                }
            }
        }
        return Logic.target({ pointerLive: live, pointerTileAddress: tileAddr,
                              pointerWorkspaceId: wsId, query: root.query,
                              matchAddress: root.selectedMatchAddress,
                              cursorAddress: root.cursorAddress, selectedId: root.selectedId })
    }
    // ---- Peek (docs/specs/2026-09-18-peek-design.md) --------------------------------------
    // The hold carries exactly three pieces of state and no more. `peeking` is "the key is down
    // and the hold is live"; `peekedKey` is the identity currently on screen, read by the
    // disappearance check in rebuild() (see `peekedAtEntry` there); `peekCancelled` suppresses the
    // layer for the REST of the hold once the target vanished or a modal took over. None of the
    // three is a copy of the target's geometry or contents — following the target is the absence
    // of a snapshot.
    property bool peeking: false
    property string peekedKey: ""
    property bool peekCancelled: false
    // Whether the physical Space key is currently down, independent of whether a hold is live —
    // set at the top of the Space press branch, cleared in `Keys.onReleased`. `peekAbort()` reads
    // this to decide whether there is a key to suppress at all (review fix: it used to latch
    // `peekCancelled` unconditionally, so a modal that opened and closed with Space never pressed
    // — a plain right-click dismissed by Escape, say — still left the cancel set, and only a
    // stray press+release cycle the user never asked for would clear it before the NEXT real
    // press could open anything).
    property bool peekKeyDown: false
    // "w:<address>" for a window, "s:<id>" for a workspace. A single namespaced string so the
    // two kinds can never collide in the model test (a workspace id is a number, an address a
    // string, and JS would happily compare them across kinds).
    function peekKeyOf(t) {
        if (!t) return ""
        return t.kind === "window" ? "w:" + t.address : "s:" + t.id
    }
    // Three named exits, not one function with a boolean: `cancel` true/false looked like a
    // simple inverse pair, but it is not — a release must clear `peekCancelled` and an abort must
    // SET it, and mutation testing showed a bare boolean argument gives no signal, offscreen or
    // otherwise, when a call site passes the wrong one. Naming the three cases instead makes a
    // wrong call site a readable diff instead of a silent behavioural swap, which matters now that
    // more call sites exist than the original two (the press branch and the key catcher's release
    // handler): `openMenu()`, `openCloseAllConfirm()`, the key catcher's focus-loss handler and
    // `close()` all call `peekAbort()` too.
    //
    // These three functions are the ONLY sanctioned mutators of `peeking`/`peekCancelled` (the
    // press branch below also sets `peeking = true`, but only immediately after confirming
    // `peekCancelled` is false — see its own comment). That closes an invariant worth writing
    // down: `peekCancelled` implies `!peeking`, always. Only `peekAbort()` ever sets
    // `peekCancelled = true`, and it sets `peeking = false` in that SAME call — so the two can
    // never both be true. `shown` below relies on this to skip a redundant `&& !peekCancelled`
    // clause; if a future change adds a fourth mutator, or moves the cancel and the clear apart,
    // re-check that binding. A second invariant, added by the review fix below:
    // `peekCancelled` also implies `peekKeyDown` was true at the moment it was set — `peekAbort()`
    // only latches the cancel while there is a physically-held key to suppress it for, so a modal
    // that opens with Space never pressed leaves `peekCancelled` untouched.
    //
    // A normal release: the key came up, the hold ends, and the key is free to open a new one on
    // its very next press — so the cancel clears too.
    //
    // `peekRelease()` and `peekReset()` below now diverge by exactly one line (`peekReset()` also
    // clears `peekKeyDown`) — the two do NOT need to stay identical, and this is the first case of
    // them actually differing. `peekRelease()` doesn't need to touch `peekKeyDown` because its own
    // call site (`Keys.onReleased`) already clears it in the same breath, from the real key-up
    // event. `peekReset()` has no such event to piggyback on — a fresh summon has no "the key just
    // came up" moment — so it must clear the flag itself, or a `peekKeyDown` left stale from a
    // still-unreleased key at the previous close (see `close()`'s own `peekAbort()` call) would
    // carry into the new session and let an unrelated modal there wrongly latch a cancel again.
    // They still say different things at their call sites (a real key-up vs. a fresh summon owing
    // nothing to the last one), and are free to diverge further later. Nothing here catches an
    // edit that changes one body without checking whether the other needs the same change — that
    // is a known gap, not an oversight, and is the cost of keeping the names distinct. Resist
    // "simplifying" by having one call the other (that would make the intent at one of the two
    // call sites a lie); if you change what either function does, re-read this comment and check
    // whether the other one needs the same fix.
    function peekRelease() {
        peeking = false
        peekedKey = ""
        peekCancelled = false
    }
    // An abort: the target vanished, a modal took over, or the overview is closing under a still
    // -held key whose release will never arrive. The hold ends; the cancel is left SET so the key
    // stays inert for the rest of this physical press — only `peekRelease()` (the real key-up)
    // clears it — but ONLY when there is a physical key down to suppress in the first place
    // (`peekKeyDown`). Without that guard, a modal that opens with Space never pressed (a plain
    // right-click, dismissed by Escape, with no hold ever started) would still set the cancel, and
    // since nothing but a real Space release clears it, the very next — unrelated — Space press
    // would be silently swallowed until one stray press+release cycle happened to clear it first.
    // Review fix; see the property's own comment and `test_a_menu_opened_and_dismissed_without_space_does_not_dead_the_next_press`.
    function peekAbort() {
        peeking = false
        peekedKey = ""
        if (peekKeyDown) peekCancelled = true
    }
    // A fresh summon: nothing carries over from whatever the key was doing at the previous close,
    // cancelled or not — a stale `peekCancelled` here would leave the very first Space of a new
    // session silently inert. `peekKeyDown` must reset too, for the same reason one level down:
    // `close()` calls `peekAbort()` under a still-held key whose release will never arrive (the
    // surface is unfocused/gone), so `peekKeyDown` is left true across the close. Without clearing
    // it here, the NEXT summon starts with a stale "key is down" belief, and a modal opened with
    // no Space actually held in the new session (a plain right-click) would incorrectly latch
    // `peekCancelled` via that stale flag — reintroducing the exact bug this property exists to
    // fix, one summon later. See the note above `peekRelease()`: identical to it today, kept
    // separate on purpose.
    function peekReset() {
        peeking = false
        peekedKey = ""
        peekCancelled = false
        peekKeyDown = false
    }
    // The mini-map's window list, reconciled by identity (Task 7 review, item 2). `rebuild()`
    // reassigns `_windows` to a brand-new array on every `onWorkspacesChanged` — i.e. on ANY
    // title change anywhere, not just on the peeked workspace — so a naive `_windows.filter(...)`
    // in the PeekLayer binding below hands it a fresh array every time, even when nothing about
    // the peeked workspace changed. PeekLayer's own Repeater keys its model on that array's
    // IDENTITY, not its content, so a fresh-but-equal array reassigns the model, which destroys
    // and recreates every WindowTile delegate underneath it — and with it, every live
    // ScreencopyView capture mid-hold. That is invisible offscreen (no captures exist in this
    // tier) but real on a live desktop: a held workspace peek would restart all its captures on
    // compositor traffic that has nothing to do with it. The fix mirrors the grid's own
    // `tilesModel` reconciliation (`rowDiffers`, above): build the candidate list, fold a cheap
    // signature over exactly the fields `_placeWindows`/`peekTiles` (logic.js) actually consume,
    // and hand back the PREVIOUS array — same object, same identity — whenever the signature
    // still matches. A workspace switch mid-hold (a new `wsId`) always misses the cache, so the
    // mini-map still repaints immediately when the peek re-targets to a different workspace.
    //
    // ONE property holding a mutable object, not three scalar properties: `workspaceWindows`'s own
    // binding calls this function, so on a cache HIT this function both reads and (on a miss)
    // writes the cache in the same pass. Reassigning a `property var` from inside another
    // property's binding evaluation trips QML's binding-loop detector (`Binding loop detected for
    // property "workspaceWindows"` — seen and removed while writing this), even though the
    // read/write here is safe and terminates. Mutating this object's OWN fields in place, instead
    // of reassigning the property that holds it, changes nothing QML's property system can see
    // (no assignment, no change notification) and avoids the false loop entirely.
    property var _peekWsWinCache: ({ id: -1, sig: "", list: [] })
    function peekWorkspaceWindowsFor(wsId) {
        var out = [], sig = ""
        for (var i = 0; i < root._windows.length; i++) {
            var w = root._windows[i]
            if (w.workspaceId !== wsId) continue
            out.push(w)
            sig += w.address + "|" + w.ax + "|" + w.ay + "|" + w.sw + "|" + w.sh + "|" +
                   w.floating + "|" + w.fullscreen + "|" + w.workspaceId + ";"
        }
        var c = _peekWsWinCache
        if (wsId === c.id && sig === c.sig) return c.list
        c.id = wsId; c.sig = sig; c.list = out
        return out
    }
    // ---- Actions: the arrow-key window cursor ----------------------------------------------
    // The keyboard's window target inside the selected workspace. "" = none. Mirrored into the
    // tiles model as the `cursor` role so the ring is a binding, not an imperative repaint.
    property string cursorAddress: ""
    function setCursor(addr) {
        if (cursorAddress === addr) return
        cursorAddress = addr
        applyCursorRole()
    }
    function applyCursorRole() {
        for (var i = 0; i < tilesModel.count; i++) {
            var cur = tilesModel.get(i)
            var next = { cursor: cur.address === root.cursorAddress }
            if (rowDiffers(cur, next)) tilesModel.set(i, next)
        }
    }
    // The model rows as cycleWindows wants them. Canvas coordinates, so a fullscreen window's
    // recovered slot and a floating window's real position both sort where they are drawn.
    function tileRows() {
        var out = []
        for (var i = 0; i < tilesModel.count; i++) {
            var t = tilesModel.get(i)
            out.push({ address: t.address, wsid: t.wsid, x: t.wx, y: t.wy, w: t.ww, h: t.wh })
        }
        return out
    }
    function closeSkipSet() {
        var skip = {}
        for (var a in pendingCloses) skip[a] = true
        return skip
    }
    function navigateCursor(dir) {
        selectFocusedIfNone()
        if (!Logic.hasWs(selectedId)) return
        setCursor(Logic.navigateWindows(tileRows(), selectedId, cursorAddress, dir, closeSkipSet()))
    }
    // Focus one window and leave: the tile-click path, including the scratchpad raise (focus alone
    // leaves a scratchpad window under whichever floating sibling was last on top).
    function focusWindow(addr) {
        var win = _windowByAddress[addr]
        if (win && Logic.isScratchpad(win.workspaceId)) Hyprland.dispatch(Logic.scratchpadFocusLua(addr))
        else Hyprland.dispatch('hl.dsp.focus({ window = "address:' + addr + '" })')
        close()
    }
    // Enter: whatever the target rule names.
    function activateTarget() {
        var t = resolveTarget()
        if (!t) return
        if (t.kind === "workspace") jump(t.id)
        else focusWindow(t.address)
    }
    // ---- Actions: outstanding closes -------------------------------------------------------
    // A close is a REQUEST: the app may prompt, delay or refuse, and Hyprland keeps reporting the
    // window until it is really gone. addr → deadline (1.8 s, like the other pending maps).
    property var pendingCloses: ({})
    function applyClosingRoles() {
        for (var i = 0; i < tilesModel.count; i++) {
            var cur = tilesModel.get(i)
            var next = { closing: !!pendingCloses[cur.address] }
            if (rowDiffers(cur, next)) tilesModel.set(i, next)
        }
    }
    // Drop every optimistic display state held for `addr`, exactly as a new grab does. Without
    // this, applyTiles would keep a just-dropped window's row (it skips updates AND removals for
    // an address in pendingMoves) until its deadline, outliving the action taken on it.
    function supersedePending(addr) {
        delete pendingMoves[addr]
        delete pendingFullscreen[addr]
        setTileRoles(addr, { fsPending: false })
    }
    // The one close path: Ctrl+W and the middle click land here today; a future menu Close would
    // too.
    function closeWindow(addr, advanceCursor) {
        if (!addr || pendingCloses[addr]) return
        supersedePending(addr)
        pendingCloses[addr] = Date.now() + 1800
        if (advanceCursor)
            setCursor(Logic.cycleWindows(tileRows(), selectedId, addr, 1, closeSkipSet()))
        applyClosingRoles()
        Hyprland.dispatch('hl.dsp.window.close({ window = "address:' + addr + '" })')
        scheduleRebuild()
        reconcileTimer.restart()
    }
    function closeTarget() {
        if (dragTile !== null) return          // a drag owns the pointer; actions wait
        var t = resolveTarget()
        if (!t) return
        // ✎ 2026-09-18 A workspace is not a closable thing — EXCEPT when it names exactly one
        // window, which close and close-all would treat identically anyway (Logic.loneWindow, and
        // the `windowCount > 1` gate the menu's Close all already carries). Resolved here rather
        // than in Logic.target so the carve-out belongs to close alone: widening the shared target
        // rule would also turn Enter on such a workspace from a jump into a focus.
        var addr = t.kind === "window" ? t.address
                                       : Logic.loneWindow(tileRows(), t.id, closeSkipSet())
        if (!addr) return
        closeWindow(addr, addr === cursorAddress)
    }
    // As conservative as reconcileMoves: absence from `windows` alone never clears an entry. A
    // window on a workspace that just became a lock placeholder is ALSO absent (find/drag never
    // see a placeholder's windows — see buildInput), and is not gone; treating that absence as
    // "the close went through" would drop the tracking and let a second Ctrl+W fire a duplicate
    // the moment the placeholder clears. Only the deadline decides.
    function reconcileCloses() {
        for (var addr in pendingCloses)
            if (Date.now() >= pendingCloses[addr]) delete pendingCloses[addr]
        applyClosingRoles()
    }
    Timer {
        id: reconcileTimer
        interval: 120; repeat: true
        onTriggered: root._reconcileStep()
    }
    function setTileRoles(addr, roles) {
        for (var i = 0; i < tilesModel.count; i++)
            if (tilesModel.get(i).address === addr) { tilesModel.set(i, roles); return }
    }
    // ---- Actions: the context menu ---------------------------------------------------------
    // Lives at PANEL level, not in the canvas: the Flickable clips, so a canvas-level menu opened
    // near the viewport's bottom edge would be cut off. Position is recorded in panel coordinates.
    property bool menuOpen: false
    property var menuTarget: null          // { kind: "window", address } | { kind: "workspace", id }
    property var menuItems: []
    property int menuIndex: -1
    // The raw press point, in panel coordinates, UNCLAMPED. Clamping happens at the instantiation
    // site instead of here, against the menu's own live width/height — see the comment there for
    // why: contextMenu.width is not valid synchronously when openMenu() runs.
    // Scene coordinates, from mapToItem(null, …). NOT mapToItem(panel, …): in the running shell
    // `panel` is a PanelWindow — a Window, not an Item — and passing it to mapToItem throws
    // "Passing incompatible arguments to C++ functions from JavaScript is not allowed", killing the
    // handler before the menu ever opens. The offscreen fixture cannot catch that, because
    // prepare.py rewrites every `PanelWindow {` into `Item {`, which makes the call legal there.
    // The menu's parent is the panel's content item at (0, 0), so scene coordinates are exactly
    // what its x/y want.
    property real menuRawX: 0
    property real menuRawY: 0
    // The key that dismissed the menu, swallowed until its real release: holding a letter down
    // through a dismissal must not start a query with the repeats that follow.
    property int menuDismissKey: 0

    function monitorList() {
        var out = [], ms = Hyprland.monitors ? Hyprland.monitors.values : []
        for (var i = 0; i < ms.length; i++) if (ms[i] && ms[i].name) out.push({ name: ms[i].name })
        return out
    }
    function menuContext() {
        if (!menuTarget) return null
        if (menuTarget.kind === "window") {
            var w = _windowByAddress[menuTarget.address] || null
            // The window's OWN workspace box, not the selected one (docs/specs/2026-09-15-
            // actions-design.md, "The menu", addendum 2026-09-17): the workspace rows a window's
            // menu carries act on where the window actually lives.
            return { win: w, box: w ? boxForWs(w.workspaceId) : null, monitors: monitorList() }
        }
        return { win: null, box: boxForWs(menuTarget.id), monitors: monitorList() }
    }
    function refreshMenuItems() {
        var ctx = menuContext()
        menuItems = ctx ? Logic.menuItems(menuTarget, ctx) : []
    }
    // `p` is the press point in PANEL coordinates, recorded as-is — no geometry here. Clamping it
    // against contextMenu.width/height at THIS point would read a stale value: that width comes
    // from a Repeater of Text delegates, resolved in a later polish pass, not synchronously with
    // the `items` write above. Read here it would still be the previous menu's settled width (150,
    // the floor, on the very first open) — not this menu's real, possibly wider, size. The
    // instantiation site clamps itself instead, as a binding against its own live width/height,
    // so the position re-evaluates the moment that width actually settles.
    function openMenu(tgt, p) {
        if (dragTile !== null) return                  // a drag owns the pointer
        menuTarget = tgt
        menuIndex = -1
        menuDismissKey = 0
        refreshMenuItems()
        if (!menuItems.length) { menuTarget = null; return }   // nothing modal appeared: nothing to cancel
        peekAbort()                                     // a modal and a peek are never both up
        menuOpen = true
        menuRawX = p.x
        menuRawY = p.y
    }
    function openWindowMenu(addr, p) { openMenu({ kind: "window", address: addr }, p) }
    function openWorkspaceMenu(id, p) { openMenu({ kind: "workspace", id: id }, p) }
    // `menuItems` is deliberately NOT cleared here. ContextMenu's width, height and rows all bind
    // to it, so emptying it on dismiss would collapse the menu to a sliver and fade *that* out
    // instead of fading the menu in place. `menuOpen` is what gates everything — the key branch,
    // the catcher, the staleness recompute — so stale rows behind a closed menu are inert, and
    // openMenu() replaces them before it shows anything.
    function menuDismiss() {
        if (!menuOpen) return
        menuOpen = false; menuTarget = null; menuIndex = -1
    }
    function menuActivate(i) {
        var list = menuItems, tgt = menuTarget
        var id = (i >= 0 && i < list.length) ? String(list[i].id) : ""
        menuDismiss()                                   // activation dismisses first, then acts
        if (id) runMenuAction(id, tgt)
    }
    // Every key while the menu is open. Up/Down stay inside it; everything else leaves it, and
    // the key that leaves owns its own auto-repeats until released. Logic.menuNavigate takes the
    // item list, not a count, so it can step past a separator — not hoverable, not activatable,
    // and never a landing place even when wrapping off either end.
    function menuKey(e) {
        if (e.key === Qt.Key_Up) { menuIndex = Logic.menuNavigate(menuItems, menuIndex, -1); return }
        if (e.key === Qt.Key_Down) { menuIndex = Logic.menuNavigate(menuItems, menuIndex, 1); return }
        menuDismissKey = e.key
        if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) menuActivate(menuIndex)
        else menuDismiss()
    }
    // Every menu id names a state to set. A window action first supersedes that address's
    // optimistic display state, exactly as a new grab does — otherwise applyTiles would keep a
    // just-dropped window's row (it skips updates AND removals while a move is pending) and the
    // stale tile would outlive the action taken on it.
    function runMenuAction(id, tgt) {
        if (!tgt) return
        if (tgt.kind === "window") {
            var addr = tgt.address
            if (id === "close") { closeWindow(addr, addr === cursorAddress); return }
            if (id === "float" || id === "tile" || id === "fullscreen" || id === "unfullscreen") {
                supersedePending(addr)
                if (id === "float" || id === "tile") {
                    Hyprland.dispatch(Logic.setFloatLua(addr, id === "float"))
                } else {
                    var mode = id === "fullscreen" ? 2 : 0
                    pendingFullscreen[addr] = { mode: mode, deadline: Date.now() + 1800 }
                    // Only the EXIT direction hides anything optimistically: there is no badge to
                    // hide when entering, and the slot changes when fresh geometry lands.
                    setTileRoles(addr, { fsPending: mode === 0 })
                    Hyprland.dispatch(Logic.setFullscreenLua(addr, mode))
                }
                scheduleRebuild()
                reconcileTimer.restart()
                return
            }
            // Everything else reaching a window's menu is a row from its WORKSPACE'S group,
            // below the separator (docs/specs/2026-09-15-actions-design.md, "The menu", addendum
            // 2026-09-17) — it acts on the window's own workspace, not the selected one.
            var w = _windowByAddress[addr]
            if (!w) return
            runWorkspaceMenuAction(id, w.workspaceId)
            return
        }
        runWorkspaceMenuAction(id, tgt.id)
    }
    // The rows every workspace-acting menu shares, whichever menu (window, well or badge) they
    // were reached through. Close all asks first (below): every entry point goes through the
    // same confirmation, so the guarantee does not depend on which one was used.
    function runWorkspaceMenuAction(id, wsId) {
        if (id === "lock" || id === "unlock") { lockSet(wsId, id === "lock"); return }
        if (id === "closeAll") { openCloseAllConfirm(wsId); return }
        if (id.indexOf("move:") === 0) { moveWorkspace(wsId, id.slice(5)); return }
        if (id.indexOf("swap:") === 0) { swapWorkspace(wsId, id.slice(5)); return }
    }
    // ---- Close all: confirmation ----------------------------------------------------------
    // ✎ Close all asks first (added 2026-09-17): a mis-aimed pick closes every window on a
    // workspace irreversibly, with no per-application save prompt for anything already saved.
    // Gates EVERY entry point (window menu, well, badge) — runWorkspaceMenuAction is the one
    // place all three converge, so the guarantee holds regardless of which menu was used.
    property bool confirmOpen: false
    property int confirmCloseAllWs: -1
    function openCloseAllConfirm(wsId) {
        if (!Logic.hasWs(wsId)) return
        confirmCloseAllWs = wsId
        confirmDialog.selectedIndex = 0   // default to Cancel: this is the destructive path
        peekAbort()                                     // a modal and a peek are never both up
        confirmOpen = true
    }
    function cancelCloseAllConfirm() {
        confirmOpen = false
        confirmCloseAllWs = -1
    }
    function confirmCloseAllConfirmed() {
        confirmOpen = false
        var wsId = confirmCloseAllWs
        confirmCloseAllWs = -1
        closeAllOn(wsId)
    }
    // Hint tiers. Kept on the component (keepLoaded), so the preference survives a summon but
    // not a shell restart; deliberately not written to config — it is a transient affordance.
    property bool hintsExpanded: false
    // ---- Find -------------------------------------------------------------------------
    // Query edit: the best match for the *new* query is always the selection (a window that
    // won for "s" must not stay selected once "slack" ranks another first).
    function setQuery(q) {
        if (q.length) setCursor("")      // find and the cursor are the same intent; never both
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
        Hyprland.dispatch(Logic.setFullscreenLua(addr, 0))
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
        if (box.placeholder) {                     // dispatch only: no optimistic row, no pending entry
            var ppos = win.floating ? Logic.dropToWindowPos(dropX, dropY, box, mon, params, win) : null
            if (ppos) Hyprland.dispatch(Logic.floatingMoveLua(addr, targetWs, ppos))
            // A tiled source gets a plain move (no split side): a placeholder box shows no
            // tiles, so there is no anchor window to insert against.
            else Hyprland.dispatch('hl.dsp.window.move({ workspace = "' + Logic.wsSelector(targetWs) +
                                   '", follow = false, window = "address:' + addr + '" })')
            scheduleRebuild()
            return
        }
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
                                matched: false, selectedMatch: false,
                                cursor: t.address === root.cursorAddress, closing: false })
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
            // synthetic/active are not roles here: the menu reads them off root.boxes
            // (Logic.layout()'s raw output via boxForWs()), not boxesModel, and active flips on
            // every workspace switch — an unread role would make rowDiffers fire a model set()
            // with no visible effect on every such switch, even off-screen.
            var row = { workspaceId: b.workspaceId, bx: b.x, by: b.y, bw: b.w, bh: b.h,
                        focused: !!b.focused, occupied: !!b.occupied,
                        armed: !!b.armed, placeholder: !!b.placeholder,
                        // Not read by the overview yet.
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
        // Snapshotted before anything below runs a fresh resolveTarget(): this is fundamental to
        // how the disappearance check works, not a workaround for the order operations happen to
        // run in. `Logic.target` falls THROUGH on disappearance rather than going null — a closed
        // window's cursor lands on the selected workspace, a destroyed workspace's selection lands
        // on its neighbour — and that fall-through is the CORRECT, permanent answer for what the
        // peek should show next, exactly like every other live retarget (Tab, an arrow, a hover).
        // `PeekLayer.peekTarget` is a plain binding on `resolveTarget()`, so the moment this
        // function reassigns the `boxes`/`_windowByAddress` it depends on, that binding re-
        // resolves to the survivor — synchronously, before this function reaches the check below —
        // and `onPeekTargetChanged` (Task 8, on PeekLayer) writes that survivor's identity into
        // `root.peekedKey`. By the time the check runs, `root.peekedKey` no longer names what was
        // on screen when this rebuild started; it already names what replaces it. The check needs
        // the identity from BEFORE that re-resolve — the only way to tell "this vanished and fell
        // through to a valid neighbour" apart from "this is still here and I'm looking at it
        // normally" — so it must be captured here, at entry, not read live at the check site.
        var peekedAtEntry = root.peekedKey
        buildHandles()
        var input = buildInput()
        // A box that just became a placeholder must not keep an optimistic tile (it would be a
        // live capture on a box that shows none): drop pending moves into it before applyTiles.
        // Target-only: a pending move OUT of a box that becomes a placeholder keeps its row
        // until it lands or times out — bounded by the pending deadline, and the window itself
        // is under this same rule once it settles on the placeholder side.
        if (Object.keys(pendingMoves).length) {
            var ph = {}
            for (var pw = 0; pw < input.workspaces.length; pw++) {
                var w = input.workspaces[pw]
                if (w.placeholder) ph[w.id] = true
            }
            for (var pa in pendingMoves) if (ph[pendingMoves[pa].workspaceId]) delete pendingMoves[pa]
        }
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
        reconcileCloses()
        if (!Object.keys(pendingMoves).length && !Object.keys(pendingFullscreen).length &&
            !Object.keys(pendingCloses).length) reconcileTimer.stop()
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
        // The cursor survives only while its window is still on the selected workspace. No
        // successor rule (unlike find): nothing was typed here that a successor would preserve.
        if (cursorAddress) {
            var cw = wmap[cursorAddress]
            if (!cw || cw.workspaceId !== root.selectedId) cursorAddress = ""
        }
        applyCursorRole()
        // Peek: the target's DISAPPEARANCE cancels the hold (spec: "A disappearing target cancels
        // the hold"). Tested against the model, never against resolveTarget(): that falls THROUGH
        // on disappearance — a cleared cursor lands on the selected workspace, a find match on its
        // successor — so a null test would never fire and the peek would silently slide to a
        // target the user never chose. Navigation needs no case here: it changes what resolves
        // while the old identity is still in the model. Checked against `peekedAtEntry`, the
        // identity captured BEFORE this rebuild's own resolveTarget() re-resolved — `root.peekedKey`
        // itself already names the fall-through survivor by this point (see that snapshot's own
        // comment), which is the right target for the NEXT peek but the wrong one to test here.
        if (peeking && peekedAtEntry) {
            var pk = peekedAtEntry.slice(2), gone = false
            if (peekedAtEntry.charAt(0) === "w") gone = !wmap[pk]
            else gone = Logic.indexOfWorkspace(res.boxes, parseInt(pk, 10)) < 0
            if (gone) peekAbort()
        }
        // An open menu follows fresh data: it dismisses when its target is gone (menuItems returns
        // an empty list for a missing window or box) and relabels in place otherwise, keeping the
        // highlight on the same item id — or, for a toggle row whose id itself is the thing that
        // just changed (float <-> tile, lock <-> unlock, fullscreen <-> unfullscreen), on the same
        // POSITION: an id search can never find "float" in a list that now says "tile" for the
        // very same row, so falling back to the old index (clamped) is what keeps the highlight on
        // the row the user was looking at instead of dropping it to "none".
        if (menuOpen) {
            var keepId = (menuIndex >= 0 && menuIndex < menuItems.length) ? String(menuItems[menuIndex].id) : ""
            var keepIndex = menuIndex
            refreshMenuItems()
            if (!menuItems.length) menuDismiss()
            else {
                var ni = -1
                for (var mi = 0; mi < menuItems.length; mi++)
                    if (String(menuItems[mi].id) === keepId) { ni = mi; break }
                if (ni < 0 && keepIndex >= 0 && keepIndex < menuItems.length) ni = keepIndex
                menuIndex = ni
            }
        }
        rematchAfterRebuild()   // a query survives rebuilds; windows may have come or gone
    }

    function selectByTab(step) {
        if (!boxes.length) return
        selectedIndex = Logic.cycleWorkspace(boxes, selectedIndex, step)
        ensureSelectedVisible()
    }
    // Spatial selection over the boxes. No key reaches it any more -- the arrows step windows --
    // but it is the one place the grid's geometry drives the selection, and the tests use it.
    function selectByNav(dir) {
        if (!boxes.length) return
        var i = selectedIndex < 0 ? 0 : selectedIndex
        selectedIndex = Logic.navigate(boxes, i, dir)
        ensureSelectedVisible()
    }
    // Nothing selected yet (a fresh open) means the workspace you are on.
    function selectFocusedIfNone() {
        if (selectedIndex >= 0 || !boxes.length) return
        for (var i = 0; i < boxes.length; i++) if (boxes[i].focused) { selectedIndex = i; return }
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
        // The staged entrance is bar-mode only: a top-down stagger under a card that scales from
        // its centre reads as a bug. With motion off, progress is SET, never animated — an
        // unplayed animation would leave every row at 0, i.e. an invisible grid.
        config.probeWallpaper()          // a theme switch between summons must not show the old one
        openAnim.stop()
        if (root.barMode && root.motion.enabled) { root.entranceOpen = 0; openAnim.start() }
        else root.entranceOpen = 1
        lockUnresolvedNotified = false; lockInvalidNotified = false
        lockInstall(); lockSync(); locks.refresh()
        resetFind(); setCursor(""); menuDismiss(); menuDismissKey = 0; cancelCloseAllConfirm()
        peekReset()                                 // nothing carries over from the previous summon
        // A keyboard summon (SUPER+P is a compositor keybind the overview never sees as a key
        // event) must hand the target to the keyboard until the pointer actually moves again —
        // "most recent input device wins" means the device that summoned the overview, not
        // wherever the mouse was left resting the last time it closed. Only the flags reset:
        // pointerSceneX/Y are left alone, so if the real pointer has not moved at all since the
        // last close, the next onPointChanged/notePointerMove sees the SAME position and does not
        // spuriously flip liveness back on (see notePointerMove's early-return guard); and where
        // it does differ — the mouse moved while the overview was unmapped, or this is the first
        // summon of the session — the mapping's own hover report is taken as the position to
        // measure the next move against, not as that move (see pointerPrimed).
        pointerLive = false; pointerPrimed = false; pointerPrime.restart()
        _showVisuals(true)                         // before the first rebuild: layout motion is gated on it
        rebuild()          // instant paint from current data
        flick.contentX = 0; flick.contentY = 0   // fresh scroll every open (kept-loaded state would otherwise leak the last offset)
        ensureSelectedVisible()
        scheduleRebuild()  // then settle as fresh toplevel geometry lands
        Qt.callLater(function () { keyCatcher.forceActiveFocus() })
    }
    function close() {
        if (!opened) return                        // a click on the scrim mid-fade is not a second close
        endDrag(); menuDismiss(); cancelCloseAllConfirm()
        peekAbort()                                 // the release will never arrive at an unfocused surface
        // settleTimer is open-only; reconcileTimer keeps running (bounded by the 1.8 s
        // deadlines): it clears optimistic display state (pendingMoves / fsPending / pendingCloses)
        // so a re-summon inside that window shows authoritative state, and with keepLoaded the
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
        root.entranceOpen = 1
        root.entranceScale = 1                     // NEVER card.scale = 1 here: card.scale now
                                                     // carries a live binding, and an imperative
                                                     // assignment to a bound property destroys
                                                     // the binding permanently (same failure
                                                     // shape as the ternary-anchor bug).
        card.opacity = on ? 1 : 0
        scrimRect.opacity = on ? 1 : 0
    }
    ParallelAnimation {
        id: enterAnim
        NumberAnimation { target: scrimRect; property: "opacity"; to: 1
                          duration: root.motion.normal; easing.type: root.motion.move }
        NumberAnimation { target: card; property: "opacity"; to: 1
                          duration: root.motion.enter; easing.type: root.motion.move }
        // Animates entranceScale, not card.scale: card.scale is a live binding
        // (barMode ? 1 : entranceScale) so a mid-flight mode flip is picked up instantly instead
        // of waiting for this animation's stale trajectory to finish (see entranceScale's
        // comment). Values are unconditional again -- the mode-awareness moved to the binding.
        NumberAnimation { target: root; property: "entranceScale"; from: 0.96; to: 1
                          duration: root.motion.enter; easing.type: root.motion.entrance
                          easing.overshoot: root.motion.overshoot }
    }
    ParallelAnimation {
        id: exitAnim
        NumberAnimation { target: scrimRect; property: "opacity"; to: 0
                          duration: root.motion.exit; easing.type: root.motion.move }
        NumberAnimation { target: card; property: "opacity"; to: 0
                          duration: root.motion.exit; easing.type: root.motion.move }
        NumberAnimation { target: root; property: "entranceScale"; to: 0.98
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
        function onRawEvent(event) {
            if (event && event.name === "configreloaded") { root.lockInstall(); root.lockSync() }
            // The compositor just moved keyboard focus to a window while the picker is up (a close,
            // a workspace switch, a special workspace opening, a monitor focus change — see
            // Logic.focusStealingEvent), which takes the keys off this overlay's on-demand layer.
            // Re-grant them with a cursor warp (Logic.regrabFocusLua). Gated on `opened` only, and
            // never on our own pendingCloses: a window closing by itself steals focus the same way,
            // and the close event carries a bare hex address that would need prefix-matching anyway.
            if (event && root.opened && Logic.focusStealingEvent(event.name))
                Hyprland.dispatch(Logic.regrabFocusLua())
            // Share-time reminder frame (addendum): each monitor's `lastIpcObject` is a snapshot,
            // and the frame is a binding on it. These are the events after which the workspace a
            // monitor SHOWS may have changed (Logic.lockFrameRefreshEvent) — deliberately not the
            // whole stream, since a refresh is an IPC round trip. Runs whether or not the overview
            // is open: the frame is a desktop cue, not part of the picker.
            if (event && Logic.lockFrameRefreshEvent(event.name)) {
                if (typeof Hyprland.refreshMonitors === "function") Hyprland.refreshMonitors()
                // Same events, second reason: `monitorFor()` may now answer with a DIFFERENT
                // object for the same screen (see monitorEpoch).
                root.monitorEpoch++
            }
            if (root.opened) root.scheduleRebuild()
        }
    }
    // The watched config file changing the padded workspace count while open: the compositor
    // data is not stale, so a plain rebuild re-lays the wells at once. `lockBorder`/
    // `lockBorderSize` need no handler at all now — the frame binds to them directly.
    Connections {
        target: config
        function onWorkspacesChanged() { if (root.opened) root.rebuild() }
    }

    // Share-time reminder frame: one per screen, four strips each (LockFrame.qml). Lives outside
    // the overview's own PanelWindow — it is on screen while a share runs, whether or not the
    // picker is open — and is therefore gated on the manifest's keepLoaded, like every other
    // always-on part of this component.
    Variants {
        model: Quickshell.screens
        LockFrame {
            required property var modelData
            frameScreen: modelData
            // The comma operator is the dependency: `monitorEpoch` is read (and so captured) on
            // every evaluation, `monitorFor()`'s one-shot result is what the binding yields.
            monitor: (root.monitorEpoch, Hyprland.monitorFor(modelData))
            sharing: locks.sharing
            armed: locks.armed
            frameColor: Logic.lockColorToQml(config.lockBorder)
            thickness: config.lockBorderSize
        }
    }

    // Click-catcher for the OTHER screens: the overview is a single surface on the focused screen,
    // so a click on another monitor would otherwise land on that monitor's windows and leave the
    // overview open. One transparent overlay per non-target screen, only while opened; it swallows
    // the click (the same as the outside-click on the overview's own screen does) and closes.
    Variants {
        model: Quickshell.screens
        PanelWindow {
            required property var modelData
            objectName: "omascapeCatcher"
            // Never on the target screen: it would sit above the card and eat every click meant
            // for it. `targetScreen` is an element of `Quickshell.screens` (focusedScreen()), the
            // same objects this model carries, so identity is the comparison.
            visible: root.opened && modelData !== root.targetScreen
            screen: modelData
            anchors { top: true; bottom: true; left: true; right: true }
            color: "transparent"
            WlrLayershell.namespace: "omascape-catcher"
            WlrLayershell.layer: WlrLayer.Overlay
            // No keyboard interactivity at all: Hyprland only moves keyboard focus to a layer
            // surface under the pointer when its interactivity is not `none`, so a focus-less
            // catcher leaves the keys with the overview's own (OnDemand) surface however far the
            // pointer wanders. It must NOT be Exclusive either — see the panel's keyboardFocus.
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
            exclusionMode: ExclusionMode.Ignore
            // On PRESS, not click: a drag begun on another monitor must not leave the overview up.
            MouseArea { anchors.fill: parent; onPressed: root.close() }
        }
    }

    PanelWindow {
        id: panel
        // Stays mapped through the exit fade (the pattern Omarchy's PopupCard uses); keyboard
        // focus is released the moment `opened` drops, not when the fade ends.
        visible: root.opened || card.opacity > 0
        screen: root.targetScreen
        anchors { top: true; bottom: true; left: true; right: true }
        color: "transparent"
        WlrLayershell.namespace: "omascape"
        WlrLayershell.layer: WlrLayer.Overlay
        // OnDemand, not Exclusive. Hyprland 0.56 (InputManager.cpp, mouseMoveUnified: "forced above
        // all") routes EVERY pointer event to the exclusive layer surfaces while any exists — and
        // when the cursor is over none of them it hands the event to the first one anyway, at
        // out-of-bounds coordinates. So with Exclusive, a click on another monitor never reached
        // that monitor's catcher (nor its windows: the other screen went dead). An OnDemand overlay
        // layer still grabs keyboard focus the moment it maps (LayerSurface.cpp, GRABSFOCUS) and
        // keeps it while the pointer is over it or over a focus-less surface like the catcher
        // (the refocus at mouseMoveUnified requires interactivity != none), so bare keys keep
        // reaching keyCatcher, and pointer routing is the normal per-monitor hit test.
        WlrLayershell.keyboardFocus: root.opened ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None
        // Pointer input is released the moment `opened` drops, like keyboard focus: an empty
        // input region makes the fading surface click-through.
        mask: root.opened ? null : emptyRegion
        Region { id: emptyRegion }
        exclusionMode: ExclusionMode.Ignore

        // Starts BELOW the bar when the card is attached to it: a card meeting a dimmed bar
        // reads as covering it, not as hanging from it, which is the whole point of attaching.
        Rectangle { id: scrimRect
                    anchors { left: parent.left; right: parent.right; bottom: parent.bottom
                              top: parent.top; topMargin: root.barMode ? root.reservedTop : 0 }
                    color: root.scrim; visible: config.scrim; opacity: 0 }
        MouseArea { anchors.fill: parent; enabled: root.opened; onClicked: root.close() }

        // A 28% shadow reads on light themes but vanishes on dark ones (Tokyo Night sweep),
        // so the alpha follows the card's luminance.
        // SoftShadow's own defaults (blur 28, offset 0,6). A deeper shadow was tried on this
        // branch — blur 48, offset (0,12), alpha 0.65/0.38 — on the reasoning that the card must
        // lift off the desktop now that there is real air around it. Reverted after looking at
        // it: raising blur, offset and alpha together was too much, and the border added below
        // already does the lifting the deeper shadow was for. Doing both was double.
        SoftShadow {
            id: cardShadow
            target: card; scale: card.scale; opacity: card.opacity
            // In bar mode the halo must not reach ABOVE the card. This surface is
            // WlrLayer.Overlay and the bar is WlrLayer.Top, so whatever the shadow paints above
            // the card's top edge lands on the bar itself. The halo reaches `blur - offset.y`
            // upward, which at the defaults is 28 - 6 = 22 px: almost the whole of a 26 px bar,
            // darkened at up to 0.55 alpha. That reads as the card and the bar not matching --
            // in EVERY theme, and whether the bar is painting a colour or showing the desktop,
            // because it darkens the bar either way. Pushing the offset out to the blur radius
            // puts the halo's top edge exactly on the card's, leaving the shadow only below.
            // Expressed against `blur` rather than as a literal so the two cannot drift.
            offset: Qt.vector2d(0, root.barMode ? blur : 6)
            color: Qt.rgba(0, 0, 0, root.darkTheme ? 0.55 : 0.28)
        }
        Rectangle {
            id: card
            anchors.horizontalCenter: parent.horizontalCenter
            // NOT a ternary pair (`verticalCenter: barMode ? undefined : parent.verticalCenter` /
            // `top: barMode ? parent.top : undefined`). A QML binding that evaluates to
            // `undefined` is DESTROYED, not merely skipped for that one evaluation, so such a pair
            // survives exactly one mode flip and then stays corrupt — silently, no anchor-conflict
            // warning — for the rest of the card's life. `card` is never recreated across
            // open()/close(), and `barMode` can flip live (hiding the bar while the picker is open
            // drops `reservedTop` to 0), so this is reachable, not theoretical. `AnchorChanges`
            // inside a `State` exists precisely because anchors can't be rebound by a ternary; it
            // reverses cleanly on state exit.
            anchors.verticalCenter: parent.verticalCenter
            states: State {
                name: "bar"
                when: root.barMode
                AnchorChanges {
                    target: card
                    anchors.verticalCenter: undefined
                    anchors.top: card.parent.top
                }
            }
            anchors.topMargin: root.reservedTop
            // Full width in bar mode. Setting `width` overrides the implicitWidth binding, so
            // the Behavior on implicitWidth goes inert there — correct, since the width is the
            // screen and must never animate.
            width: root.barMode ? panel.width : implicitWidth
            // Square against the bar, and no border of its own: with no radius there are no top
            // corners to hide, so nothing is ever painted OVER the card. That matters because
            // barBackground may carry alpha, and two stacked translucent fills composite darker
            // than one (two at 50% give 75%), which is what a cover-up strip would produce.
            radius: root.barMode ? 0 : root.cardRadius
            border.width: root.barMode ? 0 : 1
            // Three grounds. Wallpaper-backed, the Rectangle paints nothing and the Image
            // below is the ground. Attached to an opaque bar, the bar's own token. Otherwise
            // the menu ground, which is also the fallback when the wallpaper cannot be resolved.
            color: root.wallpaperBacked ? "transparent"
                 : (root.barMode && !config.barTransparent) ? root.barBackground
                 : root.background
            // With real air around the card it must read as elevated rather than as a lighter
            // rectangle. Accent-derived rather than a fixed neutral: a black hairline looks like
            // a bug on a light card and a white one vanishes on it. `accent` is already
            // `selText` and already tracks the theme, so this needs no new colour. One logical
            // px is two device px at 2x — crisp at exactly the scale that reported the problem.
            border.color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.35)
            opacity: 0        // the entrance brings it in; panel.visible follows this
            // A live binding, not the animation target itself: pins to 1 the instant barMode
            // goes true even mid-animation, rather than riding out entranceScale's in-flight
            // trajectory. See entranceScale's declaration for why that distinction matters.
            scale: root.barMode ? 1 : root.entranceScale
            // The unfurl: the card's top is pinned to the bar and its height grows, so `clip`
            // is what uncovers the rows from the top down. The Flickable inside keeps its
            // RESTING height (see its own comment) -- it is revealed, never squashed.
            clip: root.barMode
            height: root.barMode ? Math.round(root.entranceOpen * implicitHeight) : implicitHeight
            readonly property int pad: Math.round(Style.space(12))
            // Space under the grid for the key hints or, while a query is active, the find
            // bar. Reserves the larger of the two whenever either could show, so swapping one
            // for the other on the first keystroke never resizes the card by the few pixels
            // their implicitHeights happen to differ by. Zero only when both are absent.
            readonly property bool findActive: root.query.length > 0
            readonly property real hintSpace: {
                // The larger of what is actually shown: the hint tiers only when hints are
                // enabled, the find bar only while a query is active. An invisible item keeps
                // its implicitHeight in QML, so the tiers must be excluded by the config flag
                // rather than by their own visibility — otherwise a leftover expanded second
                // tier (hintsExpanded true from an earlier `?`) keeps inflating the budget after
                // config.hint turns off, even though nothing on screen explains the extra space.
                var hints = config.hint ? hintBox.implicitHeight : 0
                var bar = findActive ? findBar.implicitHeight : 0
                var h = Math.max(hints, bar)
                return h > 0 ? h + 8 : 0
            }
            // Cap the card to the screen so the Flickable viewport can be smaller than the
            // content (`availCanvasW` already keeps canvas width <= this, minus the degenerate
            // narrow-screen case, which is expected to 2-D scroll per the spec). Because
            // availCanvasW is exactly this minus 2 * pad, the WIDTH cap never binds on grid
            // width — the only thing that reaches it is the hint row, which is deliberately
            // allowed to widen a narrow card so the key hints are not clipped. The HEIGHT cap
            // does real work whenever there are enough monitor groups to overflow.
            readonly property real maxCardW: panel.width  > 0 ? panel.width  - 2 * Logic.screenMargin(panel.width)  : 1616
            readonly property real maxCardH: panel.height > 0
                ? panel.height - (root.barMode ? root.reservedTop + Logic.screenMargin(panel.height)
                                               : 2 * Logic.screenMargin(panel.height))
                : 900
            // The hint row never widens past the screen (maxCardW still caps it), but it does
            // widen a narrow card: a layout with few/narrow workspaces must not clip the eight
            // key hints against the card edge.
            implicitWidth: Math.min(Math.max(canvas.implicitWidth, config.hint ? hintBox.implicitWidth : 0) + pad * 2, maxCardW)
            implicitHeight: Math.min(canvas.implicitHeight + pad * 2 + hintSpace, maxCardH)
            // Card resize (workspaces added/removed, columns change) glides; the Flickable
            // viewport follows card.width, the canvas content is already at its new size.
            Behavior on implicitWidth  { enabled: root.layoutMotion
                NumberAnimation { duration: root.motion.normal; easing.type: root.motion.move } }
            Behavior on implicitHeight { enabled: root.layoutMotion
                NumberAnimation { duration: root.motion.normal; easing.type: root.motion.move } }
            // The wallpaper, sized and placed against the PANEL rather than the card and
            // lifted by the bar's height. That makes it the same crop of the same image at the
            // same screen position as the real wallpaper behind the bar, so the two are
            // continuous across the seam instead of merely similar. Declared first so every
            // other child paints over it; the card's own `clip` reveals it during the unfurl,
            // which is why it stays still while the card grows rather than sliding with it.
            Image {
                id: wallpaperBack
                visible: root.wallpaperBacked
                x: 0; y: -root.reservedTop
                width: panel.width; height: panel.height
                source: root.wallpaperBacked ? config.wallpaperUrl : ""
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
                cache: true
            }

            MouseArea { anchors.fill: parent; onClicked: {} }

            // The card's only visible edge in bar mode: the top is the join with the bar, the
            // sides are the screen edges. A child rather than the card's own border, because the
            // border would also draw down both sides and along the join.
            Rectangle {
                id: bottomRule
                visible: root.barMode
                anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                height: 1
                color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.35)
            }

            Item {
                id: keyCatcher
                anchors.fill: parent
                focus: true
                // The release never arrives at a surface that has lost keyboard focus, so a held
                // peek would stick open forever — the bug the spec calls out explicitly. This is
                // the primary clear; Keys.onReleased below is a second path to the same place,
                // never the only one. Attached here, not to `panel`: prepare.py rewrites `panel`
                // to a plain Item in the offscreen fixture, so its activeFocus is not guaranteed
                // to behave as it does in the real shell, whereas `keyCatcher` is the actual focus
                // item in both.
                //
                // The RETURN half exists for the same reason (review fix, round 2): the release
                // that never arrived while unfocused still never arrives once focus comes back —
                // it was lost, not merely delayed — so `peekKeyDown` and `peekCancelled` are stuck
                // exactly as `peekAbort()` above left them (key "down", cancel latched) unless
                // something clears them. Nothing else does: `peekAbort()` only runs on the loss,
                // and the physical key may genuinely still be held, so there is no key-up event to
                // wait for. Focus RETURNING is the one moment this code can know the surface is
                // live again, so it is the one moment safe to stop believing the stale "key down"
                // state and let a fresh press through. Residual and accepted, not engineered
                // around: if Space is still physically held when focus returns, the key's own next
                // auto-repeat can re-open the peek — the release was lost, so nothing here can be
                // honest about the key's real state, and re-opening under a genuinely-held key is
                // the better of the two wrong answers versus leaving the hold dead forever.
                onActiveFocusChanged: {
                    if (!activeFocus) root.peekAbort()
                    else { root.peekKeyDown = false; root.peekCancelled = false }
                }
                Keys.priority: Keys.BeforeItem
                Keys.onPressed: function (e) {
                    e.accepted = true
                    // Lone modifiers belong to no class (see Logic.isModifierKey).
                    if (Logic.isModifierKey(e.key)) return
                    // The confirmation dialog owns every key while it is open, ahead of the menu
                    // branch: this plugin has exactly one focus item, so everything is routed
                    // through here. `handleKey`'s own return is not consulted — while the dialog
                    // is open nothing else may act on the key, consumed or not.
                    //
                    // Bare Space needs one more thing done to it than "route to the dialog and
                    // return", or it reopens the peek the instant the dialog closes (review find):
                    // ConfirmDialog.handleKey() does not consume Space at all, so nothing above
                    // ever recorded that it was physically down. Dismiss the dialog with Escape
                    // while Space is still held (auto-repeating) and the very next repeat reaches
                    // the Space branch below with `peeking` and `peekCancelled` both still false —
                    // a hold this key never legitimately started, opened by a press the dialog
                    // already swallowed. The menu branch below doesn't need this: `menuDismissKey`
                    // (below) already latches the dismissing key's own repeats until release; the
                    // dialog has no such latch, so it has to build one here instead.
                    //
                    // Read directly off e.modifiers rather than `chord`: `chord` is computed
                    // further down, below every early return in this function, so it does not
                    // exist yet at this point in the branch — this dialog handler is one of those
                    // early returns.
                    //
                    // Order matters and is NOT swappable: `peekAbort()` only latches
                    // `peekCancelled` while `peekKeyDown` is already true (see both properties'
                    // own comments, and the review fix that put that guard there) — it exists
                    // specifically so a modal that opens and closes with Space never pressed does
                    // not falsely latch a cancel that only a real Space release would ever clear.
                    // Setting `peekKeyDown` first is what makes this a case `peekAbort()` is
                    // WILLING to latch: the key really is down right now, physically, so recording
                    // that before aborting is honest, not a workaround. Every later repeat of this
                    // same held Space runs this same pair again — harmless, since both are already
                    // set — right up until the real key-up, which is what finally clears them
                    // (`Keys.onReleased` below) and frees a genuinely fresh press to open normally.
                    if (root.confirmOpen) {
                        if (!(e.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier))
                                && e.key === Qt.Key_Space) {
                            root.peekKeyDown = true
                            root.peekAbort()
                        }
                        confirmDialog.handleKey(e); return
                    }
                    // The menu owns every key while it is open — checked before `finding`, so a
                    // letter dismisses instead of extending the query.
                    if (root.menuOpen) { root.menuKey(e); return }
                    // …and the key that dismissed it keeps swallowing its own repeats.
                    if (root.menuDismissKey !== 0 && e.key === root.menuDismissKey) return

                    var chord = e.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier)
                    var finding = root.query.length > 0
                    // Peek: hold Space to preview the target. Placed after the menuDismissKey
                    // swallow (so a Space that dismissed a menu does not also peek) and before
                    // the chord branch (a chorded Space is not a peek and falls through to it).
                    // Also placed before the pointerLive reset below: resolveTarget() must see
                    // pointer liveness exactly as the pointer left it. Task 3 already keeps Space
                    // out of that reset (it is an action key), so this ordering is belt and
                    // braces — but a future reordering that moved the reset above this branch
                    // would silently break pointer targeting, and this is what protects against
                    // it. Guarded on STATE, not on e.isAutoRepeat: a held key repeats, and the
                    // open decision must be made once. QtTest cannot synthesize isAutoRepeat, so
                    // a flag-only guard would have no offscreen test at all.
                    if (!chord && e.key === Qt.Key_Space) {
                        // Physical key state, set before anything else below can return early —
                        // peekAbort()'s no-target branch two lines down must see it as already
                        // down (that press legitimately latches the cancel for the rest of this
                        // hold), and every other peekAbort() call site needs to tell "a key is
                        // down right now" from "nothing is held" (see peekKeyDown's own comment).
                        root.peekKeyDown = true
                        if (root.peeking || root.peekCancelled) return
                        var pt = root.resolveTarget()
                        if (!pt) { root.peekAbort(); return }   // no target: nothing, all hold
                        // No `peekedKey = peekKeyOf(pt)` here: PeekLayer's `onPeekTargetChanged`
                        // (below, on the PeekLayer instantiation) already sets it the instant
                        // `peeking` flips true and its `peekTarget` binding re-evaluates — a
                        // duplicate write here was proven genuinely redundant (review, round 2:
                        // deleting it changes nothing, 29/29 still green), and two writers of the
                        // same property is exactly the shape that let the earlier confusion in
                        // this file happen once already. One writer.
                        root.peeking = true
                        return
                    }
                    // Action keys read pointer liveness; everything else is keyboard intent and
                    // clears it BEFORE any resolve below can see it.
                    if (!Logic.isActionKey(e.key, chord, Qt.ControlModifier)) root.pointerLive = false

                    if (chord) {
                        if (chord === Qt.ControlModifier && e.key === Qt.Key_Backspace && finding) root.setQuery("")
                        else if (chord === Qt.ControlModifier && e.key === Qt.Key_S) root.toggleScratchpad()
                        else if (chord === Qt.ControlModifier && e.key === Qt.Key_L) root.lockToggleSelected()
                        else if (chord === Qt.ControlModifier && e.key === Qt.Key_W && !e.isAutoRepeat) root.closeTarget()
                        return
                    }
                    if (e.key === Qt.Key_Escape) {
                        if (root.cursorAddress) root.setCursor("")
                        else if (finding) root.setQuery("")
                        else root.close()
                        return
                    }
                    if (e.key === Qt.Key_Backspace) {
                        if (finding) root.setQuery(root.query.slice(0, -1))
                        return
                    }
                    if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) { root.activateTarget(); return }
                    if (finding) {
                        if (e.key === Qt.Key_Tab) { root.cycleMatch(1); return }
                        if (e.key === Qt.Key_Backtab) { root.cycleMatch(-1); return }
                        if (e.key === Qt.Key_Left) { root.navigateMatch("left"); return }
                        if (e.key === Qt.Key_Right) { root.navigateMatch("right"); return }
                        if (e.key === Qt.Key_Up) { root.navigateMatch("up"); return }
                        if (e.key === Qt.Key_Down) { root.navigateMatch("down"); return }
                    } else {
                        // Tab steps workspaces and the arrows step windows: the Cmd+Tab /
                        // Alt+Tab habit, with the key that summoned the overview under the
                        // same hand.
                        if (e.key === Qt.Key_Tab) { root.setCursor(""); root.selectByTab(1); return }
                        if (e.key === Qt.Key_Backtab) { root.setCursor(""); root.selectByTab(-1); return }
                        if (e.key >= Qt.Key_1 && e.key <= Qt.Key_9) { root.setCursor(""); root.jump(e.key - Qt.Key_0); return }
                        if (e.key === Qt.Key_0) { root.setCursor(""); root.jump(10); return }
                        if (e.key === Qt.Key_Left) { root.navigateCursor("left"); return }
                        if (e.key === Qt.Key_Right) { root.navigateCursor("right"); return }
                        if (e.key === Qt.Key_Up) { root.navigateCursor("up"); return }
                        if (e.key === Qt.Key_Down) { root.navigateCursor("down"); return }
                    }
                    // `?` is the hint toggle only while there is no query to append to — the
                    // same rule digits already follow — and only while hints are enabled at all;
                    // otherwise it would flip a tier nobody can see.
                    if (!finding && config.hint && e.text === "?") { root.hintsExpanded = !root.hintsExpanded; return }
                    var next = Logic.appendQueryText(root.query, e.text)
                    if (next !== root.query) root.setQuery(next)
                }
                Keys.onReleased: function (e) {
                    e.accepted = true
                    if (root.menuDismissKey !== 0 && e.key === root.menuDismissKey && !e.isAutoRepeat)
                        root.menuDismissKey = 0
                    // The release is the ONLY thing that clears the cancel: every other exit path
                    // (a modal, focus loss, the target vanishing) leaves it set, which is what
                    // stops the layer re-opening under a key that is merely still held. It is also
                    // the only place `peekKeyDown` goes back to false, so `peekAbort()` stops
                    // latching a fresh cancel the instant the physical key comes up.
                    if (e.key === Qt.Key_Space && !e.isAutoRepeat) { root.peekKeyDown = false; root.peekRelease() }
                }
            }

            Flickable {
                id: flick
                // Centred on the card when the grid is narrower than the room available.
                // layout() lays boxes out from x = 0 and the canvas is exactly the grid's
                // width. In centred mode the card shrinks to the grid, so there is never any
                // slack; a full-width bar-mode card leaves the difference -- 108 px on a
                // 2048-logical panel, where maxCellW caps the cells at 380 before the width
                // runs out -- and the grid would hug the left edge.
                //
                // It is the FLICKABLE that moves, not the canvas: pointerPoint() maps the
                // pointer through `flick` and then calls the result canvas coordinates, which
                // is only true while canvas.x is 0. Offsetting the canvas would silently break
                // every hit test and the drag.
                readonly property real avail: card.width - card.pad * 2
                width: Math.min(canvas.implicitWidth, avail)
                x: card.pad + Math.round(Math.max(0, (avail - width) / 2))
                y: card.pad
                // card.implicitHeight, NOT card.height: during the unfurl the card is shorter
                // than its content, and sizing the viewport from the animated height would
                // drive it toward zero -- onContentHeightChanged's clamp would then scroll the
                // grid mid-animation and leave contentY wrong once it settled.
                height: card.implicitHeight - card.pad * 2 - card.hintSpace
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
                    root.menuDismiss()
                }
                onContentYChanged: {
                    if (root.dragTile) root.dragTile.y += contentY - previousY
                    previousY = contentY
                    root.updateDropTarget()
                    root.menuDismiss()
                }

                // Content shrinking (windows/workspaces closing) must never leave the viewport
                // scrolled past the new end.
                onContentWidthChanged: flick.contentX = Math.max(0, Math.min(flick.contentX, flick.contentWidth - flick.width))
                onContentHeightChanged: flick.contentY = Math.max(0, Math.min(flick.contentY, flick.contentHeight - flick.height))

                // Pointer liveness. A HoverHandler, not a hoverEnabled MouseArea: handlers do not
                // block one another (`blocking` defaults to false), so the tiles' own hover zoom
                // and title label keep working underneath this one.
                HoverHandler {
                    id: pointerWatch
                    onPointChanged: root.notePointerMove(point.scenePosition)
                    onHoveredChanged: if (!hovered) root.pointerLive = false
                }

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

                            // Arrival phase for this box's row. A Translate, not a `y` change:
                            // the y binding already carries the layout-motion Behavior, and the
                            // entrance must never fight a glide still in flight.

                            // big low-contrast numeral, only where nothing would hide it
                            Text {
                                objectName: "wsNumeral"
                                anchors.centerIn: parent
                                visible: !boxItem.model.occupied && !boxItem.model.placeholder
                                text: root.wsLabel(boxItem.model.workspaceId)
                                color: root.foreground
                                opacity: 0.10
                                font.pixelSize: Math.round(boxItem.height * 0.45)
                                font.weight: Font.DemiBold
                            }
                            // lock placeholder: the workspace is armed and a share is running —
                            // no tiles are laid out, so the well shows only this glyph.
                            Text {
                                objectName: "lockGlyph"
                                anchors.centerIn: parent
                                visible: boxItem.model.placeholder
                                text: "\u{F033E}"          // nf-md-lock
                                color: root.foreground
                                opacity: 0.25
                                font.family: root.fontFamily
                                font.pixelSize: Math.round(boxItem.height * 0.4)
                            }
                            MouseArea {   // left click on empty well => jump; right press => menu
                                anchors.fill: parent
                                enabled: root.opened
                                acceptedButtons: Qt.LeftButton | Qt.RightButton
                                onClicked: function (m) {
                                    if (m.button === Qt.LeftButton) root.jump(boxItem.model.workspaceId)
                                }
                                onPressed: function (m) {
                                    if (m.button === Qt.RightButton)
                                        root.openWorkspaceMenu(boxItem.model.workspaceId, mapToItem(null, m.x, m.y))
                                }
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
                        id: tileRepeater
                        model: tilesModel
                        WindowTile {
                            required property var model
                            // Re-evaluates when `locks.armed` changes: an armed box's windows are under a
                            // no_screen_share window rule, and Hyprland denies toplevel export of such a
                            // window outright — capturing it live would show its "permission denied" texture,
                            // not the window, so the tile falls back to its icon instead.
                            readonly property bool boxArmed: locks.isArmed(Logic.wsSelector(model.wsid))
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
                            readonly property string tileAddress: model.address
                            tileLayer: model.layer
                            fullscreen: model.fullscreen
                            fullscreenPending: model.fsPending
                            title: model.title
                            matched: model.matched
                            selectedMatch: model.selectedMatch
                            cursorTarget: model.cursor
                            // Tiles take their BOX's rank, looked up by workspace id, so a tile
                            // can never stagger out of step with the well it sits in.
                            closing: model.closing
                            dimmed: root.query.length > 0 && !model.matched && root.dropTargetAddress !== model.address
                            accent: root.accent
                            dragging: root.draggingAddress === model.address
                            handle: root.handleByAddress[model.address] || null
                            // Kept loaded while hidden (keepLoaded): captures run only while the
                            // surface is mapped. An armed box always falls back to its icon, share
                            // or not — the compositor denies the capture either way (see boxArmed).
                            capMode: (panel.visible && !boxArmed) ? "live" : "icon"
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
                                acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
                                preventStealing: true
                                drag.target: undefined
                                property bool moved: false
                                onPressed: function (m) {
                                    if (m.button === Qt.RightButton) {
                                        root.openWindowMenu(model.address, mapToItem(null, m.x, m.y))
                                        return
                                    }
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
                                        if (root.dragTile === null)   // a drag owns the pointer; actions wait
                                            root.closeWindow(model.address, model.address === root.cursorAddress)
                                        return
                                    }
                                    // Only the LEFT button ever drops or counts as a click. Before
                                    // the right button was accepted here, every non-middle release
                                    // was treated as a possible drop — a right click during a left
                                    // drag would have moved the window.
                                    if (m.button !== Qt.LeftButton) return
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
                                    if (!wasMoved) { root.focusWindow(addr) }
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
                                objectName: "wsBadgeText"
                                anchors.centerIn: parent
                                text: root.wsLabel(badge.model.workspaceId) + (badge.model.armed ? " \u{F033E}" : "")
                                color: badge.model.focused ? root.background : root.foreground
                                font.family: root.fontFamily
                                font.pixelSize: root.labelSize
                                font.weight: Font.DemiBold
                            }
                            // Right button only, so a left click still falls through to the tile
                            // or well beneath. A well filled by one tiled window leaves only the
                            // 3 px inset of bare well, which makes this the reliable target for
                            // the workspace menu.
                            MouseArea {
                                anchors.fill: parent
                                enabled: root.opened
                                acceptedButtons: Qt.RightButton
                                onPressed: function (m) {
                                    root.openWorkspaceMenu(badge.model.workspaceId, mapToItem(null, m.x, m.y))
                                }
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

            // key hints: two tiers. The primary row is what a new user needs; `?` reveals the
            // advanced keys, which would otherwise crowd it past the card width on a laptop.
            // A ground for whichever of the two bars is showing, while the card is
            // wallpaper-backed. Both are bare text, and bare text on a photograph is not
            // readable. Same glass as the wells, so the card reads as one material. Declared
            // before them so it paints behind, and sized to whichever is visible.
            Rectangle {
                id: bottomBarGlass
                visible: root.wallpaperBacked && (hintBox.visible || findBar.visible)
                readonly property Item subject: hintBox.visible ? hintBox : findBar
                x: subject.x - 14; y: subject.y - 7
                width: subject.width + 28; height: subject.height + 14
                radius: root.boxRadius
                color: root.glass(0.55)
            }

            Column {
                id: hintBox
                visible: config.hint && !card.findActive
                anchors { horizontalCenter: parent.horizontalCenter; bottom: parent.bottom; bottomMargin: 8 }
                spacing: 4
                Row {
                    id: hint
                    anchors.horizontalCenter: parent.horizontalCenter
                    spacing: Math.round(Style.space(12))
                    Repeater {
                        id: hintKeys
                        model: [ { k: "1–0", l: "jump" }, { k: "tab", l: "workspace" }, { k: "↑ ↓ ← →", l: "window" },
                                 { k: "↵", l: "select" },
                                 { k: "drag", l: "move window" }, { k: "type", l: "find" },
                                 { k: "hold space", l: "peek" },
                                 { k: "esc", l: "close" },
                                 { k: "?", l: root.hintsExpanded ? "less" : "more" } ]
                        HintCap { foreground: root.foreground; fill: root.wellColor
                                  fontFamily: root.fontFamily; fontSize: root.captionSize
                                  capOpacity: root.hintCapOpacity
                                  labelOpacity: root.hintLabelOpacity }
                    }
                }
                Row {
                    id: hint2
                    visible: root.hintsExpanded
                    anchors.horizontalCenter: parent.horizontalCenter
                    spacing: Math.round(Style.space(12))
                    Repeater {
                        id: hintKeys2
                        model: [ { k: "ctrl+w / mid-click", l: "close" },
                                 { k: "right-click", l: "menu" },
                                 { k: "ctrl+s", l: "scratchpad" }, { k: "ctrl+l", l: "lock" } ]
                        HintCap { foreground: root.foreground; fill: root.wellColor
                                  fontFamily: root.fontFamily; fontSize: root.captionSize
                                  capOpacity: root.hintCapOpacity
                                  labelOpacity: root.hintLabelOpacity }
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

        // The peek (docs/specs/2026-09-18-peek-design.md, "The peek layer"): a sibling of `card`,
        // stacked above it, needing no z-order arbitration against the menu or the confirmation
        // dialog in either direction — `Keys.onPressed` returns early for both before the `Space`
        // branch. `openMenu()` and `openCloseAllConfirm()` each force-clear the peek when they
        // actually open (Task 8), so the two are never on screen together. Display only: every
        // property below is a plain binding on root state, not a value copied at press time.
        // `shown` follows `peeking` alone (see the invariant note on `peeking`/`peekCancelled`
        // above); `peekTarget` is a binding on `resolveTarget()`, so a live Tab, arrow or hover
        // re-targets the layer without a release — no imperative `onPeekingChanged` assignment
        // anywhere in this block. PeekLayer anchors nothing itself, so this call site owns its
        // sizing.
        PeekLayer {
            id: peekLayer
            anchors.fill: parent
            // Not `root.peeking && !root.peekCancelled`: the clause was proven unreachable dead
            // code, not merely untested. `peekAbort()` is the ONLY place `peekCancelled` is ever
            // set true, and it sets `peeking = false` in that same call (see the three named
            // mutators above) — so `peeking && peekCancelled` can never both hold. A written-down
            // invariant beats a defensive clause that implies a state the code cannot reach.
            shown: root.peeking
            peekTarget: root.peeking ? root.resolveTarget() : null
            // Keeps peekedKey naming the identity CURRENTLY on screen, so the disappearance check
            // in rebuild() compares against what the user is actually looking at. Without this,
            // peekedKey would stay pinned to whatever was on screen at press time: after Tab
            // retargets the layer to a new window, closing the ORIGINAL window would wrongly
            // cancel (it is no longer shown) while closing the NEW one would not (rebuild() would
            // still be checking the stale identity).
            onPeekTargetChanged: if (root.peeking) root.peekedKey = root.peekKeyOf(peekTarget)
            monForTarget: {
                var t = peekTarget
                if (!t) return null
                if (t.kind === "window") {
                    var w = root._windowByAddress[t.address]
                    var b = w ? root.boxForWs(w.workspaceId) : null
                    return b ? root._monByName[b.monitorName] : null
                }
                var wb = root.boxForWs(t.id)
                return wb ? root._monByName[wb.monitorName] : null
            }
            // See peekWorkspaceWindowsFor's own comment: this hands back the SAME array when
            // nothing that _placeWindows/peekTiles reads has changed, so an unrelated rebuild()
            // does not reassign the Repeater's model and restart every capture underneath it.
            workspaceWindows: {
                var t = peekTarget
                return (t && t.kind === "workspace") ? root.peekWorkspaceWindowsFor(t.id) : []
            }
            // The lock gate, mirroring the grid tile's `boxArmed`: an armed workspace's windows
            // are under a `no_screen_share` rule and the compositor denies toplevel export, so
            // capturing would fire a denied request per window and show nothing. Task 5 added the
            // `armed` property for this; without this binding the gate is inert.
            armed: {
                var t = peekTarget
                if (!t) return false
                var wsId = t.kind === "workspace" ? t.id
                         : (root._windowByAddress[t.address] || { workspaceId: -1 }).workspaceId
                // Bare `locks`, not `root.locks`: it is an object id, and QML ids are not
                // reachable as properties of root. This is how the grid tile does it too.
                return Logic.hasWs(wsId) ? locks.isArmed(Logic.wsSelector(wsId)) : false
            }
            windowByAddress: root._windowByAddress
            handleByAddress: root.handleByAddress
            params: root.params
            background: root.background; foreground: root.foreground
            hairline: root.hairline; scrim: root.scrim
            // config.scrim (root state, not target-dependent) is wired now, unlike the
            // target-resolution properties above: a user who has turned the card's own scrim off
            // must not get one reintroduced just by holding Space.
            scrimVisible: config.scrim
            cardRadius: root.cardRadius
            fontFamily: root.fontFamily; captionSize: root.captionSize
            darkTheme: root.darkTheme
            motion: root.motion
        }
        // Swallows any press that is not on the menu itself. Panel-sized and above the card, so a
        // press on the scrim cannot both dismiss the menu and close the overview — one press, one
        // effect. A press on ANOTHER monitor still closes the overview (its own catcher), which is
        // the user asking to leave; the menu goes with it.
        MouseArea {
            id: menuCatcher
            anchors.fill: parent
            z: 100
            visible: root.menuOpen
            enabled: root.menuOpen
            acceptedButtons: Qt.AllButtons
            onPressed: root.menuDismiss()
        }
        ContextMenu {
            id: contextMenu
            z: 101
            // `open`, not `visible`: the component owns its own fade and drops its input region
            // once it reaches zero opacity (see ContextMenu.qml).
            open: root.menuOpen && root.menuItems.length > 0
            // Clamped here, as a binding against this item's OWN width/height, rather than as a
            // one-shot snapshot in openMenu(): width in particular comes from a Repeater of Text
            // delegates and is not known synchronously when the press happens, only once the
            // polish pass measures it — so the clamp must re-run when that settles, not once
            // upfront against a stale (often still-150-floor) value. This is what keeps the menu
            // fully on screen even when a row (e.g. "Move to <long monitor name>") widens it well
            // past the floor.
            x: Math.max(4, Math.min(root.menuRawX, panel.width - width - 4))
            y: Math.max(4, Math.min(root.menuRawY, panel.height - height - 4))
            items: root.menuItems
            index: root.menuIndex
            background: root.background
            foreground: root.foreground
            selBackground: root.selBackground
            selText: root.selText
            fontFamily: root.fontFamily
            fontSize: root.labelSize
            cornerRadius: root.boxRadius
            motion: root.motion
            onHoverRow: function (row) { root.menuIndex = row }
            onActivated: function (id) {
                var tgt = root.menuTarget
                root.menuDismiss()
                root.runMenuAction(id, tgt)
            }
        }
        // Close all asks first (docs/specs/2026-09-15-actions-design.md, "The menu", addendum
        // 2026-09-17): the shell's own Ui/ConfirmDialog, themed with everything else, gating
        // Close all from every entry point (window menu, well, badge — runWorkspaceMenuAction is
        // where all three converge). Above the menu (z), and keys are routed to it ahead of the
        // menu branch in keyCatcher — its own scrim MouseArea (inside ConfirmDialog.qml) already
        // consumes any press on it, so it needs no panel-sized catcher of its own the way the
        // menu does.
        ConfirmDialog {
            id: confirmDialog
            anchors.fill: parent
            z: 200
            opened: root.confirmOpen
            message: "Close all windows on workspace " + root.wsLabel(root.confirmCloseAllWs) + "?"
            confirmText: "Close all"
            cancelText: "Cancel"
            onCanceled: root.cancelCloseAllConfirm()
            onConfirmed: root.confirmCloseAllConfirmed()
        }
    }
}
