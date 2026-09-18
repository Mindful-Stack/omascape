.pragma library

function _index(arr, key) {
    var m = {}
    for (var i = 0; i < arr.length; i++) m[arr[i][key]] = arr[i]
    return m
}

// Monitors that have workspaces, ordered by the lowest REAL workspace id each one holds, so
// the groups read 1..10 top to bottom. Synthetic wells (padWorkspaces) never take part in the
// key — they are the one thing that may differ between two focus states — and a group with
// only synthetic wells falls back to its lowest synthetic id. Fixed regardless of focus and
// screen position: the focused group is marked, not moved.
function _orderedMonitorNames(monitors, workspaces) {
    var real = {}, any = {}
    for (var i = 0; i < workspaces.length; i++) {
        var ws = workspaces[i]; if (ws.id < 0) continue
        var m = ws.monitorName
        if (!(m in any) || ws.id < any[m]) any[m] = ws.id
        if (!ws.synthetic && (!(m in real) || ws.id < real[m])) real[m] = ws.id
    }
    var names = []
    for (var j = 0; j < monitors.length; j++)
        if (monitors[j].name in any) names.push(monitors[j].name)
    function key(n) { return n in real ? real[n] : any[n] }
    names.sort(function (a, b) {
        var ka = key(a), kb = key(b)
        return ka !== kb ? ka - kb : (a < b ? -1 : a > b ? 1 : 0)
    })
    return names
}

function _monLogical(mon) {
    var s = (mon && mon.scale) ? mon.scale : 1
    return { w: mon.width / s, h: mon.height / s }
}

function _usableRect(mon) {
    var l = _monLogical(mon)
    var r = mon.reserved || [0, 0, 0, 0]
    return { x: r[0], y: r[1], w: l.w - r[0] - r[2], h: l.h - r[1] - r[3] }
}

function _tileRect(win, mon, box, P, slot) {
    var R = _usableRect(mon)
    var mmW = box.w - 2 * P.cellInset, mmH = box.h - 2 * P.cellInset   // was P.cellW/P.cellH
    var k = Math.min(mmW / R.w, mmH / R.h)
    var offX = P.cellInset + (mmW - R.w * k) / 2
    var offY = P.cellInset + (mmH - R.h * k) / 2
    var wx, wy, sw, sh
    if (slot) {                                   // caller-decided rect (recovered slot etc.)
        wx = slot.x; wy = slot.y; sw = slot.w; sh = slot.h
    } else {
        // Callers place flagged fullscreen windows via `slot`; the geometry heuristic remains
        // for unflagged windows that happen to span the output.
        var l = _monLogical(mon)
        var isFull = Math.abs(win.ax - mon.x) <= 1 && Math.abs(win.ay - mon.y) <= 1 &&
             Math.abs(win.sw - l.w) <= 1 && Math.abs(win.sh - l.h) <= 1
        if (isFull)
            return { x: box.x + offX, y: box.y + offY, w: R.w * k, h: R.h * k }
        wx = (win.ax - mon.x) - R.x; wy = (win.ay - mon.y) - R.y; sw = win.sw; sh = win.sh
    }
    var cx = Math.max(0, wx), cy = Math.max(0, wy)
    var cR = Math.min(wx + sw, R.w), cB = Math.min(wy + sh, R.h)
    var cw = cR - cx, ch = cB - cy
    if (cw <= 0 || ch <= 0) return null
    var tx = box.x + offX + cx * k, ty = box.y + offY + cy * k
    var tw = Math.max(P.minTileW, cw * k), th = Math.max(P.minTileH, ch * k)
    tx = Math.max(box.x + P.cellInset, Math.min(tx, box.x + box.w - P.cellInset - tw))
    ty = Math.max(box.y + P.cellInset, Math.min(ty, box.y + box.h - P.cellInset - th))
    return { x: tx, y: ty, w: tw, h: th }
}

// Hyprland's `fullscreen` client field is 0 none / 1 maximized / 2 fullscreen; older callers
// passed a boolean, which means fullscreen.
function fullscreenMode(win) {
    var m = win.fullscreen === true ? 2 : (win.fullscreen | 0)
    return Math.max(0, Math.min(2, m))
}

function _uniqSorted(a) {
    a = a.slice().sort(function (p, q) { return p - q })
    var out = []
    for (var i = 0; i < a.length; i++) if (!out.length || a[i] - out[out.length - 1] > 0.5) out.push(a[i])
    return out
}

// Where a fullscreen window sits in the tiled layout, recovered from what the OTHER tiled
// windows leave uncovered: dwindle slots partition the usable rect, and fullscreen hides the
// others without moving them, so the hole is the slot the window returns to. `R` is the usable
// rect and `others` rects in the same coordinates (floating/fullscreen windows excluded by the
// caller). Grid R on every edge; seed on the uncovered cell with the largest MINIMUM side (a gap
// strip only wins that if a gap is as thick as the slot's thinnest cell, which no sane
// configuration reaches, so no gap configuration is needed); grow while whole neighbouring
// columns/rows are uncovered (absorbs adjacent gap padding, never crosses a neighbour); trim the
// outer band thinner than P.slotGapTolerance on each side (cumulative, so thin projected-edge
// cells just inside the slot are not peeled one after another; at most tol px of a slot edge can
// be lost). Null when nothing usable is uncovered.
function recoverSlot(R, others, P) {
    var tol = P.slotGapTolerance || 24
    var xs = [R.x, R.x + R.w], ys = [R.y, R.y + R.h], rects = []
    for (var i = 0; i < others.length; i++) {
        var o = others[i]
        var x0 = Math.max(R.x, o.x), y0 = Math.max(R.y, o.y)
        var x1 = Math.min(R.x + R.w, o.x + o.w), y1 = Math.min(R.y + R.h, o.y + o.h)
        if (x1 <= x0 || y1 <= y0) continue
        rects.push({ x0: x0, y0: y0, x1: x1, y1: y1 })
        xs.push(x0, x1); ys.push(y0, y1)
    }
    xs = _uniqSorted(xs); ys = _uniqSorted(ys)
    var nx = xs.length - 1, ny = ys.length - 1
    var cov = []                                   // cov[ci][cj]: cell centre inside some rect
    var ci, cj
    for (ci = 0; ci < nx; ci++) {
        cov.push([])
        for (cj = 0; cj < ny; cj++) {
            var cx = (xs[ci] + xs[ci + 1]) / 2, cy = (ys[cj] + ys[cj + 1]) / 2, hit = false
            for (var k = 0; k < rects.length && !hit; k++)
                hit = cx > rects[k].x0 && cx < rects[k].x1 && cy > rects[k].y0 && cy < rects[k].y1
            cov[ci].push(hit)
        }
    }
    var si = -1, sj = -1, best = 0
    for (ci = 0; ci < nx; ci++) for (cj = 0; cj < ny; cj++) {
        if (cov[ci][cj]) continue
        var m = Math.min(xs[ci + 1] - xs[ci], ys[cj + 1] - ys[cj])
        if (m > best) { best = m; si = ci; sj = cj }
    }
    if (si < 0) return null
    function colFree(c, ja, jb) { for (var j = ja; j <= jb; j++) if (cov[c][j]) return false; return true }
    function rowFree(r, ia, ib) { for (var i2 = ia; i2 <= ib; i2++) if (cov[i2][r]) return false; return true }
    var i0 = si, i1 = si, j0 = sj, j1 = sj, grew = true
    while (grew) {
        grew = false
        if (i0 > 0 && colFree(i0 - 1, j0, j1)) { i0--; grew = true }
        if (i1 < nx - 1 && colFree(i1 + 1, j0, j1)) { i1++; grew = true }
        if (j0 > 0 && rowFree(j0 - 1, i0, i1)) { j0--; grew = true }
        if (j1 < ny - 1 && rowFree(j1 + 1, i0, i1)) { j1++; grew = true }
    }
    var tx0 = xs[i0];     while (i0 < i1 && xs[i0 + 1] - tx0 < tol) i0++
    var tx1 = xs[i1 + 1]; while (i1 > i0 && tx1 - xs[i1] < tol) i1--
    var ty0 = ys[j0];     while (j0 < j1 && ys[j0 + 1] - ty0 < tol) j0++
    var ty1 = ys[j1 + 1]; while (j1 > j0 && ty1 - ys[j1] < tol) j1--
    var slot = { x: xs[i0], y: ys[j0], w: xs[i1 + 1] - xs[i0], h: ys[j1 + 1] - ys[j0] }
    return Math.min(slot.w, slot.h) <= tol ? null : slot
}

// Pad `workspaces` so ids 1..count all appear, so the 1–0 keys always have a target even when
// Hyprland has not created a workspace (a persistent rule whose monitor is absent, or no rule
// at all). A synthesized well is placed next to its numeric neighbours — on the monitor of the
// nearest lower real workspace, else the nearest higher one — so where it is drawn depends
// only on the real workspace→monitor mapping, never on focus (the layout must not move when
// the overview opens from the other screen). Only when no real workspace exists at all does it
// fall back to the focused monitor. Hyprland decides the actual monitor when the workspace is
// created on jump or drop; the next rebuild then shows the truth. Synthesized entries carry
// `synthetic: true` so ordering can ignore them. `count` <= 0 disables padding. Returns a new
// array; input untouched.
function padWorkspaces(workspaces, count, focusedMonitorName) {
    var out = workspaces.slice()
    if (!(count > 0)) return out
    var realIds = []
    var monById = {}
    for (var i = 0; i < workspaces.length; i++) {
        var ws = workspaces[i]; if (ws.id < 0) continue
        monById[ws.id] = ws.monitorName; realIds.push(ws.id)
    }
    realIds.sort(function (a, b) { return a - b })
    function hostFor(id) {
        var lower = -1, higher = -1
        for (var k = 0; k < realIds.length; k++) {
            if (realIds[k] < id) lower = realIds[k]
            else if (higher < 0) { higher = realIds[k]; break }
        }
        if (lower >= 0) return monById[lower]
        if (higher >= 0) return monById[higher]
        return focusedMonitorName
    }
    for (var id = 1; id <= count; id++) {
        if (id in monById) continue
        var host = hostFor(id); if (!host) continue
        out.push({ id: id, monitorName: host, focused: false, occupied: false, windowCount: 0,
                   synthetic: true })
    }
    return out
}

