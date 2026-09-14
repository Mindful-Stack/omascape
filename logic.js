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
        out.push({ id: id, monitorName: host, focused: false, occupied: false, synthetic: true })
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
                            armed: !!chunk[c].armed, placeholder: !!chunk[c].placeholder }
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
                     armed: !!sws.armed, placeholder: !!sws.placeholder }
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
        '  local msg = "omyview: ' + what + ' failed: " .. tostring(err)\n' +
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
        '  if ' + curExpr + ' then hl.dispatch(hl.dsp.cursor.move({ x = ' + curExpr + '.x, y = ' + curExpr + '.y })) end\n' +
        'end'
    )
}

// One atomic chunk that turns fullscreen off for `addr`. Focus is left unchanged (re-focused
// only if the dispatcher moved it) and the cursor is restored. Used by the tile badge. The
// toggle runs inside pcall so restoreFocusLua still runs (and
// focus/cursor still land back where they were) even if the dispatcher throws — parity with
// tiledInsertLua's pcall-wrapped re-tile step.
function unfullscreenLua(addr) {
    return (
        'function()\n' +
        '  local prevW, cur = hl.get_active_window(), hl.get_cursor_pos()\n' +
        '  ' + dispatchGuardLua() + '\n' +
        '  local ok, err = pcall(function()\n' +
        fullscreenBodyLua('"address:' + addr + '"', '0') + '\n' +
        '  end)\n' +
        reportLua('un-fullscreen') + '\n' +
        restoreFocusLua('prevW', 'cur') + '\n' +
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
// are "auto", so a typo in omyview.json never freezes the picker.
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

// Share-time reminder border colour (docs/specs/2026-09-12-lock-design.md, addendum): only the
// `rgb(hhhhhh)` / `rgba(hhhhhhhh)` hex forms are accepted, on both sides — here in parseConfig,
// and again in lockSyncLua right before the value is interpolated into a Lua chunk (defense in
// depth: a config value could reach the builder through a path that never went through
// parseConfig, e.g. a future caller, and the value is untrusted text landing inside a Lua string
// literal).
var LOCK_BORDER_RE = /^rgba?\([0-9a-fA-F]{6}([0-9a-fA-F]{2})?\)$/

// ~/.config/omarchy/omyview.json → a fully-defaulted settings object. Every key has a default;
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

// Bump on ANY change to the observer callback's body (including which `kind` values it
// ignores). `_G.omyview_lock` is compositor Lua state that survives a shell restart, and the
// callback lives in a closure owned by the old subscription — `L.sub:is_active()` stays true
// across a restart, so without a version check the install's own idempotence guard
// (`if not (L.sub and L.sub:is_active())`) would keep the STALE callback forever; a shell
// restart alone could never deliver a behaviour change to a running compositor, only a
// `configreloaded` (which drops `_G` entirely) would.
// 3 (share-time reminder border, 2026-09-14 addendum): the callback body changed from calling
// `L.publish()` to calling `L.apply()` (reconcile every border rule's enabled state against the
// current sharing/exclusion state, THEN publish) — a running compositor whose callback still
// only publishes would never toggle a border added after it started, so the body change itself
// must force the stale callback out, the same as the `kind` filter did at version 2.
// 4 (share-state hysteresis, 2026-09-14 round 3): the callback body changed again — it no longer
// applies every edge. It keeps `L.sharing` as the raw counter but drives the borders and the
// state file from `L.effective`, a debounced view of it: a true edge applies at once and cancels
// any pending grace timer, a false edge only arms a `LOCK_SHARE_GRACE_MS` oneshot that turns the
// cue off if no true arrived meanwhile. A compositor still running the v3 callback would keep
// flapping the border rules twice a second (see LOCK_SHARE_GRACE_MS below), so the body change
// must force the stale callback out.
var LOCK_OBSERVER_VERSION = 4

// Grace period before a share that stopped signalling is treated as over. Hyprland's
// ScreenshareSession.cpp emits `screenshare.state(true, …)` on every successfully COPIED frame
// and `screenshare.state(false, …)` from a 500 ms timer that fires whenever no frame arrived for
// half a second — so a consumer that pulls frames irregularly (OBS on a mostly static screen)
// makes the compositor emit false/true pairs for the whole recording: measured 20 events in 30 s
// on 2026-09-14, every false run under ~1 s. Applying each edge toggled `border_size` (a border
// size change relayouts the workspace → windows visibly "resizing") and rewrote the state file
// twice a second. 3000 ms leaves headroom over the longest measured gap for a fully static
// screen. The trade-off is one-sided: too short means flicker, too long means the rim lingers a
// few seconds after the share really ended — cosmetic only, because the exclusion rules are
// always on and privacy never depends on this signal.
var LOCK_SHARE_GRACE_MS = 3000

// Install the compositor-side lock state: one table in _G, and the share observer that
// publishes 1/0 to $XDG_RUNTIME_DIR/omyview/share-state. No layer rule for the overview's own
// namespace: a `no_screen_share` layer renders as an opaque black rect over the whole layer box
// while mapped (ScreenshareFrame.cpp), so it would blank the entire shared screen whenever the
// overview is open — and toplevel export of an armed window is denied by Hyprland regardless
// (see lockSyncLua's per-workspace window rules), so the overview cannot leak armed pixels
// without it. Idempotent: re-running keeps the rules, the subscription and the share counter.
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
// `L.ensureDir()` runs on EVERY install, not only when `L.dir` is nil: `_G.omyview_lock` is
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
        '    local L = _G.omyview_lock\n' +
        '    if not L then L = { rules = {}, sharing = 0, effective = false, grace = nil, sub = nil, subVer = nil, dir = nil, borders = {}, borderCfg = nil }; _G.omyview_lock = L end\n' +
        // Mirrors how the exclusion table (`L.rules`) is always present: an observer re-install
        // after a shell restart can land on an `_G.omyview_lock` created by an OLDER omyview
        // build that predates the border addendum (so `L.borders` was never set at all, and the
        // `if not L` branch above is skipped because L already exists) -- this keeps that
        // observer's border handles (an empty table the first time, whatever it already holds
        // otherwise) instead of leaving `L.borders` nil until the next sync happens to set it.
        '    L.borders = L.borders or {}\n' +
        // `L.sharing` is the raw balanced counter; `L.effective` is the debounced view of it that
        // the border rules and the state file follow (see LOCK_SHARE_GRACE_MS). Seeded from the
        // counter — and only when unset — so an install landing on an `_G.omyview_lock` from a
        // pre-hysteresis build starts out agreeing with whatever is actually running, and a later
        // re-install never resets a live `false` grace decision back to `true`.
        '    if L.effective == nil then L.effective = L.sharing > 0 end\n' +
        '    function L.ensureDir()\n' +
        '      local base = os.getenv("XDG_RUNTIME_DIR"); if not base then error("XDG_RUNTIME_DIR unset") end\n' +
        '      local dir = base .. "/omyview"\n' +
        '      local probe = io.open(dir .. "/.omyview-probe", "w")\n' +
        '      if not probe then\n' +
        '        os.execute("mkdir -p \'" .. dir .. "\'")\n' +
        '        probe = io.open(dir .. "/.omyview-probe", "w")\n' +
        '        if not probe then error("runtime dir unavailable: " .. dir) end\n' +
        '      end\n' +
        '      probe:close(); os.remove(dir .. "/.omyview-probe")\n' +
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
        // L.reconcileBorders()/L.apply() are defined here — before the subVer check and the
        // observer subscription below, which calls L.apply() — so a fresh subscription's
        // callback always closes over fully-defined functions (never stale/partial ones from an
        // earlier install). L.reconcileBorders() toggles every border rule's enabled state
        // against the current sharing count and its exclusion rule's own state; every border
        // rule is created DISABLED by lockSyncLua and only ever toggled here. Each toggle is
        // guarded on its own (never letting one bad rule handle abort the rest); a handle whose
        // set_enabled throws while ENABLING is dropped from L.borders so the next sync recreates
        // it instead of retrying a dead handle. A failed DISABLE keeps the handle instead (rules
        // cannot be destroyed in this Hyprland Lua API, only disabled): dropping it there would
        // leave the rule stuck ENABLED and unreachable, and the next sync would create a second,
        // disabled rule under the same name that never undoes the first — a stale red frame with
        // no share running until a config reload. This mirrors lockSyncLua's own exclusion-rule
        // disable loop below, which never drops a handle on a failed set_enabled(false) either.
        // L.apply() runs the border reconcile BEFORE L.publish() — a publish failure (raised out
        // of L.apply()) must not leave the border rules untouched; reconciling first means it
        // always runs regardless of the publish outcome. lockSyncLua calls L.reconcileBorders()
        // directly, never L.apply(): publishing the share-state file is the observer/install's
        // job, not a rule sync's — see lockSyncLua below.
        // The reconcile is idempotent: a rule already in the wanted state is left alone. Every
        // set_enabled on a border rule costs a workspace relayout (border_size changes the tile
        // geometry), and this runs on every sync — arm/disarm, config change, every overview
        // open — so re-setting an already-correct rule is pure flicker. The is_enabled() read is
        // pcall'd too: a handle that throws on the read is "unknown", and unknown means set it.
        '    function L.reconcileBorders()\n' +
        '      for sel, b in pairs(L.borders or {}) do\n' +
        '        local r = L.rules[sel]\n' +
        '        local want = L.effective and r ~= nil and r:is_enabled()\n' +
        '        local iok, cur = pcall(function() return b:is_enabled() end)\n' +
        '        if (not iok) or cur ~= want then\n' +
        '          local tok = pcall(function() b:set_enabled(want) end)\n' +
        '          if not tok and want then L.borders[sel] = nil end\n' +
        '        end\n' +
        '      end\n' +
        '    end\n' +
        '    function L.apply()\n' +
        '      L.reconcileBorders()\n' +
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
        // bare Lua error inside the compositor rather than an omyview log line.
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
        '                if not gok then print("omyview: share grace timer failed: " .. tostring(gerr)) end\n' +
        '              end, { timeout = ' + LOCK_SHARE_GRACE_MS + ', type = "oneshot" })\n' +
        '            end)\n' +
        '            L.grace = tok and t or nil\n' +
        '            if not L.grace then L.effective = false; L.apply() end\n' +
        '          end\n' +
        '        end)\n' +
        '        if not sok then print("omyview: share observer failed: " .. tostring(serr)) end\n' +
        '      end)\n' +
        '    end\n' +
        '    local pok, perr = pcall(function()\n' +
        '      L.ensureDir()\n' +
        '      L.apply()\n' +
        '    end)\n' +
        '    if not pok then error(perr, 0) end\n' +
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
// `border` ({ color, size }) is the share-time reminder border (addendum, 2026-09-14):
// validated again here with LOCK_BORDER_RE (the value is interpolated into the chunk) and its
// size coerced to an integer 0..20, exactly like parseConfig — this builder must not trust that
// every caller already went through parseConfig. A second, disabled, named rule per armed
// selector (`omyview-lock-border-<sel>`) carries the border; it is only ever ENABLED by
// `L.reconcileBorders()` (called directly at the end of this chunk, and via `L.apply()` by the
// share observer and install), never here — this function only creates/keeps the rule disabled
// and, on a colour/size change, disables and drops every existing border rule so they are
// rebuilt against the new config on demand. This chunk calls `L.reconcileBorders()`, NOT
// `L.apply()`: `L.apply()` also republishes the share-state file, but a sync never changes
// `L.sharing` (only the observer does), so republishing here would be redundant and — being a
// filesystem operation — could fail for reasons that have nothing to do with rule reconciliation.
// Folding that failure into this chunk's `ok, err` would make "lock sync failed" notifications
// fire for a stale runtime directory even though every rule was reconciled correctly; skipping
// the publish keeps this chunk's report about rule reconciliation only, per the addendum.
function lockSyncLua(armed, border) {
    var sels = []
    for (var i = 0; i < (armed || []).length; i++) if (validLockSelector(armed[i])) sels.push('"' + armed[i] + '"')
    var b = border || {}
    var color = (typeof b.color === "string" && LOCK_BORDER_RE.test(b.color)) ? b.color : "rgb(ff4444)"
    var sizeNum = Number(b.size)
    var size = isFinite(sizeNum) ? Math.max(0, Math.min(20, Math.floor(sizeNum))) : 6
    return (
        'function()\n' +
        '  local ARMED = {' + sels.join(', ') + '}\n' +
        // `pair` is the same colour twice. Hyprland's parseBorderColorRule (WindowRule.cpp) sets
        // only the ACTIVE border colour from a single value and fills `inactive` only when the
        // string holds exactly two colour tokens and no `deg`; WindowRuleApplicator.cpp then
        // overrides the inactive colour only if `inactive` is present. A single value therefore
        // rims just the focused window — live-confirmed 2026-09-14, and the opposite of the
        // round-1 probe note. `color` stays the single configured value: it is what the user
        // configures, and what `L.borderCfg` compares (doubling is a rendering detail).
        '  local BORDER = { color = "' + color + '", pair = "' + color + ' ' + color + '", size = ' + size + ' }\n' +
        '  local L = _G.omyview_lock\n' +
        '  local ok, err = L ~= nil, "lock not installed"\n' +
        '  if L then\n' +
        '    local want = {}; for _, sel in ipairs(ARMED) do want[sel] = true end\n' +
        '    local failed = {}\n' +
        '    local function step(sel, f) local sok, serr = pcall(f); if not sok then failed[#failed + 1] = sel .. ": " .. tostring(serr) end end\n' +
        '    for sel in pairs(want) do\n' +
        '      step(sel, function()\n' +
        '        local r = L.rules[sel]\n' +
        '        if not r then\n' +
        '          r = hl.window_rule({ name = "omyview-lock-" .. sel, match = { workspace = sel }, no_screen_share = true, enabled = true })\n' +
        '          L.rules[sel] = r\n' +
        '        else\n' +
        '          local eok, eerr = pcall(function() r:set_enabled(true) end)\n' +
        '          if not eok then L.rules[sel] = nil; error(eerr, 0) end\n' +
        '        end\n' +
        '      end)\n' +
        '    end\n' +
        '    for sel, r in pairs(L.rules) do if not want[sel] then step(sel, function() r:set_enabled(false) end) end end\n' +
        '    L.borders = L.borders or {}\n' +
        '    local cfgKey = BORDER.color .. "/" .. BORDER.size\n' +
        // A dropped rule cannot be destroyed in this Hyprland Lua API (0.56.2) -- only disabled.
        // A colour/size change therefore disables every existing border rule and drops it from
        // L.borders (not from the compositor's rule table, which has no removal call); the loop
        // below re-creates one under the SAME name (`omyview-lock-border-<sel>`) per still-armed
        // selector. The stale, disabled, unreferenced rule handle is simply abandoned -- inert
        // and harmless, the same trade-off lockSyncLua already makes for a dead exclusion handle.
        '    if L.borderCfg ~= cfgKey then\n' +
        '      for _, br in pairs(L.borders) do pcall(function() br:set_enabled(false) end) end\n' +
        '      L.borders = {}\n' +
        '      L.borderCfg = cfgKey\n' +
        '    end\n' +
        '    for sel in pairs(want) do\n' +
        '      step(sel, function()\n' +
        '        if not L.borders[sel] then\n' +
        '          local spec = { name = "omyview-lock-border-" .. sel, match = { workspace = sel }, border_color = BORDER.pair, enabled = false }\n' +
        '          if BORDER.size > 0 then spec.border_size = BORDER.size end\n' +
        '          L.borders[sel] = hl.window_rule(spec)\n' +
        '        end\n' +
        '      end)\n' +
        '    end\n' +
        '    ok, err = #failed == 0, table.concat(failed, "; ")\n' +
        // pcall'd so an error inside L.reconcileBorders() (e.g. an _G.omyview_lock left by an
        // older build without the function at all) cannot kill the chunk before reportLua runs;
        // ok/err above already describes rule reconciliation and must not be touched by this.
        '    pcall(function() L.reconcileBorders() end)\n' +
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