function layout(input) {
    var P = input.params
    var monByName = _index(input.monitors, "name")
    var order = _orderedMonitorNames(input.monitors, input.workspaces)

    // With more than one monitor group each group gets a chip band (headerH) and an inset
    // (groupInset) so a backdrop can be drawn around it inside the canvas; a single group
    // gets neither, keeping the one-monitor picture flush.
    var multi = order.length > 1
    var headerH = multi ? P.headerH : 0
    var inset = multi ? (P.groupInset || 0) : 0

    // adaptive cell size — maxCols is a CAP, not a floor
    var gap = P.cellSpacing
    // safe default when availW is missing/invalid: maxCols cells at minCellW with the
    // (maxCols-1) gaps between them included, so cols resolves to maxCols and cw clamps
    // to exactly minCellW — finite, valid geometry instead of NaN.
    var availW = (typeof input.availW === "number" && input.availW > 0)
        ? input.availW - 2 * inset : (P.maxCols * P.minCellW + (P.maxCols - 1) * gap)
    var cols = Math.max(1, Math.min(P.maxCols,
        Math.floor((availW + gap) / (P.minCellW + gap))))
    var cw = Math.max(P.minCellW, Math.min(P.maxCellW,
        Math.floor((availW - (cols - 1) * gap) / cols)))
    // Cell height follows each group's own monitor (see the group loop), so the picture is
    // identical whichever screen has focus; `cell.h` reports the focused monitor's for reference.
    function cellHeightFor(mon) {
        var aspect = mon ? _monLogical(mon).w / _monLogical(mon).h : (16 / 10)
        return Math.round(cw / aspect)
    }
    var ch = cellHeightFor(monByName[input.focusedMonitorName])

    var wsByMon = {}
    for (var i = 0; i < input.workspaces.length; i++) {
        var ws = input.workspaces[i]; if (ws.id < 0) continue
        ;(wsByMon[ws.monitorName] = wsByMon[ws.monitorName] || []).push(ws)
    }
    for (var mn in wsByMon) wsByMon[mn].sort(function (a, b) { return a.id - b.id })

    // Groups carry their full bounds (x, y, w, h) — the inset, chip band and rows — so the
    // view can draw a backdrop behind the focused monitor's group.
    var boxes = [], boxByWs = {}, groups = [], y = 0, canvasW = 0
    for (var r = 0; r < order.length; r++) {
        var name = order[r], wss = wsByMon[name] || []
        if (!wss.length) continue
        var focusedGroup = name === input.focusedMonitorName
        var gch = cellHeightFor(monByName[name])
        var group = { monitorName: name, special: "", x: 0, y: y, w: 0, h: 0, inset: inset, headerH: headerH,
                      focused: focusedGroup }
        groups.push(group)
        y += inset + headerH
        var groupW = 0
        for (var s = 0; s < wss.length; s += cols) {
            var chunk = wss.slice(s, s + cols)
            for (var c = 0; c < chunk.length; c++) {
                var box = { workspaceId: chunk[c].id, monitorName: name, monFocused: focusedGroup,
                            special: "", x: inset + c * (cw + gap), y: y, w: cw, h: gch,
                            focused: !!chunk[c].focused, occupied: !!chunk[c].occupied,
                            // How many windows the workspace holds, not merely whether it holds
                            // any: Close all needs more than one (see workspaceMenuRows).
                            windowCount: chunk[c].windowCount | 0,
                            armed: !!chunk[c].armed, placeholder: !!chunk[c].placeholder,
                            // Menu eligibility (docs/specs/2026-09-15-actions-design.md): Move and
                            // Swap need a workspace the compositor actually has, and Swap needs it
                            // to be the one its monitor is showing.
                            synthetic: !!chunk[c].synthetic, active: !!chunk[c].active }
                boxes.push(box); boxByWs[box.workspaceId] = box
            }
            var rowW = chunk.length * cw + (chunk.length - 1) * gap
            if (rowW > groupW) groupW = rowW
            y += gch
            if (s + cols < wss.length) y += P.rowSpacing        // between sub-rows of one group
        }
        y += inset
        group.w = groupW + 2 * inset; group.h = y - group.y
        if (group.w > canvasW) canvasW = group.w
        if (r < order.length - 1) y += P.rowSpacing             // between monitor groups
    }

    // Trailing scratchpad group (a special workspace shown on demand): its own header band —
    // always, even when the monitor groups have none — and one cell, below every monitor group.
    // The monitor loop above skips negative ids, so the scratchpad never lands in a monitor row.
    // Exactly one scratchpad group can exist, so this loop stops at the first match: a special
    // record with a non-negative id (never legitimately the scratchpad) must not produce a
    // second box for the same id.
    for (var si = 0; si < input.workspaces.length; si++) {
        var sws = input.workspaces[si]; if (!sws.special || !isScratchpad(sws.id)) continue
        if (groups.length) y += P.rowSpacing
        var sgroup = { monitorName: sws.monitorName, special: sws.special, x: 0, y: y, w: 0, h: 0,
                       inset: inset, headerH: P.headerH, focused: false }
        groups.push(sgroup)
        y += inset + P.headerH
        // The row spans the canvas and the single cell sits centred in it (a left-aligned lone
        // cell under a full-width grid read as misplaced in use).
        var rowW = Math.max(canvasW, cw + 2 * inset)
        var sbox = { workspaceId: sws.id, monitorName: sws.monitorName, monFocused: false,
                     special: sws.special, x: inset + Math.round((rowW - 2 * inset - cw) / 2), y: y, w: cw,
                     h: cellHeightFor(monByName[sws.monitorName]),
                     focused: !!sws.focused, occupied: !!sws.occupied,
                     windowCount: sws.windowCount | 0,
                     armed: !!sws.armed, placeholder: !!sws.placeholder,
                     // A special workspace is never a monitor's `activeWorkspace` (it is reported
                     // separately as `specialWorkspace`), and it is never a pad slot.
                     synthetic: false, active: false }
        boxes.push(sbox); boxByWs[sbox.workspaceId] = sbox
        y += sbox.h + inset
        sgroup.w = rowW; sgroup.h = y - sgroup.y
        if (sgroup.w > canvasW) canvasW = sgroup.w
        break
    }

    // Tiled windows that are not fullscreen or maximized, per workspace, in usable-rect-local
    // coords: what a fullscreen window's slot is recovered from (see recoverSlot).
    var tiledByWs = {}
    for (var pi = 0; pi < input.windows.length; pi++) {
        var pw = input.windows[pi]
        if (pw.floating || fullscreenMode(pw)) continue
        var pbox = boxByWs[pw.workspaceId], pmon = pbox ? monByName[pbox.monitorName] : null
        if (!pmon) continue
        var pR = _usableRect(pmon)
        ;(tiledByWs[pw.workspaceId] = tiledByWs[pw.workspaceId] || []).push(
            { x: (pw.ax - pmon.x) - pR.x, y: (pw.ay - pmon.y) - pR.y, w: pw.sw, h: pw.sh })
    }
    var tiles = []
    for (var wi = 0; wi < input.windows.length; wi++) {
        var win = input.windows[wi], wbox = boxByWs[win.workspaceId]; if (!wbox) continue
        if (wbox.placeholder) continue     // lock placeholder: no tile, no capture (spec: Rendering)
        var wmon = monByName[wbox.monitorName]; if (!wmon) continue
        var mode = fullscreenMode(win), layer = win.floating ? 2 : 1, slot = null
        if (mode) {
            var UR = _usableRect(wmon), whole = { x: 0, y: 0, w: UR.w, h: UR.h }
            if (win.floating) {
                slot = { x: UR.w * 0.2, y: UR.h * 0.2, w: UR.w * 0.6, h: UR.h * 0.6 }   // no slot exists
            } else {
                var others = tiledByWs[win.workspaceId] || []
                slot = others.length ? recoverSlot(whole, others, P) : whole
                if (!slot) { slot = whole; layer = 0 }                              // ambiguous → backdrop
            }
        }
        var t = _tileRect(win, wmon, wbox, P, slot)
        if (t) {
            t.address = win.address; t.workspaceId = win.workspaceId
            t.layer = layer; t.fullscreen = mode
            tiles.push(t)
        }
    }
    return { canvasSize: { w: canvasW, h: y }, boxes: boxes, tiles: tiles,
             groups: groups, cell: { w: cw, h: ch, cols: cols } }
}

// Reverse of _tileRect's placement: map a dragged tile's canvas top-left back to the window's
// real global logical top-left, so a floating window can be repositioned to where it was
// dropped inside its own workspace cell. Tiled placement re-tiles at a cursor point instead
// (see tiledInsertLua).
function dropToWindowPos(tileX, tileY, box, mon, P, win) {
    var R = _usableRect(mon)
    var mmW = box.w - 2 * P.cellInset, mmH = box.h - 2 * P.cellInset
    var k = Math.min(mmW / R.w, mmH / R.h)
    var offX = P.cellInset + (mmW - R.w * k) / 2
    var offY = P.cellInset + (mmH - R.h * k) / 2
    var rx = (tileX - box.x - offX) / k
    var ry = (tileY - box.y - offY) / k
    // Include the window's extent so a drop near the edge stays fully visible.
    // Without an extent retain the original point-clamping API for callers.
    var l = _monLogical(mon)
    var minX = mon.x + (win ? R.x : 0), minY = mon.y + (win ? R.y : 0)
    var maxX = win ? Math.max(minX, mon.x + R.x + R.w - win.sw) : mon.x + l.w
    var maxY = win ? Math.max(minY, mon.y + R.y + R.h - win.sh) : mon.y + l.h
    var x = Math.round(Math.max(minX, Math.min(mon.x + R.x + rx, maxX)))
    var y = Math.round(Math.max(minY, Math.min(mon.y + R.y + ry, maxY)))
    // The typed dispatcher reserves -1 for "preserve this axis".
    return { x: x === -1 ? -2 : x, y: y === -1 ? -2 : y }
}

// ---- tiled drop: mirror Hyprland's native drag-and-drop placement ----
//
// A native tiled drop is a re-tile at the cursor: dwindle inserts the window as a new split of
// the node under (or closest to) the cursor, choosing the side by dwindle's smart-split rule —
// the slope of (cursor - node centre) against the node's aspect ratio picks left/right for
// shallow angles and top/bottom for steep ones (DwindleAlgorithm::addTarget, 0.56).

// Side of `rect` a point lands on under that rule: "left" | "right" | "top" | "bottom".
// Division by zero follows IEEE like the C++ (±Infinity → vertical; NaN at the exact centre →
// "top"), so the preview agrees with what the compositor will do.
function dropSide(rect, px, py) {
    var dx = px - (rect.x + rect.w / 2), dy = py - (rect.y + rect.h / 2)
    if (Math.abs(dy / dx) < rect.h / rect.w) return dx > 0 ? "right" : "left"
    return dy > 0 ? "bottom" : "top"
}

// Squared distance from a point to a rect (0 inside) — used to pick the closest tiled tile
// when a drop lands in a gap, matching dwindle's getClosestNode fallback.
function rectDistanceSq(rect, px, py) {
    var dx = Math.max(rect.x - px, 0, px - (rect.x + rect.w))
    var dy = Math.max(rect.y - py, 0, py - (rect.y + rect.h))
    return dx * dx + dy * dy
}

// Where a tiled drop centred at (cx, cy) inside a workspace box would insert, shared by the
// drag preview and the release so they can never disagree. `candidates` are the canvas rects
// ({x, y, w, h, address}) of the tiled windows that can anchor the insert, in stacking order
// (later wins a tie); `own` is the dragged tile's own rect when the drop is inside its own
// workspace (`sameWorkspace`), or null. Returns { anchor, side } — anchor "" when the target
// workspace has nothing tiled and the window simply fills it — or null when nothing should
// happen: a drop back onto the window's own slot, or a lone tiled window dropped inside its
// own workspace.
function tiledDropPlan(candidates, sameWorkspace, own, cx, cy) {
    if (own && cx >= own.x && cx <= own.x + own.w && cy >= own.y && cy <= own.y + own.h) return null
    var best = null, bestD = Infinity
    for (var i = candidates.length - 1; i >= 0; i--) {
        var d = rectDistanceSq(candidates[i], cx, cy)
        if (d < bestD) { bestD = d; best = candidates[i] }
    }
    if (!best) return sameWorkspace ? null : { anchor: "", side: "" }
    return { anchor: best.address, side: dropSide(best, cx, cy) }
}

// Lua statement defining `run(d)`: dispatch `d` and raise when the compositor reports failure.
// hl.dispatch never raises (Hyprland 0.56.2, LuaBindingsToplevel.cpp hlDispatch): a failed
// dispatcher — even one that hit a Lua error internally — comes back as { ok = false,
// error = "..." }. Raising inside our pcall turns that into the failure path: the sequence
// stops, the guarded cleanup runs, and reportLua names the failed step.
function dispatchGuardLua() {
    return 'local function run(d) local r = hl.dispatch(d) if r and r.ok == false then error(tostring(r.error), 0) end return r end'
}

// Lua statements that report a failure captured as `ok, err` (from pcall) for the operation
// `what`: to the compositor log (Hyprland rebinds `print` to its log with a [Lua] prefix) and
// as an on-screen notification (guarded: hl.notification is missing on older Hyprland). Errors
// inside our own pcall are otherwise invisible — the compositor only logs uncaught ones.
// Returns newline-separated statements; the outermost chunk builder must flatten to one line.
function reportLua(what) {
    return (
        'if not ok then\n' +
        '  local msg = "omascape: ' + what + ' failed: " .. tostring(err)\n' +
        '  print(msg)\n' +
        '  pcall(function() hl.notification.create({ text = msg, duration = 4000, icon = "error" }) end)\n' +
        'end'
    )
}

// One atomic Lua chunk (Hyprland Lua-config mode evaluates `dispatch` payloads as
// `hl.dispatch(<payload>)`, and accepts a function) that replays a native tiled drop:
//   strip the target workspace's fullscreen window (and the dragged window's own fullscreen,
//   if any) so every window is measured in its tiled slot → float the window (detaches it from
//   the tree) → move it silently to the target workspace if needed → warp the cursor onto the
//   anchor's `side` edge → un-float (re-tiles at the cursor) → re-apply the fullscreen modes
//   stripped above → restore focus (only if the dispatcher moved it) and the cursor.
// Detaching the window re-lays out the target workspace, so the cursor point is computed from
// the anchor's geometry AFTER the float, not from the overview's pre-drop layout: the edge
// midpoint of the requested side (inset so the hit test resolves to the anchor), which under
// dwindle's smart-split slope rule always picks that side. `placement` is { anchor, side, x, y }:
// anchor is the window address to split (or "" when the workspace has nothing tiled) and x/y
// the global fallback point used when there is no anchor to measure.
// While it runs, smart_split is forced on so the side follows the cursor regardless of the
// user's force_split, and use_active_for_splits is turned off on the focused monitor's active
// workspace so the anchor is the window under the cursor rather than the focused window.
// Hidden workspaces keep use_active on: there dwindle already falls back to the closest node
// by geometry. Everything runs inside the compositor before the next frame, so nothing flashes.
// The risky steps run in a pcall; the un-float, both fullscreen re-applies and the config
// restore are separate guarded steps that re-read state, so a throw never leaves the window
// floating, and the error is reported (log + notification). Layouts other than dwindle get a
// plain silent move: the cursor-based insert is dwindle behaviour.
function tiledInsertLua(addr, targetWs, placement) {
    var ws = String(parseInt(targetWs, 10))
    var gx = Math.round(placement.x), gy = Math.round(placement.y)
    var side = { left: 1, right: 1, top: 1, bottom: 1 }[placement.side] ? placement.side : ""
    var anchorSel = placement.anchor ? '"address:' + placement.anchor + '"' : 'nil'
    // Built readable, then flattened to one line: the IPC request is a single line.
    return (
        'function()\n' +
        '  local sel = "address:' + addr + '"\n' +
        '  local w = hl.get_window(sel)\n' +
        '  if not w or w.floating then return end\n' +
        '  local anchorSel = ' + anchorSel + '\n' +
        '  local prevW = hl.get_active_window()\n' +
        '  local cur = hl.get_cursor_pos()\n' +
        '  ' + dispatchGuardLua() + '\n' +
        '  local same = w.workspace ~= nil and w.workspace.id == ' + ws + '\n' +
        '  local layout = hl.get_config("general.layout")\n' +
        '  if layout ~= nil and layout ~= "dwindle" then\n' +
        '    local ok, err = pcall(function()\n' +
        '      if not same then run(hl.dsp.window.move({ workspace = "' + ws + '", follow = false, window = sel })) end\n' +
        '    end)\n' +
        '    ' + reportLua('tiled insert') + '\n' +
        '    ' + restoreFocusLua('prevW', 'cur') + '\n' +
        '    return\n' +
        '  end\n' +
        '  local smart = hl.get_config("dwindle.smart_split")\n' +
        '  local useActive = hl.get_config("dwindle.use_active_for_splits")\n' +
        '  local aws = hl.get_active_workspace()\n' +
        '  local onActive = aws ~= nil and aws.id == ' + ws + '\n' +
        // Fullscreen bookkeeping. The target workspace's fullscreen window is stripped so every
        // window there (the anchor included) is measured in its tiled slot, and re-applied
        // afterwards; the dragged window's own mode is kept only for a same-workspace re-tile.
        '  local tws = hl.get_workspace("' + ws + '")\n' +
        '  local fsWin = tws and tws.fullscreen_window or nil\n' +
        '  local fa = fsWin and tostring(fsWin.address or "") or ""\n' +
        '  if fa ~= "" and fa:sub(1, 2) ~= "0x" then fa = "0x" .. fa end\n' +
        '  local fsSel = fa ~= "" and ("address:" .. fa) or nil\n' +
        '  local fsMode = fsWin and tws.fullscreen_mode or 0\n' +
        '  local ownMode = same and w.fullscreen or 0\n' +
        '  hl.config({ dwindle = { smart_split = true, use_active_for_splits = not onActive } })\n' +
        '  local ok, err = pcall(function()\n' +
        '    if fsSel then ' + fullscreenBodyLua('fsSel', '0') + ' end\n' +
        '    ' + fullscreenBodyLua('sel', '0') + '\n' +
        '    run(hl.dsp.window.float({ window = sel, action = "toggle" }))\n' +
        '    if not same then\n' +
        '      run(hl.dsp.window.move({ workspace = "' + ws + '", follow = false, window = sel }))\n' +
        '    end\n' +
        '    local x, y = ' + gx + ', ' + gy + '\n' +
        '    local a = anchorSel and hl.get_window(anchorSel) or nil\n' +
        '    if a and a.at and a.size then\n' +
        '      local inset = 2\n' +
        '      x, y = a.at.x + a.size.x / 2, a.at.y + a.size.y / 2\n' +
        '      if "' + side + '" == "left" then x = a.at.x + inset\n' +
        '      elseif "' + side + '" == "right" then x = a.at.x + a.size.x - 1 - inset\n' +
        '      elseif "' + side + '" == "top" then y = a.at.y + inset\n' +
        '      elseif "' + side + '" == "bottom" then y = a.at.y + a.size.y - 1 - inset end\n' +
        '    end\n' +
        '    run(hl.dsp.cursor.move({ x = math.floor(x + 0.5), y = math.floor(y + 0.5) }))\n' +
        '  end)\n' +
        // Cleanup. On success the un-float IS the re-tile (at the cursor). Each step re-reads
        // state and is guarded on its own, so a failure above — or in an earlier cleanup step —
        // never leaves the window floating, the workspace un-fullscreened, or the config changed.
        // The window was tiled on entry, so any floating state here is ours to undo. A failing
        // cleanup step folds into ok/err so it is reported too (the first error wins).
        '  local function step(f) local g, e = pcall(f) if not g then ok, err = false, err or e end end\n' +
        '  step(function() local fw = hl.get_window(sel); if fw and fw.floating then run(hl.dsp.window.float({ window = sel, action = "toggle" })) end end)\n' +
        '  step(function() if fsSel and fsSel ~= sel then ' + fullscreenBodyLua('fsSel', 'fsMode') + ' end end)\n' +
        '  step(function() if ownMode ~= 0 then ' + fullscreenBodyLua('sel', 'ownMode') + ' end end)\n' +
        '  hl.config({ dwindle = { smart_split = smart, use_active_for_splits = useActive } })\n' +
        '  ' + reportLua('tiled insert') + '\n' +
        '  ' + restoreFocusLua('prevW', 'cur') + '\n' +
        'end'
    ).replace(/\n\s*/g, ' ')
}

// ---- fullscreen ----
//
// Lua statements that leave the window selected by the Lua expression `sel` (e.g. '"address:0x1"'
// or a local name) in fullscreen mode `modeExpr` (a Lua expression: 0 off, 1 maximized,
// 2 fullscreen). Re-reads the window and toggles only when its mode differs, so the statements
// are idempotent and a stale request is harmless. Hyprland's toggle turns fullscreen OFF when
// asked for the mode the window already has and SWITCHES modes otherwise, so when turning off the
// name is taken from the window's current mode.
// Returns newline-separated statements; the outermost chunk builder must flatten to one line.
function fullscreenBodyLua(sel, modeExpr) {
    return (
        'do local fw, fm = hl.get_window(' + sel + '), ' + modeExpr + '\n' +
        '  if fw and fm and fw.fullscreen ~= fm then\n' +
        '    local name = (fm == 1 or (fm == 0 and fw.fullscreen == 1)) and "maximized" or "fullscreen"\n' +
        '    run(hl.dsp.window.fullscreen({ window = ' + sel + ', mode = name, action = "toggle" }))\n' +
        '  end\n' +
        'end'
    )
}

// Lua statements that move the cursor back to `curExpr` (an HL.Vec2 or nil). Split out of
// restoreFocusLua because the workspace chunks restore the cursor but deliberately NOT focus.
function restoreCursorLua(curExpr) {
    return 'if ' + curExpr + ' then hl.dispatch(hl.dsp.cursor.move({ x = ' + curExpr + '.x, y = ' + curExpr + '.y })) end'
}

// Lua statements that re-focus the window `prevExpr` (an HL.Window or nil, read before the
// change) when the active window is no longer it, then move the cursor back to `curExpr`
// (an HL.Vec2 or nil). The probe (tests/integration/probe-fullscreen.sh) showed the fullscreen
// dispatcher can drop focus to nil, and focusing warps the cursor, so every chunk that touches
// fullscreen ends with this. Addresses from Lua may lack the 0x prefix hyprctl uses.
// Returns newline-separated statements; the outermost chunk builder must flatten to one line.
function restoreFocusLua(prevExpr, curExpr) {
    return (
        'do local nowW = hl.get_active_window()\n' +
        '  if ' + prevExpr + ' and (not nowW or nowW.address ~= ' + prevExpr + '.address) then\n' +
        '    local a = tostring(' + prevExpr + '.address)\n' +
        '    if a:sub(1, 2) ~= "0x" then a = "0x" .. a end\n' +
        '    hl.dispatch(hl.dsp.focus({ window = "address:" .. a }))\n' +
        '  end\n' +
        '  ' + restoreCursorLua(curExpr) + '\n' +
        'end'
    )
}

// One atomic chunk that puts `addr` in floating state `floating` (a boolean). An explicit state,
// never a toggle: a menu row rendered from a snapshot the compositor has since changed must be a
// no-op, not the opposite of its label. Hyprland maps action "on"/"off" to ENABLE/DISABLE
// (parseToggleStr) and Actions::floatWindow returns early when the state already matches, so the
// guard here is belt and braces — but it also keeps the dispatch count assertable in tests.
// Focus and cursor are restored: the float raises the window and relayouts its workspace, which
// moves focus (verified in Actions::floatWindow, 0.56.2). The dispatch itself runs inside the
// inner pcall, but restoreFocusLua is called OUTSIDE it (after `reportLua`), so focus and the
// cursor still land back where they were even if the dispatcher throws — parity with
// tiledInsertLua's pcall-wrapped re-tile step and the old unfullscreenLua this replaces.
function setFloatLua(addr, floating) {
    var want = floating ? 'true' : 'false'
    return (
        'function()\n' +
        '  local sel = "address:' + addr + '"\n' +
        '  local prevW, cur = hl.get_active_window(), hl.get_cursor_pos()\n' +
        '  ' + dispatchGuardLua() + '\n' +
        '  local ok, err = pcall(function()\n' +
        '    local w = hl.get_window(sel)\n' +
        '    if not w then error("window is gone", 0) end\n' +
        '    if (w.floating == true) ~= ' + want + ' then\n' +
        '      run(hl.dsp.window.float({ window = sel, action = "' + (floating ? 'on' : 'off') + '" }))\n' +
        '    end\n' +
        '  end)\n' +
        '  ' + reportLua('float') + '\n' +
        '  ' + restoreFocusLua('prevW', 'cur') + '\n' +
        'end'
    ).replace(/\n\s*/g, ' ')
}

// One atomic chunk that leaves `addr` in fullscreen mode `mode` (0 off, 1 maximized, 2 fullscreen)
// via the idempotent fullscreenBodyLua. Focus is restored because fullscreening a window on the
// ACTIVE workspace leaves Hyprland 0.56.2 with no active window (probe-fullscreen.sh). The toggle
// dispatch runs inside the inner pcall, but restoreFocusLua runs OUTSIDE it, so focus and the
// cursor still land back where they were even if the dispatcher throws — parity with
// tiledInsertLua's pcall-wrapped re-tile step and the old unfullscreenLua this replaces.
function setFullscreenLua(addr, mode) {
    var m = Math.max(0, Math.min(2, mode | 0))
    return (
        'function()\n' +
        '  local prevW, cur = hl.get_active_window(), hl.get_cursor_pos()\n' +
        '  ' + dispatchGuardLua() + '\n' +
        '  local ok, err = pcall(function()\n' +
        fullscreenBodyLua('"address:' + addr + '"', String(m)) + '\n' +
        '  end)\n' +
        reportLua(m === 0 ? 'un-fullscreen' : 'fullscreen') + '\n' +
        restoreFocusLua('prevW', 'cur') + '\n' +
        'end'
    ).replace(/\n\s*/g, ' ')
}

// The tile badge's un-fullscreen is the mode-0 case. Kept as its own name because the badge, the
// menu and the existing chunk test all refer to it.
function unfullscreenLua(addr) { return setFullscreenLua(addr, 0) }

// Raw Hyprland events after which the compositor may have moved keyboard focus to a WINDOW,
// which silently takes it away from this overlay's on-demand layer surface while the picker is
// still up. Each one is a place Hyprland calls fullWindowFocus/refocus:
//   closewindow      — the closed window was the focused one (Window.cpp, "refocus on a new window
//                      if needed"; it logs "ignoring a refocus" otherwise, hence the intermittency)
//   workspacev2      — a workspace switch focuses that workspace's last window
//                      (WorkspacePlacementController.cpp)
//   activespecialv2  — opening a special workspace focuses a window on it
//   focusedmonv2     — monitor focus moved, taking window focus with it
// The overlay held focus unconditionally until it became OnDemand (so the other-monitor catcher
// could receive presses); an exclusive layer could not lose it this way. The answer is not to go
// back — it is to re-grab (see regrabFocusLua), which the warp does without disturbing pointer
// routing. Deliberately NOT activewindowv2: focusing the layer can itself emit an activewindow
// change, and regrabbing on that would chase its own tail.
function focusStealingEvent(name) {
    return name === "closewindow" || name === "workspacev2" ||
           name === "activespecialv2" || name === "focusedmonv2"
}

// One atomic chunk that re-grants keyboard focus to this overlay's layer surface, by warping the
// cursor to where it already is.
//
// Why this is needed at all: when a window really closes, Hyprland refocuses another one if the
// closed window was the focused one (Window.cpp, "refocus on a new window if needed" — it logs
// "ignoring a refocus" otherwise, which is why the symptom is intermittent). Focusing a *window*
// takes keyboard focus away from an on-demand layer surface, which is what this overlay is, so the
// overview silently stops receiving keys — mid-Ctrl+W, the next keystroke lands in the window
// Hyprland just picked.
//
// Why a warp fixes it: mouseMoveUnified re-grants keyboard focus to the layer under the pointer
// whenever its interactivity is not `none` (InputManager.cpp). Warping to the SAME position is
// deliberate and sufficient — Actions::moveCursor calls warpTo(pos, true), and Hyprland's own
// simulateMouseMovement has to offset by a pixel specifically to AVOID counting as a refocus, so an
// unoffset warp does count. Every other action chunk already ends with a cursor restore and so
// never lost focus; close was the only one that did not, and the only one that did.
function regrabFocusLua() {
    return (
        'function()\n' +
        '  local cur = hl.get_cursor_pos()\n' +
        '  ' + restoreCursorLua('cur') + '\n' +
        'end'
    ).replace(/\n\s*/g, ' ')
}

// One atomic chunk that closes every window on workspace `wsId`. The list is read INSIDE the
// compositor (HL.Workspace:get_windows() — a one-based table of HL.Window, verified in
// LuaWorkspace.cpp and by tests/integration/actions-probe.sh), not passed in, so windows the
// overview never laid out (a null _tileRect, or a workspace it is not showing) are closed too.
// Each close is guarded on its own: one window refusing must not stop the rest, and the failures
// are reported together in one notification rather than one per window.
function closeAllLua(wsId) {
    var ws = wsSelector(wsId)
    return (
        'function()\n' +
        '  ' + dispatchGuardLua() + '\n' +
        '  local failed = {}\n' +
        '  local ok, err = pcall(function()\n' +
        '    local w = hl.get_workspace("' + ws + '")\n' +
        '    if not w or not w.get_windows then error("workspace ' + ws + ' not found", 0) end\n' +
        '    for _, win in ipairs(w:get_windows() or {}) do\n' +
        '      local a = tostring(win and win.address or "")\n' +
        '      if a ~= "" then\n' +
        '        if a:sub(1, 2) ~= "0x" then a = "0x" .. a end\n' +
        '        local s, e = pcall(function() run(hl.dsp.window.close({ window = "address:" .. a })) end)\n' +
        '        if not s then failed[#failed + 1] = a .. ": " .. tostring(e) end\n' +
        '      end\n' +
        '    end\n' +
        '  end)\n' +
        '  if ok and #failed > 0 then ok, err = false, table.concat(failed, "; ") end\n' +
        '  ' + reportLua('close all') + '\n' +
        'end'
    ).replace(/\n\s*/g, ' ')
}

// One atomic chunk that moves the floating window `addr` to workspace `targetWs` (skipped when
// it is already there) and then to the exact global position `pos` — in that order, because a
// workspace transfer relocates a floating window (especially across monitors), so positioning
// must come after it. Both happen inside the compositor before the next frame, so nothing in
// the overlay has to survive to finish the move: an unloaded overlay loses only its optimistic
// tile, never the operation. Tiled windows return early (they take the tiled-insert chunk).
// The position payload keeps the exact-coordinate string form the old two-phase move used.
function floatingMoveLua(addr, targetWs, pos) {
    var ws = wsSelector(targetWs)
    var x = Math.round(pos.x), y = Math.round(pos.y)
    var same = isScratchpad(targetWs)
        ? 'w.workspace ~= nil and w.workspace.name == "' + SCRATCHPAD_NAME + '"'
        : 'w.workspace ~= nil and w.workspace.id == ' + ws
    return (
        'function()\n' +
        '  local sel = "address:' + addr + '"\n' +
        '  local w = hl.get_window(sel)\n' +
        '  if not w or not w.floating then return end\n' +
        '  local prevW, cur = hl.get_active_window(), hl.get_cursor_pos()\n' +
        '  ' + dispatchGuardLua() + '\n' +
        '  local same = ' + same + '\n' +
        '  local ok, err = pcall(function()\n' +
        '    if not same then run(hl.dsp.window.move({ workspace = "' + ws + '", follow = false, window = sel })) end\n' +
        '    run(hl.dsp.window.move({ x = "' + x + '", y = "' + y + '", window = sel }))\n' +
        '  end)\n' +
        '  ' + reportLua('floating move') + '\n' +
        '  ' + restoreFocusLua('prevW', 'cur') + '\n' +
        'end'
    ).replace(/\n\s*/g, ' ')
}

// One atomic chunk that moves workspace `wsId` to monitor `monitorName`. What the compositor then
// does depends on where the workspace was (CWorkspacePlacementController::moveWorkspaceToMonitor,
// 0.56.2): a hidden workspace arrives hidden and nothing on either screen changes; one that was
// active on a non-focused monitor also arrives hidden, its old monitor switching to another of its
// workspaces; one that was active on the FOCUSED monitor becomes the destination's active
// workspace, takes monitor focus with it and WARPS THE CURSOR to the destination's centre (the Lua
// dispatcher exposes no noWarpCursor). The chunk warps the cursor back so the pointer never leaves
// the overview's screen. Focus is deliberately not restored — the compositor's outcome stands.
function workspaceMoveLua(wsId, monitorName) {
    var ws = wsSelector(wsId)
    return (
        'function()\n' +
        '  local cur = hl.get_cursor_pos()\n' +
        '  ' + dispatchGuardLua() + '\n' +
        '  local ok, err = pcall(function()\n' +
        '    run(hl.dsp.workspace.move({ monitor = "' + monitorName + '", workspace = "' + ws + '" }))\n' +
        '  end)\n' +
        '  ' + reportLua('move workspace') + '\n' +
        '  ' + restoreCursorLua('cur') + '\n' +
        'end'
    ).replace(/\n\s*/g, ' ')
}

// One atomic chunk that swaps monitor `monitorA`'s active workspace with monitor `monitorB`'s.
// `wsId` is the workspace the menu row was drawn for: hl.dsp.workspace.swap_monitors acts on
// whatever is ACTIVE on monitorA at dispatch time (swapActiveWorkspaces, 0.56.2), and that monitor
// may have switched workspaces since the last rebuild — so the chunk verifies the identity first
// and refuses rather than swapping a workspace the user never chose. One dispatcher, so the swap
// itself can never half-apply.
function workspaceSwapLua(wsId, monitorA, monitorB) {
    var ws = wsSelector(wsId)
    return (
        'function()\n' +
        '  local cur = hl.get_cursor_pos()\n' +
        '  ' + dispatchGuardLua() + '\n' +
        '  local ok, err = pcall(function()\n' +
        '    local a = hl.get_active_workspace("' + monitorA + '")\n' +
        '    if not a or tostring(a.id) ~= "' + ws + '" then\n' +
        '      error("workspace ' + ws + ' is no longer active on ' + monitorA + '", 0)\n' +
        '    end\n' +
        '    run(hl.dsp.workspace.swap_monitors({ monitor1 = "' + monitorA + '", monitor2 = "' + monitorB + '" }))\n' +
        '  end)\n' +
        '  ' + reportLua('swap workspaces') + '\n' +
        '  ' + restoreCursorLua('cur') + '\n' +
        'end'
    ).replace(/\n\s*/g, ' ')
}

function _center(b) { return { x: b.x + b.w / 2, y: b.y + b.h / 2 } }

// Spatial arrow-key navigation over the wrapped grid. dir: "left"|"right"|"up"|"down".
// Left/right move within the same row (vertical overlap required); up/down pick the nearest
// box above/below, weighting vertical distance and preferring the closest column. Returns the
// new index, or the current index when there is no box in that direction.
function navigate(boxes, currentIndex, dir) {
    if (currentIndex < 0 || currentIndex >= boxes.length) return currentIndex
    var c = _center(boxes[currentIndex]), rowH = boxes[currentIndex].h
    var best = -1, bestCost = Infinity
    for (var i = 0; i < boxes.length; i++) {
        if (i === currentIndex) continue
        var p = _center(boxes[i]), dx = p.x - c.x, dy = p.y - c.y, cost
        if (dir === "right") { if (dx <= 0 || Math.abs(dy) > rowH / 2) continue; cost = dx + Math.abs(dy) * 4 }
        else if (dir === "left") { if (dx >= 0 || Math.abs(dy) > rowH / 2) continue; cost = -dx + Math.abs(dy) * 4 }
        else if (dir === "down") { if (dy <= 0) continue; cost = dy + Math.abs(dx) * 0.5 }
        else if (dir === "up") { if (dy >= 0) continue; cost = -dy + Math.abs(dx) * 0.5 }
        else continue
        if (cost < bestCost) { bestCost = cost; best = i }
    }
    return best >= 0 ? best : currentIndex
}

function hitWorkspace(boxes, px, py) {
    for (var i = 0; i < boxes.length; i++) {
        var b = boxes[i]
        if (px >= b.x && px <= b.x + b.w && py >= b.y && py <= b.y + b.h)
            return b.workspaceId
    }
    return null
}

// Index of the box showing workspace `id`, or -1.
function indexOfWorkspace(boxes, id) {
    for (var i = 0; i < boxes.length; i++) if (boxes[i].workspaceId === id) return i
    return -1
}

function diffByAddress(prevAddresses, nextTiles) {
    var prev = {}
    for (var i = 0; i < prevAddresses.length; i++) prev[prevAddresses[i]] = true
    var next = {}, adds = [], updates = []
    for (var j = 0; j < nextTiles.length; j++) {
        var t = nextTiles[j]
        next[t.address] = true
        if (prev[t.address]) updates.push(t); else adds.push(t)
    }
    var removes = []
    for (var a in prev) if (!next[a]) removes.push(a)
    return { adds: adds, updates: updates, removes: removes }
}

// Pixels per tick, ramping smoothly up to 900 px/s within a 48px edge band.
function edgeScrollDelta(pointer, viewport, offset, content, elapsedMs) {
    var limit = Math.max(0, content - viewport)
    if (limit === 0 || viewport <= 0) return 0
    var band = Math.min(48, viewport / 2), velocity = 0
    if (pointer < band) velocity = -Math.min(1, (band - pointer) / band)
    else if (pointer > viewport - band) velocity = Math.min(1, (pointer - viewport + band) / band)
    return Math.max(0, Math.min(limit, offset + velocity * 900 * elapsedMs / 1000)) - offset
}

// ---- motion policy and user config ----

// "auto" follows Hyprland's animations:enabled; "full" / "off" override it. Unknown values
// are "auto", so a typo in omascape.json never freezes the picker.
function motionPolicy(configured, hyprAnimations) {
    if (configured === "full" || configured === "off") return configured
    return hyprAnimations ? "full" : "off"
}

// Parse `hyprctl -j getoption animations:enabled`. Hyprland 0.56 reports {"bool": true};
// older builds reported {"int": 1}. Anything unreadable counts as enabled: a failed probe
// must not lose motion.
function hyprAnimationsEnabled(json) {
    var o = null
    try { o = JSON.parse(String(json || "")) } catch (e) { return true }
    if (!o || typeof o !== "object") return true
    if (typeof o["bool"] === "boolean") return o["bool"]
    if (typeof o["int"] === "number") return o["int"] !== 0
    return true
}

// Share-time reminder frame colour (docs/specs/2026-09-12-lock-design.md, addendum): only the
// `rgb(hhhhhh)` / `rgba(hhhhhhhh)` hex forms are accepted — Hyprland's own colour syntax, kept
// for continuity with the rest of the user's Hyprland config even though the frame is now drawn
// by the shell. `lockColorToQml` converts an accepted value to QML's `#aarrggbb` order and
// rejects everything else, so an unvalidated string can never reach a colour property.
var LOCK_BORDER_RE = /^rgba?\([0-9a-fA-F]{6}([0-9a-fA-F]{2})?\)$/

// ~/.config/omarchy/omascape.json → a fully-defaulted settings object. Every key has a default;
// a missing file, a parse error, a wrong type or an unknown key never changes behaviour.
function parseConfig(raw) {
    var o = {}
    try { o = JSON.parse(String(raw || "")) || {} } catch (e) { o = {} }
    if (typeof o !== "object") o = {}
    return {
        scrim: (typeof o.scrim === "boolean") ? o.scrim : true,
        hint: (typeof o.hint === "boolean") ? o.hint : true,
        workspaces: (typeof o.workspaces === "number" && isFinite(o.workspaces))
            ? Math.max(0, Math.floor(o.workspaces)) : 10,
        motion: (o.motion === "full" || o.motion === "off") ? o.motion : "auto",
        lockBorder: (typeof o.lockBorder === "string" && LOCK_BORDER_RE.test(o.lockBorder))
            ? o.lockBorder : "rgb(ff4444)",
        lockBorderSize: (typeof o.lockBorderSize === "number" && isFinite(o.lockBorderSize))
            ? Math.max(0, Math.min(20, Math.floor(o.lockBorderSize))) : 6
    }
}

// ---- Find (docs/specs/2026-09-11-find-design.md) ----------------------------------------
// Fuzzy subsequence ranking over class and title. Pure: the Overview hands in the window list
// `buildInput()` produced (special workspaces already excluded) in layout order, and gets back
// `[{ address, score }]`, best first. Equal scores keep input order, so the ranking never
// jitters between keystrokes.
var FIND_CLASS_BONUS = 2          // "slack" must rank the Slack app above a tab titled "Slack …"
var FIND_LENGTH_PENALTY = 0.01    // per haystack character: shorter wins a tie
var FIND_LENGTH_CAP = 80          // characters of haystack that count toward the penalty; beyond this length no longer discriminates
function _wordStart(hay, i) {
    if (i === 0) return true
    var c = hay.charAt(i - 1)
    return c === " " || c === "-" || c === "_" || c === "." || c === "/" || c === ":"
}
// Score of `needle` as a subsequence of `hay` (both lowercase), or null when it is not one.
// Best alignment, not first occurrence: a dynamic programme over (query char, haystack
// position). Per matched character: 1, +2 when it directly follows the previous matched
// character, +3 at a word start. Greedy first-occurrence would trap "ab" on the isolated 'a' of
// "xax ab" and miss the whole word. O(n·m) per haystack; n is a few characters. The length
// penalty is capped at FIND_LENGTH_CAP characters so a real match always scores above zero and
// a very long title cannot outweigh a word-start bonus.
function fuzzyScore(needle, hay) {
    var n = needle.length, m = hay.length
    if (!n || n > m) return null
    var NEG = -Infinity, prev = null
    for (var i = 0; i < n; i++) {
        var c = needle.charAt(i), cur = new Array(m), bestBefore = NEG   // best of prev[0..j-1]
        for (var j = 0; j < m; j++) {
            if (i > 0 && j >= 1 && prev[j - 1] > bestBefore) bestBefore = prev[j - 1]
            cur[j] = NEG
            if (hay.charAt(j) !== c) continue
            var base = 1 + (_wordStart(hay, j) ? 3 : 0)
            if (i === 0) { cur[j] = base; continue }
            var from = bestBefore                                   // gapped
            if (j >= 1 && prev[j - 1] !== NEG && prev[j - 1] + 2 > from) from = prev[j - 1] + 2   // consecutive
            if (from !== NEG) cur[j] = from + base
        }
        prev = cur
    }
    var best = NEG
    for (var k = 0; k < m; k++) if (prev[k] > best) best = prev[k]
    return best === NEG ? null : best - Math.min(m, FIND_LENGTH_CAP) * FIND_LENGTH_PENALTY
}
function findMatches(query, windows) {
    var q = String(query || "").toLowerCase()
    if (!q.length) return []
    var out = []
    for (var i = 0; i < windows.length; i++) {
        var w = windows[i]
        var sc = fuzzyScore(q, String(w.cls || "").toLowerCase())
        if (sc !== null) sc += FIND_CLASS_BONUS
        var st = fuzzyScore(q, String(w.title || "").toLowerCase())
        var best = sc === null ? st : (st === null ? sc : Math.max(sc, st))
        if (best === null) continue
        out.push({ address: w.address, score: best, order: i })
    }
    // Scores are doubles. A class hit computes (base − penalty) + bonus and a title hit
    // (base + bonus) − penalty; mathematically equal scores can differ by one ulp and skip
    // the order tie-break. Unreachable with realistic window names (0 of 300k cases); if this
    // line is touched, add the bonus before subtracting the penalty.
    out.sort(function (a, b) { return (b.score - a.score) || (a.order - b.order) })
    return out.map(function (m) { return { address: m.address, score: m.score } })
}
// Does a key event's `text` extend the query? Returns the new query, or `query` unchanged.
// Control characters never do (Backspace, Escape, Return and Tab all arrive with non-empty
// text on Qt), and whitespace never starts a query. Digits are accepted here: whether a digit
// jumps instead is decided by the key handler, from whether the query is empty.
function appendQueryText(query, text) {
    var q = String(query || ""), t = String(text || "")
    if (!t.length) return q
    for (var i = 0; i < t.length; i++) {
        var c = t.charCodeAt(i)
        if (c < 0x20 || c === 0x7f) return q
    }
    if (!q.length && !t.trim().length) return q
    return q + t
}

// Arrow keys while a query is active: the same nearest-in-direction rule as `navigate`, but only
// over boxes whose workspace holds a match, so Right from ws 2 lands on ws 4 when 3 has no
// match and Down from ws 1 lands on ws 6 like it does without a query. `matchWs[i]` is the
// workspace id of the i-th ranked match; returns the match index to select — the best-ranked
// match on the chosen workspace — or `current` when there is nowhere to go.
function navigateMatches(boxes, matchWs, current, dir) {
    var has = {}
    for (var i = 0; i < matchWs.length; i++) has[matchWs[i]] = true
    var cand = []
    for (var b = 0; b < boxes.length; b++) if (has[boxes[b].workspaceId]) cand.push(boxes[b])
    if (!cand.length) return current
    var curWs = (current >= 0 && current < matchWs.length) ? matchWs[current] : -1
    var ci = indexOfWorkspace(cand, curWs)
    var ni = ci < 0 ? 0 : navigate(cand, ci, dir)
    var ws = cand[ni].workspaceId
    for (var m = 0; m < matchWs.length; m++) if (matchWs[m] === ws) return m
    return current
}

// ---- Actions (docs/specs/2026-09-15-actions-design.md) -----------------------------------
// The subject of an action. Pure: the view resolves the pointer to a tile/well and hands the
// result in, so this file never touches a delegate or a coordinate system.

// Address of the drawn tile under (px, py), or "". `candidates` are the DISPLAYED rects
// ({ address, x, y, w, h, z }) the view collects from the delegates — scale already folded in,
// so a hovered tile hit-tests at the size it is painted. Highest `z` wins; a tie goes to the
// later candidate, which is the one the Repeater paints on top. The hit test is inclusive on
// all four edges, so a pointer exactly on the shared border of two abutting tiles counts as
// inside both and the z-tie rule picks the later one. Unlike `hitWorkspace`/`tiledDropPlan`
// there is no nearest-rect fallback: an action must never reach a tile the pointer is not
// actually over.
function tileAt(candidates, px, py) {
    var best = null
    for (var i = 0; i < candidates.length; i++) {
        var c = candidates[i]
        if (px < c.x || px > c.x + c.w || py < c.y || py > c.y + c.h) continue
        if (!best || c.z >= best.z) best = c
    }
    return best ? best.address : ""
}

// "Most recent input device wins." A live pointer (see Overview.pointerLive) names what it is
// over and nothing else — over empty canvas an action has NO target, deliberately: silently
// falling back to the keyboard would make Ctrl+W close a window the user is not looking at.
// Otherwise the keyboard: while a query is active the target is the find match and nothing
// else — a query with no match is a TERMINAL "no target", not a fall-through to the cursor or
// the selected workspace. Without that, a mistyped search plus Enter would jump to whatever
// workspace happens to be selected: worse than inert. (Query and cursor cannot both be active
// in the running overview — setQuery() clears the cursor — so this branch never actually needs
// to choose between them; it is written terminal anyway so a future refactor cannot reopen the
// fall-through by "simplifying" it back in.) With no query, the Tab cursor, then the selected
// workspace.
function target(input) {
    if (input.pointerLive) {
        if (input.pointerTileAddress) return { kind: "window", address: input.pointerTileAddress }
        if (hasWs(input.pointerWorkspaceId)) return { kind: "workspace", id: input.pointerWorkspaceId }
        return null
    }
    if (input.query && input.query.length)
        return input.matchAddress ? { kind: "window", address: input.matchAddress } : null
    if (input.cursorAddress) return { kind: "window", address: input.cursorAddress }
    if (hasWs(input.selectedId)) return { kind: "workspace", id: input.selectedId }
    return null
}

// Next/previous window of workspace `wsId` in reading order (y, then x, then address so the
// order can never depend on model insertion). `tiles` must be pre-mapped into the shape
// { address, wsid, x, y } (from raw model rows with wx/wy) so a row cannot collide with a
// QML delegate's own x/y. `skip` is an address→true map of windows with an outstanding close
// request — they are not cycle stops, which is what stops a repeated Ctrl+W from landing back on
// a window it already asked to close. Returns "" when the workspace has no eligible window.
function cycleWindows(tiles, wsId, current, step, skip) {
    var list = []
    for (var i = 0; i < tiles.length; i++) {
        var t = tiles[i]
        if (t.wsid !== wsId) continue
        if (skip && skip[t.address]) continue
        list.push(t)
    }
    if (!list.length) return ""
    list.sort(function (a, b) {
        return (a.y - b.y) || (a.x - b.x) || (a.address < b.address ? -1 : a.address > b.address ? 1 : 0)
    })
    var idx = -1
    for (var j = 0; j < list.length; j++) if (list[j].address === current) { idx = j; break }
    if (idx < 0) return (step > 0 ? list[0] : list[list.length - 1]).address
    return list[((idx + step) % list.length + list.length) % list.length].address
}

// Menu highlight movement: wrapping, and from "none" onto the first (down) or last (up) row.
// Takes the ITEM LIST, not a count, so it can step past a separator (`{ separator: true }`, no
// id, not hoverable or activatable): the highlight must never land on one, whether arrived at by
// stepping or by wrapping off either end. `index < 0` ("none") is treated as sitting just before
// index 0 (stepping down) or just after the last index (stepping up), so the same wrap-and-skip
// loop below handles every case uniformly.
function menuNavigate(items, index, step) {
    var count = items.length
    if (!(count > 0)) return -1
    var i = index < 0 ? (step > 0 ? 0 : count - 1)
                       : ((index + step) % count + count) % count
    for (var n = 0; n < count; n++) {
        if (!items[i].separator) return i
        i = ((i + step) % count + count) % count
    }
    return -1   // degenerate: every item is a separator
}

// Monitor names are interpolated into quoted Lua strings inside the move/swap chunks. Anything
// outside this alphabet is refused here, in JavaScript, before it can reach a chunk at all —
// the same defence `validLockSelector` gives the lock chunks.
var MONITOR_NAME_RE = /^[A-Za-z0-9._-]+$/
function validMonitorName(name) { return typeof name === "string" && MONITOR_NAME_RE.test(name) }

// Nerd Font glyphs (nf-md-laptop / nf-md-monitor). Internal panels are eDP/LVDS/DSI connectors,
// everything else is an external screen. Lives here rather than in Overview so `menuItems` can
// stay pure and the monitor chips and the menu can never disagree about which glyph a monitor gets.
function monitorGlyph(name) { return /^(eDP|LVDS|DSI)/i.test(name) ? "\u{F0322}" : "\u{F0379}" }

// Lock/Unlock, Move to <monitor>, Swap with <monitor>, Close all windows — the rows that act on
// a workspace as a CONTAINER. Shared by the workspace-target menu (below) and the window-target
// menu's group below the separator (docs/specs/2026-09-15-actions-design.md, "The menu",
// addenda 2026-09-17 and 2026-09-18), so the two can never disagree about what a workspace
// offers or in what order.
function workspaceMenuRows(b, monitors) {
    var out = []
    out.push(b.armed ? { id: "unlock", label: "Unlock" } : { id: "lock", label: "Lock" })
    // Monitor operations need a workspace the compositor actually has, on a machine with
    // somewhere to send it. The scratchpad has no monitor of its own to move between.
    var others = []
    if (!b.special && !b.synthetic) {
        var mons = monitors || []
        for (var i = 0; i < mons.length; i++) {
            var n = mons[i] ? mons[i].name : null
            if (!validMonitorName(n) || n === b.monitorName) continue
            others.push(n)
        }
    }
    for (var m = 0; m < others.length; m++)
        out.push({ id: "move:" + others[m], label: "Move to " + others[m], glyph: monitorGlyph(others[m]) })
    // Swap exchanges the two monitors' ACTIVE workspaces (swapActiveWorkspaces, 0.56.2), so it is
    // only offered for a workspace its monitor is actually showing.
    if (b.active)
        for (var s = 0; s < others.length; s++)
            out.push({ id: "swap:" + others[s], label: "Swap with " + others[s], glyph: monitorGlyph(others[s]) })
    // ✎ Close all needs MORE THAN ONE window (2026-09-18), not merely an occupied workspace:
    // above a single window it is Close wearing a longer label and a confirmation dialog, and
    // offering both invites picking the heavier one by accident. Last in the group, the furthest
    // row from the window menu's own Close.
    if (b.windowCount > 1) out.push({ id: "closeAll", label: "Close all windows" })
    return out
}

// The rows a context menu shows for `tgt`. Pure: `ctx` carries the window record
// (`_windowByAddress`), the box record (`layout()`'s own output — the WINDOW's own workspace
// box for a window target, ✎ 2026-09-17, not necessarily the selected one) and the monitor
// list, all re-read on every rebuild, so an open menu follows the compositor rather than a
// snapshot. Anything that does not apply is HIDDEN, never greyed, and every id names the state
// it will set — never a toggle, so a stale activation is at worst a no-op inside the compositor.
function menuItems(tgt, ctx) {
    if (!tgt || !ctx) return []
    var out = []
    if (tgt.kind === "window") {
        var w = ctx.win
        if (!w) return []                               // gone: the caller dismisses on an empty list
        out.push({ id: "close", label: "Close" })
        out.push(w.floating ? { id: "tile", label: "Tile" } : { id: "float", label: "Float" })
        out.push(fullscreenMode(w) > 0 ? { id: "unfullscreen", label: "Exit fullscreen" }
                                       : { id: "fullscreen", label: "Fullscreen" })
        // ✎ A window's menu also carries its workspace's actions, below a separator — Close all
        // among them (2026-09-18, reversing the 2026-09-17 addendum that put it beside Close):
        // grouped by SCOPE, so nothing acting on every window sits among the rows acting on this
        // one. Needs the window's OWN workspace box, which may be null (the workspace vanished a
        // settle tick before this refresh) — then there is simply no group. Lock/Unlock is
        // unconditional (see workspaceMenuRows), so whenever `wb` exists the group is non-empty
        // and the separator never has nothing under it.
        var wb = ctx.box
        if (wb) {
            var wsRows = workspaceMenuRows(wb, ctx.monitors)
            if (wsRows.length) {
                out.push({ id: "separator", separator: true })
                out = out.concat(wsRows)
            }
        }
        return out
    }
    var b = ctx.box
    if (!b) return []
    return workspaceMenuRows(b, ctx.monitors)
}

// A press of a modifier key ALONE. It belongs to no class: it must not drive the menu (Ctrl then
// W would otherwise dismiss and then close a window) and must not clear pointer liveness (hover +
// Ctrl+W could never work, because the Ctrl press would go stale before the W arrived).
function isModifierKey(key) {
    return key === 0x01000020 ||   // Qt.Key_Shift
           key === 0x01000021 ||   // Qt.Key_Control
           key === 0x01000023 ||   // Qt.Key_Alt
           key === 0x01000022 ||   // Qt.Key_Meta
           key === 0x01000024 ||   // Qt.Key_CapsLock
           key === 0x01001103      // Qt.Key_AltGr
}

// An ACTION key reads pointer liveness and leaves it unchanged — "do this to what I am pointing
// at", not "I am on the keyboard now" — so a second Ctrl+W cannot silently switch from the
// hovered window to the Tab cursor. Everything else is navigation or query intent and clears
// liveness on entry. `chord` is the event's Ctrl/Alt/Meta mask.
function isActionKey(key, chord, ctrlMask) {
    if (chord === ctrlMask && key === 0x57) return true            // Ctrl+W (Qt.Key_W)
    if (chord) return false
    return key === 0x01000004 || key === 0x01000005                // Return, Enter
}

// ---- Scratchpad (docs/specs/2026-09-12-scratchpad-design.md) ---------------------------
// Hyprland allocates special-workspace ids dynamically (the next free id below -99), so the
// overview never uses the reported id: buildInput() identifies the scratchpad by name and remaps
// it, and its windows, onto this constant. It cannot collide: regular ids are >= 1, -1 is the
// "none" sentinel, Hyprland's special ids are <= -99.
var SCRATCHPAD_ID = -2
var SCRATCHPAD_BARE = "scratchpad"
var SCRATCHPAD_NAME = "special:" + SCRATCHPAD_BARE
function isScratchpad(id) { return id === SCRATCHPAD_ID }
// "Has a workspace": only -1 means none. Replaces every `id >= 0` test that meant that, so
// the scratchpad's negative id is legal wherever a selection or target is checked.
function hasWs(id) { return typeof id === "number" && isFinite(id) && id !== -1 }
// Dispatch target: the scratchpad by name, a normal workspace by id.
function wsSelector(id) { return isScratchpad(id) ? SCRATCHPAD_NAME : (typeof id === "number" && isFinite(id)) ? String(id) : "" }

// Enter on the scratchpad box: bring the scratchpad up on the focused monitor, like SUPER+S —
// but never hide one that is already up. One guarded chunk, reported like the others.
function scratchpadShowLua() {
    return (
        'function()\n' +
        '  ' + dispatchGuardLua() + '\n' +
        '  local ok, err = pcall(function()\n' +
        '    local ws = hl.get_active_special_workspace()\n' +
        '    if not (ws and ws.name == "' + SCRATCHPAD_NAME + '") then run(hl.dsp.workspace.toggle_special("' + SCRATCHPAD_BARE + '")) end\n' +
        '  end)\n' +
        '  ' + reportLua('show scratchpad') + '\n' +
        'end'
    ).replace(/\n\s*/g, ' ')
}

// Tile click in the scratchpad row: focus raises the special workspace, but a floating
// scratchpad window stays under whichever sibling was last on top — raise it explicitly, by
// address (`alter_zorder` targets a window; `bring_to_top` acts on the active window, which the
// focus above may not have made active yet while the special workspace is still coming up).
function scratchpadFocusLua(addr) {
    return (
        'function()\n' +
        '  local sel = "address:' + addr + '"\n' +
        '  ' + dispatchGuardLua() + '\n' +
        '  local ok, err = pcall(function()\n' +
        '    run(hl.dsp.focus({ window = sel }))\n' +
        '    run(hl.dsp.window.alter_zorder({ mode = "top", window = sel }))\n' +
        '  end)\n' +
        '  ' + reportLua('focus scratchpad window') + '\n' +
        'end'
    ).replace(/\n\s*/g, ' ')
}

// ---- Workspace lock (docs/specs/2026-09-12-lock-design.md) ---------------------------------
// A selector is a workspace id ("3") or a special workspace name ("special:scratchpad"). It is
// interpolated into Lua, so anything else is refused here, in JavaScript, before it can reach
// a chunk.
// Hyprland parses "007" as workspace 7 (leading zeros stripped), so a hand-edited "007" would
// arm workspace 7 with no badge to show it — numeric selectors must be a canonical decimal.
var LOCK_SELECTOR_RE = /^([1-9]\d*|special:[A-Za-z0-9_-]+)$/
function validLockSelector(sel) { return typeof sel === "string" && LOCK_SELECTOR_RE.test(sel) }

// ---- Share-time reminder frame (docs/specs/2026-09-12-lock-design.md, addendum) --------------
// The cue is four thin layer-shell strips omascape draws at the monitor edges, blanked in every
// capture by a `no_screen_share` layer rule on their namespace. These four functions are the
// whole decision: which workspace a monitor is showing, whether that earns a frame, which raw
// events invalidate the monitor snapshot, and how the configured colour becomes a QML one.

// The selector for the workspace a monitor currently SHOWS, from its `lastIpcObject`: the special
// workspace when one is open, else the active workspace. Hyprland reports
// `specialWorkspace: { id: 0, name: "" }` when none is open (the same "nothing" the
// `activespecialv2>>,,<mon>` payload announces), so the NAME — not the object's presence — is
// what decides. The result is a locks-file selector ("3" / "special:scratchpad"), never the
// dynamic special id. A malformed or missing snapshot yields null and never throws: this runs in
// a binding that re-evaluates on every monitor event, including ones that land before the first
// refresh.
function lockFrameShownSelector(mon) {
    if (!mon || typeof mon !== "object") return null
    var sp = mon.specialWorkspace
    if (sp && typeof sp === "object" && typeof sp.name === "string" && sp.name.length) return sp.name
    var aw = mon.activeWorkspace
    if (aw && typeof aw === "object" && typeof aw.id === "number" && isFinite(aw.id)) return String(aw.id)
    return null
}

// Is a monitor's frame visible? Only while a share is actually running (`locks.sharing`, the
// debounced compositor signal) AND the workspace that monitor is showing is armed. `armed` is the
// array `applyLocksTo` maintains — null while the locks file is still unresolved, which means no
// frame (never guess protection that may not be installed yet).
function lockFrameVisible(sharing, armed, mon) {
    if (sharing !== true || !armed || !armed.length) return false
    var sel = lockFrameShownSelector(mon)
    return sel !== null && armed.indexOf(sel) >= 0
}

// Raw Hyprland events after which a monitor's `lastIpcObject` may be stale, so the shell must ask
// for a fresh one (`Hyprland.refreshMonitors()`). Payloads verified in 0.56.2 source:
//   workspacev2>>id,name                — the focused monitor changed workspace
//   focusedmonv2>>monname,wsid          — focus moved to another monitor
//   activespecialv2>>id,name,monname    — a special workspace opened/closed there ("" id+name = closed)
//   moveworkspacev2>>id,name,monname    — a workspace moved to another monitor
//   monitoraddedv2 / monitorremovedv2   — the set of monitors changed
//   configreloaded                      — every Lua global (our layer rule included) is gone
// Deliberately NOT the whole event stream: a refresh is an IPC round trip, and window titles,
// focus changes and open/close events cannot move a workspace between monitors.
function lockFrameRefreshEvent(name) {
    return name === "workspacev2" || name === "focusedmonv2" || name === "activespecialv2" ||
           name === "moveworkspacev2" || name === "monitoraddedv2" || name === "monitorremovedv2" ||
           name === "configreloaded"
}

// The configured colour (Hyprland's `rgb(rrggbb)` / `rgba(rrggbbaa)`, validated by
// LOCK_BORDER_RE) as a QML colour string. The alpha moves from the END to the FRONT: Qt reads
// `#rrggbbaa` as `#aarrggbb`, so `rgba(ff444480)` left as-is would render as a nearly opaque
// near-black instead of a translucent red. Anything else — including an already-QML `#rrggbb` —
// falls back to the default red rather than producing an invalid colour, which QML would resolve
// to black.
function lockColorToQml(hypr) {
    var s = String(hypr === undefined || hypr === null ? "" : hypr)
    if (!LOCK_BORDER_RE.test(s)) return "#ff4444"
    var hex = s.slice(s.indexOf("(") + 1, s.length - 1)
    if (hex.length === 8) return "#" + hex.slice(6, 8) + hex.slice(0, 6)
    return "#" + hex
}

// The logical thickness of a frame strip's SURFACE, given the painted thickness and the monitor's
// scale: the smallest integer at least one logical px larger than the paint whose DEVICE size is a
// whole number. The blanking box a `no_screen_share` layer draws is rasterised from the surface's
// logical geometry × the scale with its origin floored and its size truncated — it covers
// `[floor(start), floor(start) + floor(size))` — so a surface whose device size is fractional is
// always one device line short, and whichever line that is (inner or outer) shows the frame in
// every capture. Snapping the SURFACE (never the paint: `lockBorderSize` is what the user asked
// for) makes the blanked box exactly the surface, with the paint strictly inside it.
// The search stops 12 px out: at that point no scale in practical use has failed to land on a
// whole number, and growing the surface without bound to satisfy an exotic scale would blank far
// more of the screen than the cue occupies. Falling back to `thickness + 1` there costs at most a
// one-device-pixel hairline of the frame colour in a capture, which discloses nothing.
// A scale that is not a positive finite number (a monitor object we never got, a malformed
// snapshot) degrades the same way instead of throwing — this runs in a binding.
function lockFrameSurfaceSize(thickness, scale) {
    var t = (typeof thickness === "number" && isFinite(thickness)) ? Math.max(0, Math.round(thickness)) : 0
    var base = t + 1
    if (typeof scale !== "number" || !isFinite(scale) || scale <= 0) return base
    for (var s = base; s <= t + 12; s++) {
        var d = s * scale
        if (Math.abs(d - Math.round(d)) < 1e-4) return s
    }
    return base
}

// Bump on ANY change to the observer callback's body (including which `kind` values it
// ignores). `_G.omascape_lock` is compositor Lua state that survives a shell restart, and the
// callback lives in a closure owned by the old subscription — `L.sub:is_active()` stays true
// across a restart, so without a version check the install's own idempotence guard
// (`if not (L.sub and L.sub:is_active())`) would keep the STALE callback forever; a shell
// restart alone could never deliver a behaviour change to a running compositor, only a
// `configreloaded` (which drops `_G` entirely) would.
// 3 (share-time reminder border, 2026-09-14 addendum): the callback body changed from calling
// `L.publish()` to calling `L.apply()` (reconcile every window-border rule's enabled state, THEN
// publish) — a running compositor whose callback still only publishes would never toggle a border
// added after it started, so the body change itself had to force the stale callback out, the same
// as the `kind` filter did at version 2.
// 4 (share-state hysteresis, 2026-09-14 round 3): the callback body changed again — it no longer
// applies every edge. It keeps `L.sharing` as the raw counter but drives the cue and the state
// file from `L.effective`, a debounced view of it: a true edge applies at once and cancels any
// pending grace timer, a false edge only arms a `LOCK_SHARE_GRACE_MS` oneshot that turns the cue
// off if no true arrived meanwhile. A compositor still running the v3 callback would keep
// flapping twice a second (see LOCK_SHARE_GRACE_MS below), so the body change had to force the
// stale callback out.
// NOT bumped for round 4 (the window-border rules replaced by the shell's own layer-shell frame):
// the callback body's TEXT is unchanged — it still calls `L.apply()`, which every install
// redefines on the shared `L` table before the version check runs, so a compositor running the v4
// callback picks up the new (publish-only) `L.apply()` the moment the new shell installs. Only a
// change to the callback's own body needs a bump.
var LOCK_OBSERVER_VERSION = 4

// Grace period before a share that stopped signalling is treated as over. Hyprland's
// ScreenshareSession.cpp emits `screenshare.state(true, …)` on every successfully COPIED frame
// and `screenshare.state(false, …)` from a 500 ms timer that fires whenever no frame arrived for
// half a second — so a consumer that pulls frames irregularly (OBS on a mostly static screen)
// makes the compositor emit false/true pairs for the whole recording: measured 20 events in 30 s
// on 2026-09-14, every false run under ~1 s. Applying each edge rewrote the state file twice a
// second, which the shell's FileView dutifully reloaded — flickering the reminder frame and the
// overview's placeholder with it (in round 3 it also toggled `border_size`, relayouting every
// window on the workspace). 3000 ms leaves headroom over the longest measured gap for a fully
// static screen. The trade-off is one-sided: too short means flicker, too long means the frame
// lingers a few seconds after the share really ended — cosmetic only, because the exclusion rules
// are always on and privacy never depends on this signal.
var LOCK_SHARE_GRACE_MS = 3000

// Install the compositor-side lock state: one table in _G, the share observer that publishes 1/0
// to $XDG_RUNTIME_DIR/omascape/share-state, and the `no_screen_share` LAYER rule that blanks the
// reminder frame's own strips in every capture (see the frame-rule block below). No such rule for
// the overview's own namespace: a `no_screen_share` layer renders as an opaque black rect over
// that surface's whole box while mapped (ScreenshareFrame.cpp), which for the overview would mean
// a black rect over the whole screen whenever it is open — and toplevel export of an armed window
// is denied by Hyprland regardless (see lockSyncLua's per-workspace window rules), so the
// overview cannot leak armed pixels without it. The frame's strips are thin edge surfaces, so the
// same blanking is exactly what is wanted there.
// Idempotent: re-running keeps the rules, the subscription and the share counter.
// Dispatched at shell start, on configreloaded (a reload drops every global) and at open().
// The share observer is created FIRST, unconditionally inside the outer pcall, before anything
// touches the filesystem: a broken $XDG_RUNTIME_DIR (or a write/rename failure) must degrade
// only share detection, never the lock itself. Before that, `L.subVer` is checked against
// `LOCK_OBSERVER_VERSION`: a mismatch (nil on an old install, or an older version number) drops
// the existing subscription — even though it is still `is_active()` — so the block below always
// creates a fresh one carrying the current callback (see LOCK_OBSERVER_VERSION above).
// `L.publish` and `L.ensureDir` are defined unconditionally too — the observer's callback closes
// over them. The verify-dir-and-publish step runs in its OWN inner pcall; on failure it is
// re-raised (`error(perr, 0)`) so the outer pcall's own `ok, err` — which reportLua reads —
// carries the filesystem failure while the subscription it already created is left standing on
// `L`, unaffected by the raised error.
// `L.ensureDir()` runs on EVERY install, not only when `L.dir` is nil: `_G.omascape_lock` is
// compositor Lua state that survives a shell restart, so a previous install's `L.dir` can point
// at a runtime directory that no longer exists (removed by a cleaner, or just gone —
// live-confirmed after the user's first manual restart: `L.dir` stayed set to a directory that
// had vanished, and every publish failed with "cannot write share-state" forever, since nothing
// ever re-checked). It probes FIRST (a single `io.open`) and only runs `mkdir -p` — measured at
// ~2.5ms of compositor main-thread time — when the probe fails, so the common case (directory
// already there) costs one file open, not a shell-out, even though it runs on every install
// (including every overview open). `L.publish()` also calls `L.ensureDir()` and retries its own
// `io.open` once if the directory turns out to be gone at share-event time, so a share observed
// between installs recovers immediately instead of failing until the next `configreloaded` or
// `open()`.
// `os.execute`'s return value cannot be trusted here (live-verified on this Hyprland build):
// the compositor reaps the child itself, so Lua never sees an exit status — `os.execute`
// returns nil even when `mkdir -p` succeeded and the directory exists. It is called (only when
// the probe already failed) and its result ignored; the directory is verified directly instead:
// open (and immediately remove) a probe file in it.
function lockInstallLua() {
    return (
        'function()\n' +
        '  local ok, err = pcall(function()\n' +
        '    local L = _G.omascape_lock\n' +
        '    if not L then L = { rules = {}, sharing = 0, effective = false, grace = nil, sub = nil, subVer = nil, dir = nil, frameRule = nil }; _G.omascape_lock = L end\n' +
        // `L.sharing` is the raw balanced counter; `L.effective` is the debounced view of it that
        // the state file follows (see LOCK_SHARE_GRACE_MS). Seeded from the
        // counter — and only when unset — so an install landing on an `_G.omascape_lock` from a
        // pre-hysteresis build starts out agreeing with whatever is actually running, and a later
        // re-install never resets a live `false` grace decision back to `true`.
        '    if L.effective == nil then L.effective = L.sharing > 0 end\n' +
        // Upgrade off round 3: a compositor that has been running since then still holds an
        // `L.borders` table of `omascape-lock-border-<sel>` window rules — possibly enabled — that
        // nothing in round 4 touches any more. This Lua API can disable a rule but never remove
        // one, so without this sweep those rims would keep colouring every window on an armed
        // workspace until the user's next config reload. Disabled once (each guarded on its own:
        // a dead handle must not abort the install) and the table dropped, so a later install has
        // nothing left to do.
        '    if L.borders then\n' +
        '      for _, r in pairs(L.borders) do pcall(function() r:set_enabled(false) end) end\n' +
        '      L.borders = nil\n' +
        '    end\n' +
        '    function L.ensureDir()\n' +
        '      local base = os.getenv("XDG_RUNTIME_DIR"); if not base then error("XDG_RUNTIME_DIR unset") end\n' +
        '      local dir = base .. "/omascape"\n' +
        '      local probe = io.open(dir .. "/.omascape-probe", "w")\n' +
        '      if not probe then\n' +
        '        os.execute("mkdir -p \'" .. dir .. "\'")\n' +
        '        probe = io.open(dir .. "/.omascape-probe", "w")\n' +
        '        if not probe then error("runtime dir unavailable: " .. dir) end\n' +
        '      end\n' +
        '      probe:close(); os.remove(dir .. "/.omascape-probe")\n' +
        '      L.dir = dir\n' +
        '    end\n' +
        '    function L.publish()\n' +
        '      local tmp, dst = L.dir .. "/share-state.tmp", L.dir .. "/share-state"\n' +
        '      local f = io.open(tmp, "w")\n' +
        '      if not f then\n' +
        '        L.ensureDir()\n' +
        '        tmp, dst = L.dir .. "/share-state.tmp", L.dir .. "/share-state"\n' +
        '        f = io.open(tmp, "w")\n' +
        '      end\n' +
        '      if not f then error("cannot write share-state") end\n' +
        '      local w = f:write(L.effective and "1" or "0"); local c = f:close()\n' +
        '      if not w or not c then os.remove(tmp); error("write share-state failed") end\n' +
        '      local rok, rerr = os.rename(tmp, dst)\n' +
        '      if not rok then os.remove(tmp); error("rename share-state: " .. tostring(rerr)) end\n' +
        '    end\n' +
        // L.apply() is defined here — before the subVer check and the observer subscription
        // below, which calls it — so a fresh subscription's callback always closes over a
        // fully-defined function (never a stale/partial one from an earlier install). Since round
        // 4 the compositor side has nothing to reconcile on a share edge (the cue is the shell's
        // own layer-shell frame, driven by the published state file), so applying IS publishing.
        // It stays a named function rather than being inlined: the observer callback's body text
        // is what LOCK_OBSERVER_VERSION guards, and keeping the indirection means a future change
        // on this side does not force every running compositor's subscription to be replaced.
        '    function L.apply()\n' +
        '      L.publish()\n' +
        '    end\n' +
        '    if L.subVer ~= ' + LOCK_OBSERVER_VERSION + ' then\n' +
        '      if L.sub then pcall(function() L.sub:remove() end) end\n' +
        '      L.sub = nil\n' +
        '      L.subVer = ' + LOCK_OBSERVER_VERSION + '\n' +
        '    end\n' +
        '    if not (L.sub and L.sub:is_active()) then\n' +
        // Hysteresis (see LOCK_SHARE_GRACE_MS): the ON edge applies at once and cancels any
        // pending off; the OFF edge only arms a oneshot that applies it LOCK_SHARE_GRACE_MS
        // later, and only if the count is still 0 by then. A fresh timer per off-edge, never a
        // re-armed one: probed live on 0.56.2, a oneshot that has already fired cannot be
        // restarted (set_enabled(true)/set_timeout after firing do nothing), while
        // set_enabled(false) BEFORE it fires cancels it for good. The timer callback carries its
        // own pcall + print: it runs on the compositor's clock, outside the pcall below, and
        // L.apply() can raise (a publish failure) — an unguarded error there would surface as a
        // bare Lua error inside the compositor rather than an omascape log line.
        '      L.sub = hl.on("screenshare.state", function(active, kind)\n' +
        '        if kind == 1 then return end\n' +
        '        local sok, serr = pcall(function()\n' +
        '          L.sharing = math.max(0, L.sharing + (active and 1 or -1))\n' +
        '          if L.sharing > 0 then\n' +
        '            if L.grace then pcall(function() L.grace:set_enabled(false) end); L.grace = nil end\n' +
        '            if not L.effective then L.effective = true; L.apply() end\n' +
        // `elseif L.effective`: an off edge while already idle has nothing to turn off, so it
        // arms nothing (a pending grace always implies L.effective == true). If hl.timer is
        // missing or throws, degrade to the immediate off rather than leave L.effective stuck
        // true — stuck, every later ON edge would be a no-op and every OFF edge would throw
        // again, so the rim would stay on every armed workspace until a config reload.
        '          elseif L.effective then\n' +
        '            if L.grace then pcall(function() L.grace:set_enabled(false) end) end\n' +
        '            local tok, t = pcall(function()\n' +
        '              return hl.timer(function()\n' +
        '                L.grace = nil\n' +
        '                local gok, gerr = pcall(function()\n' +
        '                  if L.sharing == 0 and L.effective then L.effective = false; L.apply() end\n' +
        '                end)\n' +
        '                if not gok then print("omascape: share grace timer failed: " .. tostring(gerr)) end\n' +
        '              end, { timeout = ' + LOCK_SHARE_GRACE_MS + ', type = "oneshot" })\n' +
        '            end)\n' +
        '            L.grace = tok and t or nil\n' +
        '            if not L.grace then L.effective = false; L.apply() end\n' +
        '          end\n' +
        '        end)\n' +
        '        if not sok then print("omascape: share observer failed: " .. tostring(serr)) end\n' +
        '      end)\n' +
        '    end\n' +
        // Share-time reminder frame (addendum, round 4): the strips omascape maps at the monitor
        // edges are its own layer surfaces, and this rule is what keeps them out of every capture
        // — a `no_screen_share` LAYER renders as an opaque black rect over that surface's own box
        // while mapped (ScreenshareFrame.cpp), so the frame's four thin strips go black in the
        // recording and the red cue stays purely local. Live-probed 2026-09-14 on the bar's
        // namespace: only that surface's 26 px strip went black (mean 0), the rest of the frame
        // was untouched — per-surface blanking, not a whole-screen blank.
        // Created once and kept on `L` (this Hyprland Lua API can only disable a rule, never
        // remove it, and install runs on every overview open), but re-created after a
        // `configreloaded` like every other rule, since that drops `_G` entirely. A surviving
        // rule that is somehow disabled is re-enabled rather than duplicated: a second rule under
        // the same name would not undo the first. Its own pcall, so a failure here cannot take
        // down the exclusion rules or the share observer — which are the actual protection — and
        // the error is re-raised below into the install's existing report path.
        '    local fok, ferr = pcall(function()\n' +
        '      if L.frameRule then\n' +
        '        local iok, cur = pcall(function() return L.frameRule:is_enabled() end)\n' +
        '        if (not iok) or cur == false then L.frameRule:set_enabled(true) end\n' +
        '      else\n' +
        '        L.frameRule = hl.layer_rule({ name = "omascape-lockframe", match = { namespace = "omascape-lockframe" }, no_screen_share = true })\n' +
        '      end\n' +
        '    end)\n' +
        '    local pok, perr = pcall(function()\n' +
        '      L.ensureDir()\n' +
        '      L.apply()\n' +
        '    end)\n' +
        // Precedence, when both steps failed and there is one `ok, err` to report: the FILESYSTEM
        // wins. A failed layer rule only costs the local cue's blanking (the frame would appear in
        // the capture); a failed ensureDir/publish costs share DETECTION itself, so the frame and
        // the overview's placeholder never appear at all — the bigger failure, and the one whose
        // cause (a broken runtime dir) the user can act on. Each is still reported when it fails
        // alone.
        '    if not pok then error(perr, 0) end\n' +
        '    if not fok then error(ferr, 0) end\n' +
        '  end)\n' +
        '  ' + reportLua('lock install') + '\n' +
        'end'
    ).replace(/\n\s*/g, ' ')
}

// Reconcile the compositor's rule table with the full armed set: create (enabled) or re-enable
// a named rule per armed selector, disable every other rule the table holds. Each step is
// guarded on its own so one failure never leaves another selector unprotected; failures are
// reported once, naming every selector that failed. A failed re-enable drops the dead handle
// from L.rules (rather than leaving it there forever, unusable): the next sync that arms the
// same selector sees no handle and creates a fresh rule instead of retrying a broken one.
// This chunk never publishes the share-state file: a sync never changes `L.sharing` (only the
// observer does), so republishing here would be redundant and — being a filesystem operation —
// could fail for reasons that have nothing to do with rule reconciliation. Folding that failure
// into this chunk's `ok, err` would make "lock sync failed" notifications fire for a stale
// runtime directory even though every rule was reconciled correctly; this chunk's report
// describes rule reconciliation only.
function lockSyncLua(armed) {
    var sels = []
    for (var i = 0; i < (armed || []).length; i++) if (validLockSelector(armed[i])) sels.push('"' + armed[i] + '"')
    return (
        'function()\n' +
        '  local ARMED = {' + sels.join(', ') + '}\n' +
        '  local L = _G.omascape_lock\n' +
        '  local ok, err = L ~= nil, "lock not installed"\n' +
        '  if L then\n' +
        '    local want = {}; for _, sel in ipairs(ARMED) do want[sel] = true end\n' +
        '    local failed = {}\n' +
        '    local function step(sel, f) local sok, serr = pcall(f); if not sok then failed[#failed + 1] = sel .. ": " .. tostring(serr) end end\n' +
        '    for sel in pairs(want) do\n' +
        '      step(sel, function()\n' +
        '        local r = L.rules[sel]\n' +
        '        if not r then\n' +
        '          r = hl.window_rule({ name = "omascape-lock-" .. sel, match = { workspace = sel }, no_screen_share = true, enabled = true })\n' +
        '          L.rules[sel] = r\n' +
        '        else\n' +
        '          local eok, eerr = pcall(function() r:set_enabled(true) end)\n' +
        '          if not eok then L.rules[sel] = nil; error(eerr, 0) end\n' +
        '        end\n' +
        '      end)\n' +
        '    end\n' +
        '    for sel, r in pairs(L.rules) do if not want[sel] then step(sel, function() r:set_enabled(false) end) end end\n' +
        '    ok, err = #failed == 0, table.concat(failed, "; ")\n' +
        '  end\n' +
        '  ' + reportLua('lock sync') + '\n' +
        'end'
    ).replace(/\n\s*/g, ' ')
}

// Parse the locks file. Only the shape { armed: [selector…] } is accepted; every selector is
// validated. Returns { ok, armed } or { ok: false, error }.
function parseLocks(raw) {
    var o
    try { o = JSON.parse(String(raw || "")) } catch (e) { return { ok: false, error: "not JSON" } }
    if (!o || typeof o !== "object" || !Array.isArray(o.armed)) return { ok: false, error: "no armed array" }
    var out = []
    for (var i = 0; i < o.armed.length; i++) {
        if (!validLockSelector(o.armed[i])) return { ok: false, error: "bad selector: " + String(o.armed[i]) }
        if (out.indexOf(o.armed[i]) < 0) out.push(o.armed[i])
    }
    return { ok: true, armed: out }
}

// Reduce a locks-file load result onto the current `armed` value. `status` is "ok" (raw holds
// the file's fresh text), "missing" (the file does not exist: resolves to [] once, on the first
// load only — a later "missing" load, e.g. the user deleted the file, keeps the last valid set)
// or "error:<text>" (any other read/parse failure: keeps the previous value — still null if this
// is the first load — and reports it). Returns { armed, changed, error }: `armed` is the value
// the caller should store, `changed` says whether a `loadedArmed()`-style signal is due, `error`
// is set (a string) when the file should be reported as unreadable/invalid.
function applyLocksTo(current, raw, status) {
    if (status === "missing") {
        if (current === null) return { armed: [], changed: true, error: null }
        return { armed: current, changed: false, error: null }
    }
    if (status !== "ok") {
        var text = status.indexOf("error:") === 0 ? status.slice(6) : status
        return { armed: current, changed: false, error: text }
    }
    var parsed = parseLocks(raw)
    if (!parsed.ok) return { armed: current, changed: false, error: parsed.error }
    // `watchChanges`/an explicit reload() re-emits `loaded` even when the bytes on disk did not
    // change (our own atomic write reads back its own content; a repeated stub `loadArmed` in
    // tests). Comparing here — not just returning `changed: true` on every successful parse —
    // is what stops that echo from re-dispatching a sync (and, via the Overview, re-rebuilding)
    // for every "load" that carries no real change. `current === null` always counts as changed
    // (the first resolution): there is no previous set to compare against.
    return { armed: parsed.armed, changed: current === null || !sameSelectors(current, parsed.armed), error: null }
}

// Same selectors, in the same order — a plain array-of-strings equality used only to decide
// whether a load actually changed anything.
function sameSelectors(a, b) {
    if (a.length !== b.length) return false
    for (var i = 0; i < a.length; i++) if (a[i] !== b[i]) return false
    return true
}

// Toggle `sel` in `armed`. Returns a new array, or `null` when the toggle must be refused
// (armed is unresolved, or the selector fails validation) — the caller treats null as "did
// nothing" and must not sync or write.
function toggleSelector(armed, sel) {
    if (armed === null || !validLockSelector(sel)) return null
    var next = armed.slice(); var i = next.indexOf(sel)
    if (i >= 0) next.splice(i, 1); else next.push(sel)
    return next
}

// One-line, pcall-guarded chunk that shows a Hyprland notification. Every value that reaches
// here (a Quickshell FileView error, a JSON parse error) is untrusted text, so it is truncated
// to a 200-character budget FIRST, on the raw (unescaped) input, and only THEN escaped —
// escaping first and truncating the result would risk slicing a just-introduced `\\` escape
// pair in half, leaving a lone trailing backslash that escapes the chunk's closing quote and
// makes the whole thing unparseable. Escaping itself: backslashes and quotes first (order
// matters — escaping the quote first would double-escape the backslash it just introduced),
// then newlines/tabs flattened to a single space (the chunk itself must stay single-line).
function notifyLua(text) {
    var raw = String(text === undefined || text === null ? "" : text)
    var cut = raw.length > 200
    if (cut) raw = raw.slice(0, 200) + "…"
    var t = raw
        .replace(/\\/g, "\\\\")
        .replace(/"/g, "\\\"")
        .replace(/[\n\r\t]+/g, " ")
    return (
        'function()\n' +
        '  pcall(function() hl.notification.create({ text = "' + t + '", duration = 4000, icon = "error" }) end)\n' +
        'end'
    ).replace(/\n\s*/g, ' ')
}
