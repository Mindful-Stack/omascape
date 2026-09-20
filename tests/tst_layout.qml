import QtQuick
import QtTest
import "../logic.js" as Logic

TestCase {
    name: "Layout"

    readonly property var params: ({
        maxCols: 5, minCellW: 140, maxCellW: 380, cellInset: 6, cellSpacing: 8,
        rowSpacing: 12, headerH: 22, groupInset: 6, minTileW: 8, minTileH: 6, slotGapTolerance: 24
    })

    // The production spacing params after docs/specs/2026-09-20-proportional-spacing-design.md:
    // the gap is 8% of the cell, both edges carry one gap, and maxCellW is only a sanity cap.
    // `params` above stays on the pixel model on purpose — every fixture in this file pins
    // absolute x/y literals against it, and the ratio must not move them.
    readonly property var ratioParams: ({
        maxCols: 5, minCellW: 140, maxCellW: 800, cellInset: 3, cellSpacing: 4,
        rowSpacing: 8, headerH: 22, groupInset: 6, minTileW: 8, minTileH: 6, slotGapTolerance: 24,
        gapRatio: 0.08
    })

    // One monitor (eDP-1, aspect 1.6), five empty workspaces, no windows: the smallest input
    // that exercises every column. `availW` may be anything, including undefined.
    function fiveOn(availW, p) {
        var wss = []
        for (var i = 1; i <= 5; i++)
            wss.push({ id: i, monitorName: "eDP-1", focused: i === 1, occupied: false })
        return Logic.layout({ monitors: [edp()], workspaces: wss, windows: [],
                              focusedMonitorName: "eDP-1", availW: availW,
                              params: p === undefined ? ratioParams : p })
    }

    function withRatio(base, value) {
        var p = {}
        for (var k in base) p[k] = base[k]
        p.gapRatio = value
        return p
    }

    // Every box and group finite — the NaN floor (lore/knowledge/general/layout-and-sizing.md).
    function assertFinite(r, label) {
        verify(isFinite(r.canvasSize.w) && r.canvasSize.w > 0 && isFinite(r.canvasSize.h) && r.canvasSize.h > 0,
               label + ": canvas " + JSON.stringify(r.canvasSize))
        for (var i = 0; i < r.boxes.length; i++) {
            var b = r.boxes[i]
            verify(isFinite(b.x) && isFinite(b.y) && isFinite(b.w) && isFinite(b.h) && b.w > 0 && b.h > 0,
                   label + ": box " + b.workspaceId + " " + JSON.stringify([b.x, b.y, b.w, b.h]))
        }
        for (var g = 0; g < r.groups.length; g++) {
            var gr = r.groups[g]
            verify(isFinite(gr.x) && isFinite(gr.y) && isFinite(gr.w) && gr.w > 0 && isFinite(gr.h) && gr.h > 0,
                   label + ": group " + gr.monitorName + " " + JSON.stringify([gr.x, gr.y, gr.w, gr.h]))
        }
    }

    // Boxes sharing the first row's y ARE the first row; with five workspaces that is `cols`
    // whenever cols <= 5.
    function firstRowCount(r) {
        var y0 = r.boxes[0].y, n = 0
        for (var i = 0; i < r.boxes.length; i++) if (r.boxes[i].y === y0) n++
        return n
    }

    // Two monitors (so the group inset and header band are on), six workspaces on the first
    // so it wraps into a second sub-row, and the scratchpad shown: every vertical seam the
    // layout has. availW 2024 less the 2*6 inset is 2012 — cw 367, gap 29, no fit step, with
    // the default ratioParams; under the pixel `params` the same fixture is cw 380, gap 8, and
    // the wrap still happens.
    function multiWithScratchpad(p) {
        var wss = []
        for (var i = 1; i <= 6; i++) wss.push({ id: i, monitorName: "eDP-1", focused: i === 1, occupied: false })
        for (var j = 7; j <= 8; j++) wss.push({ id: j, monitorName: "HDMI-A-1", focused: false, occupied: false })
        wss.push({ id: Logic.SCRATCHPAD_ID, monitorName: "eDP-1", special: "scratchpad",
                   focused: false, occupied: true })
        return Logic.layout({ monitors: [edp(), hdmi()], workspaces: wss, windows: [],
                              focusedMonitorName: "eDP-1", availW: 2024,
                              params: p === undefined ? ratioParams : p })
    }

    // eDP-1: 2560x1600 @1.25 => 2048x1280 logical; 26px top bar reserved.
    function edp() {
        return { name: "eDP-1", x: 0, y: 0, width: 2560, height: 1600,
                 scale: 1.25, reserved: [0, 26, 0, 0], transform: 0 }
    }

    function hdmi() {
        return { name: "HDMI-A-1", x: 2560, y: 0, width: 1920, height: 1080,
                 scale: 1, reserved: [0, 26, 0, 0], transform: 0 }
    }

    function boxById(res, id) {
        for (var i = 0; i < res.boxes.length; i++)
            if (res.boxes[i].workspaceId === id) return res.boxes[i]
        return null
    }

    // A workspace bound to no monitor ("monitor": "?" in hyprctl) makes Quickshell hand the
    // plugin a placeholder monitor of that name with everything zeroed. Its logical size is
    // 0x0, and 0/0 is NaN: before this was guarded, that NaN aspect flowed into the cell
    // height, every box and group height in the layout, the canvas and finally the card, which
    // a Rectangle paints as nothing at all — the overview mapped its surface, took focus and
    // drew a scrim over an invisible card (found on a real desktop, 2026-09-18).
    function phantom() {
        return { name: "?", x: 0, y: 0, width: 0, height: 0, scale: 0, reserved: [0,0,0,0], transform: 0 }
    }
    function test_a_monitorless_workspace_never_yields_NaN_geometry() {
        var r = Logic.layout({ monitors:[edp(), phantom()],
            workspaces:[{id:1,monitorName:"eDP-1",focused:true,occupied:true},
                        {id:2,monitorName:"eDP-1",focused:false,occupied:false},
                        {id:6,monitorName:"?",focused:false,occupied:false}],
            windows:[], focusedMonitorName:"eDP-1", availW:1632, params:params })
        verify(isFinite(r.canvasSize.h), "canvas height must be finite, got " + r.canvasSize.h)
        verify(isFinite(r.canvasSize.w), "canvas width must be finite, got " + r.canvasSize.w)
        verify(isFinite(r.cell.h), "cell height must be finite, got " + r.cell.h)
        for (var i = 0; i < r.boxes.length; i++) {
            var b = r.boxes[i]
            verify(isFinite(b.h) && b.h > 0, "box " + b.workspaceId + " height " + b.h)
            verify(isFinite(b.y), "box " + b.workspaceId + " y " + b.y)
        }
        for (var g = 0; g < r.groups.length; g++)
            verify(isFinite(r.groups[g].h), "group " + r.groups[g].monitorName + " height " + r.groups[g].h)
    }

    // wide anchor: availW 1632 => cols 5, cw 320, ch 200 (eDP aspect 1.6)
    function test_cell_size_and_boxes_wide() {
        var r = Logic.layout({ monitors:[edp()],
            workspaces:[{id:1,monitorName:"eDP-1",focused:true,occupied:true},
                        {id:2,monitorName:"eDP-1",focused:false,occupied:false},
                        {id:3,monitorName:"eDP-1",focused:false,occupied:true}],
            windows:[], focusedMonitorName:"eDP-1", availW:1632, params:params })
        compare(r.cell.cols, 5); compare(r.cell.w, 320); compare(r.cell.h, 200)
        var b1=boxById(r,1), b2=boxById(r,2)
        compare(b1.x,0);   compare(b1.y,0)             // single monitor: no header band
        compare(b2.x,328)                              // 320 + 8 gap
        compare(r.canvasSize.w, 976)                   // 3*320 + 2*8
        compare(r.canvasSize.h, 200)                   // ch 200, no header
        compare(r.groups.length, 1); compare(r.groups[0].headerH, 0)
    }
    // narrow screen: fewer columns, never wider than availW
    function test_narrow_adaptive_cols_no_overflow() {
        var r = Logic.layout({ monitors:[edp()],
            workspaces:[{id:1,monitorName:"eDP-1",focused:true,occupied:true},
                        {id:2,monitorName:"eDP-1",focused:false,occupied:false},
                        {id:3,monitorName:"eDP-1",focused:false,occupied:false},
                        {id:4,monitorName:"eDP-1",focused:false,occupied:false}],
            windows:[], focusedMonitorName:"eDP-1", availW:600, params:params })
        compare(r.cell.cols, 4)                        // floor((600+8)/148)=4, capped at 5 (n/a)
        compare(r.canvasSize.w, 600)                    // full row: 4*144 + 3*8 = 600 = availW
    }
    // Hyprland only reports workspaces it has created; padding fills in the 1–0 keys' targets
    // as empty wells next to their numeric neighbours (nearest lower real id's monitor), keeps
    // real ones verbatim, and flags the synthetic ones.
    function test_pad_workspaces_fills_missing_ids_next_to_neighbours() {
        var real = [{id:1,monitorName:"eDP-1",focused:true,occupied:true},
                    {id:6,monitorName:"HDMI-A-1",focused:false,occupied:true}]
        var padded = Logic.padWorkspaces(real, 10, "eDP-1")
        compare(padded.length, 10); compare(real.length, 2)          // input untouched
        var byId = {}; for (var i = 0; i < padded.length; i++) byId[padded[i].id] = padded[i]
        for (var id = 2; id <= 5; id++) compare(byId[id].monitorName, "eDP-1", "ws " + id + " follows 1")
        for (var id2 = 7; id2 <= 10; id2++) compare(byId[id2].monitorName, "HDMI-A-1", "ws " + id2 + " follows 6")
        verify(byId[10].synthetic && !byId[10].occupied && !byId[10].focused)
        verify(!byId[1].synthetic && !byId[6].synthetic)
        var r = Logic.layout({ monitors:[edp(), hdmi()], workspaces: padded,
            windows:[], focusedMonitorName:"eDP-1", availW:1632, params:params })
        compare(r.boxes.length, 10)
        var ids = []; for (var b = 0; b < r.boxes.length; b++) ids.push(r.boxes[b].workspaceId)
        compare(ids, [1,2,3,4,5,6,7,8,9,10])
        compare(boxById(r, 10).occupied, false)
        // a gap below the lowest real id leans on the nearest higher one; with no real
        // workspaces at all the focused monitor hosts everything; off switch synthesizes nothing
        var high = Logic.padWorkspaces([{id:4,monitorName:"HDMI-A-1",focused:true,occupied:true}], 4, "eDP-1")
        for (var k = 0; k < high.length; k++) compare(high[k].monitorName, "HDMI-A-1")
        compare(Logic.padWorkspaces([], 3, "eDP-1")[0].monitorName, "eDP-1")
        compare(Logic.padWorkspaces(real, 0, "eDP-1").length, 2)
        compare(Logic.padWorkspaces([], 3, "").length, 0)
    }
    // Review finding: synthetic ids must not reorder groups. Real 2 on eDP-1 and 6 on HDMI-A-1,
    // padded to 10, laid out with either monitor focused — same order, same geometry.
    function test_padded_layout_is_focus_invariant() {
        function lay(focusedMon) {
            var real = [{id:2,monitorName:"eDP-1",focused:focusedMon==="eDP-1",occupied:true},
                        {id:6,monitorName:"HDMI-A-1",focused:focusedMon==="HDMI-A-1",occupied:true}]
            return Logic.layout({ monitors:[edp(),hdmi()],
                workspaces: Logic.padWorkspaces(real, 10, focusedMon),
                windows:[], focusedMonitorName:focusedMon, availW:1632, params:params })
        }
        var a = lay("eDP-1"), b = lay("HDMI-A-1")
        compare(a.groups[0].monitorName, "eDP-1"); compare(b.groups[0].monitorName, "eDP-1")
        compare(a.boxes.length, 10); compare(b.boxes.length, 10)
        for (var i = 0; i < a.boxes.length; i++) {
            var x = a.boxes[i], y = b.boxes[i]
            compare([x.workspaceId, x.monitorName, x.x, x.y, x.w, x.h],
                    [y.workspaceId, y.monitorName, y.x, y.y, y.w, y.h], "box " + i)
        }
        compare(a.canvasSize, b.canvasSize)
        // ws 1 has no lower neighbour: it leans on 2 (eDP-1) whoever is focused
        compare(boxById(b, 1).monitorName, "eDP-1")
    }
    // A group made only of synthetic wells still sorts deterministically (by its lowest id).
    function test_order_falls_back_to_synthetic_ids_for_synthetic_only_group() {
        var wss = [{id:3,monitorName:"eDP-1",focused:true,occupied:true},
                   {id:1,monitorName:"HDMI-A-1",focused:false,occupied:false,synthetic:true}]
        var r = Logic.layout({ monitors:[edp(),hdmi()], workspaces: wss,
            windows:[], focusedMonitorName:"eDP-1", availW:1632, params:params })
        compare(r.groups[0].monitorName, "HDMI-A-1"); compare(r.groups[1].monitorName, "eDP-1")
    }
    // missing/invalid availW must not corrupt geometry into NaN — degraded but usable
    function test_missing_availw_yields_safe_default() {
        var r = Logic.layout({ monitors:[edp()],
            workspaces:[{id:1,monitorName:"eDP-1",focused:true,occupied:true}],
            windows:[], focusedMonitorName:"eDP-1", params:params })
        compare(r.cell.w, 140); compare(r.cell.cols, 5)
        verify(isFinite(r.canvasSize.w)); verify(isFinite(r.canvasSize.h))
    }
    // degenerate: below minCellW => 1 column, cell clamped up to minCellW
    function test_degenerate_narrow_clamps_to_min() {
        var r = Logic.layout({ monitors:[edp()],
            workspaces:[{id:1,monitorName:"eDP-1",focused:true,occupied:true}],
            windows:[], focusedMonitorName:"eDP-1", availW:100, params:params })
        compare(r.cell.cols, 1); compare(r.cell.w, 140)   // clamped up; may exceed availW (2-D scroll)
    }
    // >cols workspaces wrap into sub-rows
    function test_wrap_into_subrows() {
        var wss=[]; for (var i=1;i<=7;i++) wss.push({id:i,monitorName:"eDP-1",focused:i===1,occupied:true})
        var r = Logic.layout({ monitors:[edp()], workspaces:wss, windows:[],
            focusedMonitorName:"eDP-1", availW:1632, params:params })
        compare(boxById(r,5).y, 0)                     // first sub-row (no header: one monitor)
        compare(boxById(r,6).x, 0)                     // second sub-row, first column
        compare(boxById(r,6).y, 212)                   // ch200 + rowSpacing12
        compare(r.canvasSize.h, 412)                   // 200 + 12 + 200
    }
    // two monitors stack, lowest workspace id first; each group is inset with a chip band and carries
    // its full bounds, so the view can put a backdrop behind the focused one
    function test_two_monitor_groups() {
        var r = Logic.layout({ monitors:[edp(),hdmi()],
            workspaces:[{id:1,monitorName:"eDP-1",focused:true,occupied:true},
                        {id:6,monitorName:"HDMI-A-1",focused:false,occupied:true}],
            windows:[], focusedMonitorName:"eDP-1", availW:1632, params:params })
        compare(r.groups.length, 2)
        compare(r.groups[0].monitorName, "eDP-1"); verify(r.groups[0].focused)
        compare(r.groups[0].headerH, 22); compare(r.groups[0].inset, 6)
        // availW 1632 - 2*6 inset = 1620 → cols 5, cw floor((1620-32)/5) = 317, ch round(317/1.6) = 198
        compare(r.cell.w, 317); compare(r.cell.h, 198)
        compare(r.groups[0].y, 0); compare(r.groups[0].h, 232)   // 6 + 22 + 198 + 6
        compare(r.groups[1].y, 244)                              // 232 + rowSpacing 12
        compare(boxById(r,1).x, 6); compare(boxById(r,1).y, 28)  // inset + header
        compare(r.groups[0].w, 329)                              // 317 + 2*6
        // the HDMI group uses its own 16:9 shape: ch round(317/1.778) = 178, group 6+22+178+6
        compare(boxById(r,6).h, 178); compare(r.groups[1].h, 212)
        compare(r.canvasSize.w, 329); compare(r.canvasSize.h, 456)   // 244 + 212
        verify(boxById(r,1).y < boxById(r,6).y)
    }
    // Group order is fixed by workspace numbers: the group holding the lowest id comes first,
    // so the picker reads 1..10 top to bottom whichever screen has focus or where the screens
    // sit physically. The focused group is flagged, not moved.
    function test_group_order_follows_lowest_workspace_id_not_focus() {
        var r = Logic.layout({ monitors:[edp(),hdmi()],
            workspaces:[{id:1,monitorName:"eDP-1",focused:false,occupied:true},
                        {id:6,monitorName:"HDMI-A-1",focused:true,occupied:true}],
            windows:[], focusedMonitorName:"HDMI-A-1", availW:1632, params:params })
        compare(r.groups[0].monitorName, "eDP-1"); verify(!r.groups[0].focused)
        compare(r.groups[1].monitorName, "HDMI-A-1"); verify(r.groups[1].focused)
        // the external screen owns 1..5 here: it comes first even though it is listed second
        var r2 = Logic.layout({ monitors:[edp(), hdmi()],
            workspaces:[{id:6,monitorName:"eDP-1",focused:true,occupied:true},
                        {id:1,monitorName:"HDMI-A-1",focused:false,occupied:true},
                        {id:9,monitorName:"HDMI-A-1",focused:false,occupied:false}],
            windows:[], focusedMonitorName:"eDP-1", availW:1632, params:params })
        compare(r2.groups[0].monitorName, "HDMI-A-1"); compare(r2.groups[1].monitorName, "eDP-1")
    }
    // `workspaces` config: integer count, floored, never negative, default 10 on anything odd
    function test_parse_config_workspaces() {
        compare(Logic.parseConfig('{"workspaces": 6}').workspaces, 6)
        compare(Logic.parseConfig('{"workspaces": 0}').workspaces, 0)
        compare(Logic.parseConfig('{"workspaces": 7.9}').workspaces, 7)
        compare(Logic.parseConfig('{"workspaces": -3}').workspaces, 0)
        compare(Logic.parseConfig('{"workspaces": "ten"}').workspaces, 10)
        compare(Logic.parseConfig('').workspaces, 10)
        compare(Logic.parseConfig('{"workspaces": 4}').motion, "auto")   // other keys keep defaults
    }
    // Activation policy (docs/specs/2026-09-18-activate-select-design.md).
    // Distinguishes: a key that is read raw (any string becoming the policy) or not read at all
    // (always "enter"). The unknown-string and wrong-type cases are the ones that matter: a
    // malformed config must fall back, never change behaviour.
    function test_parse_config_activate() {
        compare(Logic.parseConfig('').activate, "enter", "absent = today's behaviour")
        compare(Logic.parseConfig('{"activate": "enter"}').activate, "enter")
        compare(Logic.parseConfig('{"activate": "select"}').activate, "select")
        compare(Logic.parseConfig('{"activate": "Select"}').activate, "enter", "case-sensitive")
        compare(Logic.parseConfig('{"activate": "jump"}').activate, "enter", "unknown falls back")
        compare(Logic.parseConfig('{"activate": true}').activate, "enter", "wrong type falls back")
        compare(Logic.parseConfig('{"activate": "select"}').motion, "auto", "other keys keep defaults")
    }
    // Share-time reminder border (docs/specs/2026-09-12-lock-design.md, addendum): `lockBorder`
    // accepts only the rgb(hhhhhh) / rgba(hhhhhhhh) hex forms, `lockBorderSize` is an integer
    // 0..20 defaulting to 6. Anything else falls back to the default, including an
    // injection-shaped string trying to break out of the Lua string the builder puts it in.
    function test_parse_config_lock_border() {
        compare(Logic.parseConfig('{"lockBorder": "rgb(ff4444)"}').lockBorder, "rgb(ff4444)")
        compare(Logic.parseConfig('{"lockBorder": "rgba(ff444488)"}').lockBorder, "rgba(ff444488)")
        compare(Logic.parseConfig('{"lockBorder": "red"}').lockBorder, "rgb(ff4444)")
        compare(Logic.parseConfig('{"lockBorder": "rgb(zz)"}').lockBorder, "rgb(ff4444)")
        compare(Logic.parseConfig('{"lockBorder": "rgb(ff4444)\\"); error(\\"x"}').lockBorder, "rgb(ff4444)")
        compare(Logic.parseConfig('').lockBorder, "rgb(ff4444)")
        compare(Logic.parseConfig('{"lockBorderSize": 10}').lockBorderSize, 10)
        compare(Logic.parseConfig('{"lockBorderSize": 0}').lockBorderSize, 0)
        compare(Logic.parseConfig('{"lockBorderSize": 25}').lockBorderSize, 20)
        compare(Logic.parseConfig('{"lockBorderSize": -3}').lockBorderSize, 0)
        compare(Logic.parseConfig('{"lockBorderSize": "six"}').lockBorderSize, 6)
        compare(Logic.parseConfig('').lockBorderSize, 6)
    }
    // a single group gets neither the header band nor the inset
    function test_single_group_has_no_inset() {
        var r = Logic.layout({ monitors:[edp()],
            workspaces:[{id:1,monitorName:"eDP-1",focused:true,occupied:true}],
            windows:[], focusedMonitorName:"eDP-1", availW:1632, params:params })
        compare(r.groups[0].inset, 0); compare(r.groups[0].x, 0); compare(boxById(r,1).x, 0)
        compare(r.groups[0].w, 320); compare(r.groups[0].h, 200)
    }
    // A monitor without workspaces forms no group, so it must not bring the header band with it.
    function test_header_band_needs_two_monitors_with_workspaces() {
        var r = Logic.layout({ monitors:[edp(),hdmi()],
            workspaces:[{id:1,monitorName:"eDP-1",focused:true,occupied:true}],
            windows:[], focusedMonitorName:"eDP-1", availW:1632, params:params })
        compare(r.groups.length, 1)
        compare(r.groups[0].headerH, 0); compare(boxById(r,1).y, 0)
    }

    function test_skips_negative_workspace_ids() {
        var input = {
            monitors: [edp()],
            workspaces: [
                { id: 1,  monitorName: "eDP-1", focused: true,  occupied: true },
                { id: -99, monitorName: "eDP-1", focused: false, occupied: false }
            ],
            windows: [], focusedMonitorName: "eDP-1", availW: 1632, params: params
        }
        var r = Logic.layout(input)
        compare(r.boxes.length, 1, "special/lock workspace id<0 excluded")
    }

    function tilesByAddr(res, addr) {
        for (var i = 0; i < res.tiles.length; i++)
            if (res.tiles[i].address === addr) return res.tiles[i]
        return null
    }

    // A normal window fully inside the usable area must land entirely within its box's
    // mini-map inset — never bleeding outside (the exact failure of the old formula that
    // subtracted the reserved origin but scaled against the whole monitor).
    function test_tile_stays_within_minimap_fractional_scale() {
        var input = {
            monitors: [edp()],   // scale 1.25, reserved top 26
            workspaces: [{ id: 1, monitorName: "eDP-1", focused: true, occupied: true }],
            windows: [{ address: "0xA", cls: "foot", ax: 100, ay: 200,
                        sw: 800, sh: 600, workspaceId: 1, floating: false, fullscreen: false }],
            focusedMonitorName: "eDP-1", availW: 1632, params: params
        }
        var r = Logic.layout(input)
        var b = boxById(r, 1), t = tilesByAddr(r, "0xA")
        verify(t !== null)
        var lo = 0.5
        verify(t.x >= b.x + params.cellInset - lo)
        verify(t.y >= b.y + params.cellInset - lo)
        verify(t.x + t.w <= b.x + b.w - params.cellInset + lo)
        verify(t.y + t.h <= b.y + b.h - params.cellInset + lo)
    }

    // A cell takes its own monitor's aspect, so the only mismatch left between the mini-map
    // (box minus cellInset) and the usable rect (monitor minus reserved) comes from reserved
    // space. A 300 px top reservation makes the usable rect 2048x980 (aspect 2.09) inside a
    // 308x188 mini-map (aspect 1.64): width-limited, letterboxed on height.
    function test_unequal_aspect_letterboxes_on_short_axis() {
        var mon = edp(); mon.reserved = [0, 300, 0, 0]
        var input = {
            monitors: [mon],
            workspaces: [{ id: 1, monitorName: "eDP-1", focused: true, occupied: true }],
            // fullscreen window fills the usable rect exactly, so its tile == the fitted R
            windows: [{ address: "0xF", cls: "x", ax: 0, ay: 300, sw: 2048, sh: 980,
                        workspaceId: 1, floating: false, fullscreen: true }],
            focusedMonitorName: "eDP-1", availW: 1632, params: params
        }
        var r = Logic.layout(input)
        var b = boxById(r, 1), t = tilesByAddr(r, "0xF")
        compare(b.w, 320); compare(b.h, 200)
        // width-limited: fills mini-map width (box.w-2*inset = 308), centered vertically
        // inside mmH (box.h-2*inset = 188)
        fuzzyCompare(t.w, 308, 0.5, "fills mini-map width")
        verify(t.h < 188 - 1)                       // letterboxed on height
        verify(t.y > b.y + params.cellInset + 0.5)  // vertically centered, not flush to inset
    }

    // 0xF is fullscreen-flagged and lone on its workspace: layout() finds no tiled neighbours,
    // so its slot is the whole usable rect and _tileRect's slot branch fills R. 0xN is
    // unflagged and falls to the geometry heuristic instead; it pokes above the usable top and
    // is NOT the full output (sw 1000, sh 1200), so the heuristic clips it rather than filling.
    function test_fullscreen_fills_but_nonfullscreen_clips() {
        function run(w) {
            return Logic.layout({ monitors: [edp()],
                workspaces: [{ id: 1, monitorName: "eDP-1", focused: true, occupied: true }],
                windows: [w], focusedMonitorName: "eDP-1", availW: 1632, params: params })
        }
        var full = tilesByAddr(run({ address: "0xF", cls: "x", ax: 0, ay: 0,
            sw: 2048, sh: 1280, workspaceId: 1, floating: false, fullscreen: true }), "0xF")
        // ay:0 is above the usable top (R.y=26) => clipped; not full output => not auto-full
        var norm = tilesByAddr(run({ address: "0xN", cls: "x", ax: 0, ay: 0,
            sw: 1000, sh: 1200, workspaceId: 1, floating: false, fullscreen: false }), "0xN")
        // fullscreen fills the height-limited mini-map exactly (mmH = 188)
        fuzzyCompare(full.h, 188, 0.5, "fullscreen fills limiting axis")
        // clipped window is shorter than the full fill, but shares the usable-top line
        verify(norm.h < full.h - 1)
        fuzzyCompare(norm.y, full.y, 0.5, "clip starts at usable top, not in the bar band")
    }

    // A window entirely left of the monitor has no intersection with R => no tile.
    function test_offscreen_window_yields_no_tile() {
        var r = Logic.layout({ monitors: [edp()],
            workspaces: [{ id: 1, monitorName: "eDP-1", focused: true, occupied: true }],
            windows: [{ address: "0xOff", cls: "x", ax: -500, ay: 100, sw: 200, sh: 200,
                        workspaceId: 1, floating: false, fullscreen: false }],
            focusedMonitorName: "eDP-1", availW: 1632, params: params })
        compare(tilesByAddr(r, "0xOff"), null, "off-usable window is skipped")
    }

    // A hairline window is clamped to the minimum visible size.
    function test_min_size_clamp() {
        var r = Logic.layout({ monitors: [edp()],
            workspaces: [{ id: 1, monitorName: "eDP-1", focused: true, occupied: true }],
            windows: [{ address: "0xTiny", cls: "x", ax: 100, ay: 100, sw: 2, sh: 2,
                        workspaceId: 1, floating: true, fullscreen: false }],
            focusedMonitorName: "eDP-1", availW: 1632, params: params })
        var t = tilesByAddr(r, "0xTiny")
        compare(t.w, params.minTileW); compare(t.h, params.minTileH)
    }

    function test_hit_workspace() {
        // two monitors so the header band exists (it must be a dead zone for hits)
        var r = Logic.layout({ monitors: [edp(), hdmi()],
            workspaces: [
                { id: 1, monitorName: "eDP-1", focused: true,  occupied: true },
                { id: 2, monitorName: "eDP-1", focused: false, occupied: false },
                { id: 6, monitorName: "HDMI-A-1", focused: false, occupied: false }
            ], windows: [], focusedMonitorName: "eDP-1", availW: 1632, params: params })
        var b2 = boxById(r, 2)
        // centre of box 2 => ws 2 (cell is 320x200)
        compare(Logic.hitWorkspace(r.boxes, b2.x + 160, b2.y + 100), 2)
        // the gap between box 1 and box 2 (x in 320..328) => null
        compare(Logic.hitWorkspace(r.boxes, 324, b2.y + 100), null)
        // above the cells, in the header band (y < headerH 22) => null
        compare(Logic.hitWorkspace(r.boxes, 10, 4), null)
    }

    function test_diff_by_address() {
        var prev = ["0xA", "0xB"]
        var next = [{ address: "0xB", x: 1, y: 1, w: 1, h: 1 },
                    { address: "0xC", x: 2, y: 2, w: 2, h: 2 }]
        var d = Logic.diffByAddress(prev, next)
        compare(d.adds.length, 1);    compare(d.adds[0].address, "0xC")
        compare(d.updates.length, 1); compare(d.updates[0].address, "0xB")
        compare(d.removes.length, 1); compare(d.removes[0], "0xA")
    }

    // This window is fullscreen-FLAGGED but reports small/offset geometry (500,400,300x200),
    // nowhere near the output. Being flagged and lone on its workspace, layout() gives it a
    // slot (the whole usable rect, no tiled neighbours to recover from), so _tileRect takes
    // the slot branch and fills R regardless of the window's own geometry — the geometry
    // heuristic, which would clip this rect to a tiny ~21px-wide tile, is never consulted.
    function test_fullscreen_flag_fills_R_even_when_geometry_small() {
        var r = Logic.layout({ monitors:[edp()],
            workspaces:[{id:1,monitorName:"eDP-1",focused:true,occupied:true}],
            windows:[{address:"0xFS",cls:"x",ax:500,ay:400,sw:300,sh:200,
                      workspaceId:1,floating:false,fullscreen:true}],
            focusedMonitorName:"eDP-1", availW:1632, params:params })
        var t = tilesByAddr(r,"0xFS")
        verify(t !== null)
        fuzzyCompare(t.h, 188, 0.5, "fullscreen fills R height = box.h-2*inset")
        verify(t.w > 100)
    }

    // Distinguishes: a placement that conflates `layer` with `fullscreen`, or that loses one of
    // the three fullscreen slot branches. One workspace, three windows: a tiled fullscreen one
    // whose slot is recoverable from its neighbour, that neighbour, and a floating window. Every
    // row must keep its own pair of values — no fixture before this one had all three at once.
    function test_placement_keeps_layer_and_fullscreen_independent() {
        var r = Logic.layout({ monitors: [edp()],
            workspaces: [{ id: 1, monitorName: "eDP-1", focused: true, occupied: true }],
            windows: [
                // fullscreen, tiled: recoverSlot must find the left half from the right-half neighbour
                { address: "0xF", workspaceId: 1, ax: 0, ay: 26, sw: 2048, sh: 1254,
                  floating: false, fullscreen: 2, cls: "full", title: "full" },
                { address: "0xR", workspaceId: 1, ax: 1024, ay: 26, sw: 1024, sh: 1254,
                  floating: false, fullscreen: 0, cls: "right", title: "right" },
                { address: "0xFloat", workspaceId: 1, ax: 400, ay: 300, sw: 300, sh: 200,
                  floating: true, fullscreen: 0, cls: "floaty", title: "floaty" }
            ],
            focusedMonitorName: "eDP-1", availW: 1632, params: params })
        function row(a) {
            for (var i = 0; i < r.tiles.length; i++) if (r.tiles[i].address === a) return r.tiles[i]
            fail("no tile row for " + a); return null
        }
        var f = row("0xF"), rt = row("0xR"), fl = row("0xFloat")
        compare(f.fullscreen, 2, "fullscreen mode survives")
        compare(f.layer, 1, "a RECOVERABLE fullscreen window stays on the tiled layer, not the backdrop")
        compare(rt.fullscreen, 0); compare(rt.layer, 1)
        compare(fl.fullscreen, 0); compare(fl.layer, 2, "floating stays layer 2")
        // The recovered slot is the LEFT half: the fullscreen tile must not cover its neighbour.
        verify(f.x + f.w <= rt.x + 1, "recovered slot must not overlap the neighbour it was recovered from")
    }

    // Pins the min-size clamp's position clamp: a hairline window near the far edge of the
    // usable area, once widened to minTileW, must not spill past the cell's mini-map inset.
    function test_min_clamp_stays_within_minimap_at_edge() {
        var r = Logic.layout({ monitors: [edp()],
            workspaces: [{ id: 1, monitorName: "eDP-1", focused: true, occupied: true }],
            windows: [{ address: "0xEdge", cls: "x", ax: 2046, ay: 100, sw: 2, sh: 2,
                        workspaceId: 1, floating: true, fullscreen: false }],
            focusedMonitorName: "eDP-1", availW: 1632, params: params })
        var b = boxById(r, 1), t = tilesByAddr(r, "0xEdge")
        verify(t !== null)
        compare(t.w, params.minTileW)                                // min-clamped
        verify(t.x + t.w <= b.x + b.w - params.cellInset + 0.01)      // stays in the inset
    }

    // dropToWindowPos is the inverse of tile placement: a floating window at real (ax,ay),
    // once mapped to its tile and then mapped back from that tile's top-left, must land at
    // (ax,ay) again (within rounding). Fails if the reverse math drifts from _tileRect.
    function test_drop_to_window_pos_roundtrip() {
        var win = { address:"0xF", cls:"x", ax:600, ay:500, sw:400, sh:300,
                    workspaceId:1, floating:true, fullscreen:false }
        var r = Logic.layout({ monitors:[edp()],
            workspaces:[{id:1,monitorName:"eDP-1",focused:true,occupied:true}],
            windows:[win], focusedMonitorName:"eDP-1", availW:1632, params:params })
        var b = boxById(r,1), t = tilesByAddr(r,"0xF")
        var back = Logic.dropToWindowPos(t.x, t.y, b, edp(), params)
        fuzzyCompare(back.x, 600, 1.5, "recovers real x")
        fuzzyCompare(back.y, 500, 1.5, "recovers real y")
    }
    // Never emit a negative coord (Hyprland reads -1 as "preserve axis"; negatives fling
    // the window off-screen). A drop above/left of the mini-map content clamps to >= 0.
    function test_drop_to_window_pos_clamps_nonnegative() {
        var r = Logic.layout({ monitors:[edp()],
            workspaces:[{id:1,monitorName:"eDP-1",focused:true,occupied:true}],
            windows:[], focusedMonitorName:"eDP-1", availW:1632, params:params })
        var b = boxById(r,1)
        var back = Logic.dropToWindowPos(b.x - 50, b.y - 50, b, edp(), params) // above-left of cell
        verify(back.x >= 0); verify(back.y >= 0)
    }

    function indexOfWs(r, id) {
        for (var i = 0; i < r.boxes.length; i++) if (r.boxes[i].workspaceId === id) return i
        return -1
    }
    // 10 workspaces => two rows of 5. Arrow nav must move by ROW vertically and by column
    // horizontally — Down on ws3 lands on ws8 (the cell directly below), not ws4.
    function test_arrow_nav_2d_grid() {
        var wss = []; for (var i = 1; i <= 10; i++) wss.push({ id:i, monitorName:"eDP-1", focused:i===1, occupied:true })
        var r = Logic.layout({ monitors:[edp()], workspaces:wss, windows:[],
                               focusedMonitorName:"eDP-1", availW:1632, params:params })
        var i3 = indexOfWs(r, 3)
        // Down from 3 -> 8 (directly below); Up from there -> back to 3
        var down = Logic.navigate(r.boxes, i3, "down")
        compare(r.boxes[down].workspaceId, 8)
        compare(r.boxes[Logic.navigate(r.boxes, down, "up")].workspaceId, 3)
        // Right/Left stay in the row
        compare(r.boxes[Logic.navigate(r.boxes, i3, "right")].workspaceId, 4)
        compare(r.boxes[Logic.navigate(r.boxes, i3, "left")].workspaceId, 2)
        // End of row: Right from ws5 has no box to its right -> unchanged
        var i5 = indexOfWs(r, 5)
        compare(Logic.navigate(r.boxes, i5, "right"), i5)
        // Down from ws10 (bottom row) -> no box below -> unchanged
        var i10 = indexOfWs(r, 10)
        compare(Logic.navigate(r.boxes, i10, "down"), i10)
    }
    function test_drop_keeps_entire_window_in_usable_bounds() {
        var mon=edp(); mon.y=1440
        var box={x:0,y:22,w:320,h:200}
        var p=Logic.dropToWindowPos(319,221,box,mon,params,{sw:600,sh:400})
        compare(p.x,1448)
        compare(p.y,2320)
        p=Logic.dropToWindowPos(-100,-100,box,mon,params,{sw:600,sh:400})
        compare(p.x,0); compare(p.y,1466)
    }
    function test_edge_scroll_is_bounded_and_proportional() {
        compare(Logic.edgeScrollDelta(200,400,100,1000,16),0)
        verify(Logic.edgeScrollDelta(399,400,100,1000,16)>0)
        verify(Logic.edgeScrollDelta(1,400,100,1000,16)<0)
        compare(Logic.edgeScrollDelta(0,400,0,1000,16),0)
        compare(Logic.edgeScrollDelta(400,400,599,1000,16),1)
        compare(Logic.edgeScrollDelta(400,400,0,300,16),0)
    }

    // dropSide mirrors dwindle's smart-split rule (slope of point-from-centre vs aspect), so
    // the drag preview shows the half the compositor will actually split into.
    function test_drop_side_follows_smart_split_rule() {
        var wide = { x: 0, y: 0, w: 400, h: 200 }
        compare(Logic.dropSide(wide, 20, 100), "left")
        compare(Logic.dropSide(wide, 380, 100), "right")
        compare(Logic.dropSide(wide, 200, 10), "top")
        compare(Logic.dropSide(wide, 200, 190), "bottom")
        compare(Logic.dropSide(wide, 380, 150), "right")    // shallow angle wins near a corner
        compare(Logic.dropSide(wide, 250, 190), "bottom")   // steep angle wins near a corner
        var tall = { x: 0, y: 0, w: 200, h: 400 }
        compare(Logic.dropSide(tall, 100, 380), "bottom")
        compare(Logic.dropSide(tall, 190, 220), "right")
        compare(Logic.dropSide(tall, 100, 200), "top")      // exact centre: NaN slope → top, like the C++
    }
    function test_rect_distance_is_zero_inside_and_grows_outside() {
        var r = { x: 10, y: 10, w: 100, h: 50 }
        compare(Logic.rectDistanceSq(r, 50, 30), 0)
        compare(Logic.rectDistanceSq(r, 0, 30), 100)
        compare(Logic.rectDistanceSq(r, 120, 70), 200)
    }
    // The drop plan is what the preview highlights and what a release does. A drop back onto
    // the window's own slot, or a lone tiled window dropped inside its own workspace, plans
    // nothing; otherwise the nearest candidate anchors and the side follows the smart-split rule.
    function test_tiled_drop_plan_shares_eligibility_between_preview_and_release() {
        var own = { x: 0, y: 0, w: 100, h: 100 }
        var other = { x: 200, y: 0, w: 100, h: 100, address: "0xb" }
        compare(Logic.tiledDropPlan([other], true, own, 50, 50), null, "own slot: nothing")
        compare(Logic.tiledDropPlan([other], true, own, 100, 100), null, "own slot edge: nothing")
        compare(Logic.tiledDropPlan([], true, own, 150, 50), null, "lone window in own workspace: nothing")
        var plan = Logic.tiledDropPlan([other], true, own, 150, 50)
        compare(plan.anchor, "0xb", "nearest tiled tile anchors even from the gap")
        compare(plan.side, "left")
        compare(Logic.tiledDropPlan([other], false, null, 290, 50).side, "right")
        var empty = Logic.tiledDropPlan([], false, null, 150, 50)
        compare(empty.anchor, "", "empty destination: insert without an anchor")
        compare(empty.side, "")
        // Ties go to the later (top-most) candidate.
        var twin = { x: 200, y: 0, w: 100, h: 100, address: "0xc" }
        compare(Logic.tiledDropPlan([other, twin], false, null, 250, 50).anchor, "0xc")
    }
    // The atomic Lua chunk must replay a native drop in order: float → (move) → measure the
    // anchor → cursor → un-float, with smart_split forced on and the cursor restored, and never
    // embed NaN/undefined. The cursor point is derived from the anchor's geometry read AFTER the
    // float (detaching the window re-lays out the workspace), on the requested side.
    function test_tiled_insert_lua_replays_native_drop() {
        var lua = Logic.tiledInsertLua("0xabc", 3, { anchor: "0xdef", side: "bottom", x: 512.6, y: 1800.2 })
        verify(lua.indexOf('address:0xabc') >= 0)
        verify(lua.indexOf('"address:0xdef"') >= 0)
        verify(lua.indexOf('smart_split = true') >= 0)
        verify(lua.indexOf('workspace = "3"') >= 0)
        verify(lua.indexOf('local x, y = 513, 1800') >= 0, "fallback point when there is no anchor")
        verify(lua.indexOf('== "bottom" then y = a.at.y + a.size.y') >= 0, "bottom edge of the anchor")
        verify(lua.indexOf('hl.get_cursor_pos()') >= 0)
        verify(lua.indexOf('NaN') < 0 && lua.indexOf('undefined') < 0)
        var firstFloat = lua.indexOf('window.float(')   // the layout-guard fallback move precedes it by design
        var order = [firstFloat, lua.indexOf('window.move(', firstFloat),
                     lua.indexOf('hl.get_window(anchorSel)'), lua.indexOf('cursor.move(', firstFloat),
                     lua.lastIndexOf('window.float(')]
        for (var i = 1; i < order.length; i++) verify(order[i] > order[i - 1], "step order " + i)
        verify(lua.lastIndexOf('smart_split = smart') > lua.lastIndexOf('window.float('), "config restored after re-tile")
        var none = Logic.tiledInsertLua("0xabc", 2, { anchor: "", side: "", x: 10, y: 20 })
        verify(none.indexOf('local anchorSel = nil') >= 0, "no anchor: plain fallback point")
        verify(none.indexOf('local x, y = 10, 20') >= 0)
        var bad = Logic.tiledInsertLua("0xabc", 2, { anchor: "0xdef", side: "sideways", x: 1, y: 2 })
        verify(bad.indexOf('sideways') < 0, "unknown side falls back to the anchor centre")
    }

    // The insert chunk strips fullscreen (target workspace's window + the dragged one) BEFORE
    // the float so the anchor is measured in its tiled slot, and re-applies it AFTER the
    // un-float: the workspace's window always, the dragged window only when it stays there.
    function test_tiled_insert_lua_strips_fullscreen_first_and_reapplies_last() {
        var lua = Logic.tiledInsertLua("0xabc", 3, { anchor: "0xdef", side: "left", x: 1, y: 2 })
        verify(lua.indexOf('\n') < 0)
        verify(lua.indexOf('hl.get_workspace("3")') >= 0, "reads the target workspace")
        verify(lua.indexOf('fullscreen_window') >= 0 && lua.indexOf('fullscreen_mode') >= 0, "records the workspace's fullscreen state")
        verify(lua.indexOf('ownMode') >= 0, "records the dragged window's own mode")
        var firstFs = lua.indexOf('hl.dsp.window.fullscreen('), firstFloat = lua.indexOf('window.float(')
        var lastFs = lua.lastIndexOf('hl.dsp.window.fullscreen('), lastFloat = lua.lastIndexOf('window.float(')
        verify(firstFs >= 0 && firstFs < firstFloat, "fullscreen stripped before the float")
        verify(lastFs > lastFloat, "fullscreen re-applied after the un-float")
        verify(lua.indexOf('same and w.fullscreen or 0') >= 0, "own mode only kept for a same-workspace re-tile")
        verify(lua.lastIndexOf('smart_split = smart') > lastFs, "config restored after everything")
        verify(lua.indexOf('local prevW, cur = hl.get_active_window(), hl.get_cursor_pos()') >= 0,
               "focus and cursor recorded up front")
        // The workspace that window was on is part of the capture: the restore refuses to chase a
        // window the chunk has moved, because focusing one that lives elsewhere switches the user
        // to it (see captureFocusLua / restoreFocusLua; behaviour pinned in tests/lua).
        verify(lua.indexOf('local prevWs = prevW and prevW.workspace and prevW.workspace.id or nil') >= 0,
               "the workspace it was on is recorded too")
        verify(lua.lastIndexOf('hl.dsp.focus(') > lua.lastIndexOf('smart_split = smart'), "focus restored (if moved) at the very end")
        verify(lua.lastIndexOf('cursor.move(') > lua.lastIndexOf('hl.dsp.focus('), "cursor restored after the re-focus")
        verify(lua.indexOf('fa:sub(1, 2) ~= "0x"') >= 0, "workspace fullscreen address normalised like restoreFocusLua")
    }

    // A chunk that fails to parse is dropped silently by the compositor, so beyond substring
    // checks we sanity-check that every do/then/function( opener has a matching end.
    function luaBalanced(s) {
        var open = (s.match(/\b(do|then|function)\b/g) || []).length   // anonymous or named functions
        var elseifs = (s.match(/\belseif\b/g) || []).length   // `elseif … then` shares the if's end
        var close = (s.match(/\bend\b/g) || []).length
        return open - elseifs === close
    }

    // The un-fullscreen chunk re-reads the window and only acts when its mode differs from the
    // target, so a stale badge click is harmless; it names the window by address, is one line,
    // and takes the target mode as a Lua expression (the insert chunk re-applies a recorded mode).
    function test_unfullscreen_lua_is_guarded_single_line_and_addressed() {
        var lua = Logic.unfullscreenLua("0xabc")
        verify(lua.indexOf('\n') < 0, "single line: Quickshell drops multi-line dispatches")
        verify(lua.indexOf('function()') === 0, "a function chunk, evaluated by hl.dispatch")
        verify(lua.indexOf('hl.get_window("address:0xabc")') >= 0, "re-reads the window by address")
        verify(lua.indexOf('fw.fullscreen ~= fm') >= 0, "guard: acts only when the mode differs")
        verify(lua.indexOf('hl.dsp.window.fullscreen(') >= 0, "dispatches the typed fullscreen selector form")
        verify(lua.indexOf('hl.get_window("address:0xabc"), 0') >= 0, "target mode 0 = off")
        verify(lua.indexOf('(fm == 1 or (fm == 0 and fw.fullscreen == 1))') >= 0, "full mode-name condition, not just a fragment")
        verify(lua.indexOf('pcall(function()') >= 0, "the toggle is wrapped in pcall so focus/cursor restore still runs if it throws")
        verify(luaBalanced(lua), "do/then/function openers balance ends")
        verify(lua.indexOf('local prevW, cur = hl.get_active_window(), hl.get_cursor_pos()') >= 0, "records focus + cursor first")
        var fsAt = lua.indexOf('hl.dsp.window.fullscreen('), focusAt = lua.indexOf('hl.dsp.focus('), curAt = lua.lastIndexOf('cursor.move(')
        verify(focusAt > fsAt && curAt > focusAt, "re-focus (if changed) then cursor restore, after the toggle")
        verify(lua.indexOf('nowW.address ~= prevW.address') >= 0, "re-focuses only when focus actually moved")
        var body = Logic.fullscreenBodyLua('fsSel', 'fsMode')
        verify(body.indexOf('hl.get_window(fsSel), fsMode') >= 0, "selector and mode may be Lua expressions")
        verify(body.indexOf('"maximized" or "fullscreen"') >= 0, "mode name derived from target/current mode")
    }

    // A floating drop is ONE chunk: (workspace transfer, skipped when already there) then the
    // exact-position move, in that order, inside the compositor — so nothing depends on the
    // overlay staying loaded to finish the job. Focus/cursor restore as in every other chunk.
    function test_floating_move_lua_transfers_then_positions_in_one_chunk() {
        var lua = Logic.floatingMoveLua("0xabc", 3, { x: 200.4, y: 1600.6 })
        verify(lua.indexOf('\n') < 0, "single line")
        verify(lua.indexOf('function()') === 0)
        verify(lua.indexOf('local sel = "address:0xabc"') >= 0)
        verify(lua.indexOf('if not w or not w.floating then return end') >= 0, "tiled windows are not moved by this chunk")
        var xfer = lua.indexOf('workspace = "3", follow = false'), pos = lua.indexOf('x = "200", y = "1601"')
        verify(xfer >= 0, "workspace transfer present"); verify(pos >= 0, "rounded exact position present")
        verify(xfer < pos, "transfer before positioning")
        verify(lua.indexOf('w.workspace.id == 3') >= 0, "transfer is skipped when already on the workspace")
        verify(lua.indexOf('pcall(function()') >= 0 && luaBalanced(lua), "guarded and balanced")
        verify(lua.lastIndexOf('hl.dsp.focus(') > pos && lua.lastIndexOf('cursor.move(') > lua.lastIndexOf('hl.dsp.focus('),
               "focus then cursor restored after the moves")
        verify(lua.indexOf('NaN') < 0 && lua.indexOf('undefined') < 0)
    }

    // Cleanup must not be skippable: the un-float, both fullscreen re-applies and the config
    // restore each run OUTSIDE the risky pcall and re-read state so they only undo what the
    // chunk did. A swallowed error is reported (compositor log + on-screen notification).
    function test_tiled_insert_lua_cleanup_is_outside_the_risky_pcall_and_reports() {
        var lua = Logic.tiledInsertLua("0xabc", 3, { anchor: "0xdef", side: "left", x: 1, y: 2 })
        var risky = lua.lastIndexOf('local ok, err = pcall(function()')   // the layout guard has its own, earlier
        verify(risky >= 0, "risky steps capture ok/err")
        var riskyEnd = lua.indexOf('end)', lua.indexOf('cursor.move(', risky))
        verify(riskyEnd > risky, "the cursor move is the last risky step")
        var unfloat = lua.indexOf('if fw and fw.floating then run(hl.dsp.window.float(')
        verify(unfloat > riskyEnd, "un-float re-reads floating state and runs after the pcall")
        verify(lua.indexOf('local function step(f) local g, e = pcall(f) if not g then ok, err = false, err or e end end') > riskyEnd,
               "cleanup steps are guarded and fold their failure into ok/err")
        verify(lua.indexOf('step(function() if fsSel and fsSel ~= sel then') > riskyEnd, "workspace fullscreen re-apply is its own guarded step")
        verify(lua.indexOf('step(function() if ownMode ~= 0 then') > riskyEnd, "own fullscreen re-apply is its own guarded step")
        verify(lua.lastIndexOf('smart_split = smart') > lua.lastIndexOf('step(function() if ownMode'), "config restored after every guarded cleanup step")
        verify(lua.lastIndexOf('if not ok then') > lua.lastIndexOf('smart_split = smart'), "report after the config restore")
        verify(lua.indexOf('print(msg)') >= 0 && lua.indexOf('hl.notification.create({ text = msg') >= 0, "reported to log and screen")
        verify(lua.indexOf('tiled insert failed') >= 0)
        verify(luaBalanced(lua))
    }
    // Non-dwindle layouts get a plain silent workspace move (or nothing, same workspace) —
    // the cursor-based insert is a dwindle behaviour.
    function test_tiled_insert_lua_falls_back_to_plain_move_off_dwindle() {
        var lua = Logic.tiledInsertLua("0xabc", 3, { anchor: "0xdef", side: "left", x: 1, y: 2 })
        var guard = lua.indexOf('local layout = hl.get_config("general.layout")')
        verify(guard >= 0 && guard < lua.indexOf('smart_split = true'), "layout read before any dwindle config change")
        verify(lua.indexOf('if layout ~= nil and layout ~= "dwindle" then') >= 0, "unknown key (nil) keeps the dwindle path")
        var fb = lua.indexOf('if not same then run(hl.dsp.window.move({ workspace = "3", follow = false, window = sel })) end', guard)
        verify(fb > guard && fb < lua.indexOf('smart_split = true'), "fallback is a plain silent move, before the dwindle path")
        verify(lua.lastIndexOf('local ok, err = pcall(function()', fb) > guard && lua.indexOf('if not ok then', fb) < lua.indexOf('smart_split = true'),
               "the fallback move is guarded and reported too")
        verify(lua.indexOf('return', fb) > fb && lua.indexOf('return', fb) < lua.indexOf('smart_split = true'), "fallback returns before the dwindle path")
    }
    function test_index_of_workspace() {
        var boxes = [{ workspaceId: 2 }, { workspaceId: 5 }, { workspaceId: 7 }]
        compare(Logic.indexOfWorkspace(boxes, 5), 1)
        compare(Logic.indexOfWorkspace(boxes, 2), 0)
        compare(Logic.indexOfWorkspace(boxes, 9), -1)
        compare(Logic.indexOfWorkspace([], 2), -1)
    }
    // hl.dispatch never raises: a failed dispatcher returns { ok = false, error }. Every chunk
    // defines run() to raise on that inside its pcall, and dispatches its steps through it.
    function test_every_chunk_reports_swallowed_errors() {
        var chunks = [Logic.unfullscreenLua("0xabc"), Logic.floatingMoveLua("0xabc", 2, { x: 1, y: 2 }),
                      Logic.tiledInsertLua("0xabc", 3, { anchor: "0xdef", side: "left", x: 1, y: 2 })]
        for (var i = 0; i < chunks.length; i++) {
            var c = chunks[i], guard = c.indexOf('local function run(d) local r = hl.dispatch(d) if r and r.ok == false then error(tostring(r.error), 0) end return r end')
            verify(guard >= 0 && guard < c.indexOf('pcall(function()'), "chunk " + i + " defines run() before its first pcall")
            // Every `local ok, err = pcall(...)` … `if not ok then` span (risky steps + cleanup)
            // dispatches through run(); only the best-effort focus/cursor restore stays raw.
            var at = 0, spans = 0
            while ((at = c.indexOf('local ok, err = pcall(function()', at)) >= 0) {
                var body = c.substring(at, c.indexOf('if not ok then', at))
                verify(body.indexOf('hl.dispatch(') < 0, "chunk " + i + " span " + spans + ": guarded steps dispatch through run()")
                at += 10; spans++
            }
            verify(spans >= 1, "chunk " + i + " has a guarded span")
        }
        verify(chunks[0].indexOf('un-fullscreen failed') >= 0)
        verify(chunks[1].indexOf('floating move failed') >= 0)
        var r = Logic.reportLua('thing')
        verify(r.indexOf('if not ok then') === 0 && r.indexOf('tostring(err)') >= 0)
        verify(r.indexOf('pcall(function() hl.notification.create(') >= 0, "notification API itself guarded (older Hyprland)")
    }

    // ---- recoverSlot: a fullscreen window's tiled slot is what the OTHER tiled windows leave
    // uncovered. usableR is the usable rect in local coords (2048x1254 = eDP-1 minus the 26px bar).
    readonly property var usableR: ({ x: 0, y: 0, w: 2048, h: 1254 })
    function slotEq(s, x, y, w, h, msg) {
        verify(s !== null, msg + ": got null")
        compare(s.x, x, msg + " x"); compare(s.y, y, msg + " y")
        compare(s.w, w, msg + " w"); compare(s.h, h, msg + " h")
    }
    function test_recover_slot_two_windows() {
        // Teams on the left (x 0..825), Chrome fullscreen: the hole is the right part.
        slotEq(Logic.recoverSlot(usableR, [{ x: 0, y: 0, w: 825, h: 1254 }], params),
               825, 0, 1223, 1254, "two windows")
    }
    function test_recover_slot_nested_split_no_gaps() {
        // left column split top/bottom, hole = right half (a projected horizontal edge splits
        // the hole into two grid cells that must be merged back)
        slotEq(Logic.recoverSlot(usableR, [{ x: 0, y: 0, w: 1024, h: 627 },
                                          { x: 0, y: 627, w: 1024, h: 627 }], params),
               1024, 0, 1024, 1254, "nested split")
    }
    // gaps_in 5 / gaps_out 10: the outer/inner strips are separate thin grid cells wherever a
    // neighbour's edge creates one; those are trimmed, so the recovered slot starts at the true
    // top (y 10, h 1234). Sides without a neighbour edge keep the gap merged in (x may be 1019
    // or 1029, right edge 2048): padding, never a wrong slot.
    function test_recover_slot_with_gaps_trims_padding() {
        var s = Logic.recoverSlot(usableR, [{ x: 10, y: 10, w: 1009, h: 612 },
                                           { x: 10, y: 632, w: 1009, h: 612 }], params)
        verify(s !== null)
        compare(s.y, 10, "top gap row trimmed"); compare(s.h, 1234, "bottom gap row trimmed")
        verify(s.x >= 1019 && s.x <= 1029, "left edge within the inner gap")
        compare(s.x + s.w, 2048)
    }
    // gaps_out 40 is ABOVE slotGapTolerance: the outer strips survive the trim as padding, but
    // the old bounding-box approach would have stretched the result to the whole rect (x 0).
    // Seed+grow must stop at the neighbour: the slot never reaches the left strip.
    function test_recover_slot_outer_gap_above_tolerance_never_spans_whole_rect() {
        var s = Logic.recoverSlot(usableR, [{ x: 40, y: 40, w: 979, h: 582 },
                                           { x: 40, y: 632, w: 979, h: 582 }], params)
        verify(s !== null)
        verify(s.x >= 1019, "must not cross the neighbour into the left outer strip: x=" + s.x)
        compare(s.x + s.w, 2048)
        // contains the true tiled rect {1029,40,979,1174}
        verify(s.x <= 1029 && s.y <= 40 && s.x + s.w >= 2008 && s.y + s.h >= 1214)
    }
    // The fullscreen window was the SMALLEST of six, gaps_in 5: projected edges split the hole,
    // strips are thin. Seed on largest-min-side + grow + trim recovers the exact tiled rect.
    function test_recover_slot_smallest_of_six_exact() {
        var others = [
            { x: 0,    y: 0,   w: 1019, h: 1254 },   // A: left half
            { x: 1029, y: 0,   w: 1019, h: 622 },    // B: right-top
            { x: 1029, y: 632, w: 507,  h: 308 },    // C
            { x: 1541, y: 632, w: 507,  h: 308 },    // D
            { x: 1029, y: 945, w: 507,  h: 309 }     // E ; hole = {1541,945,507,309}
        ]
        slotEq(Logic.recoverSlot(usableR, others, params), 1541, 945, 507, 309, "smallest of six")
    }
    function test_recover_slot_no_others_is_whole_rect() {
        slotEq(Logic.recoverSlot(usableR, [], params), 0, 0, 2048, 1254, "lone")
    }
    function test_recover_slot_fully_covered_is_null() {
        compare(Logic.recoverSlot(usableR, [{ x: 0, y: 0, w: 2048, h: 1254 }], params), null)
        // only a hairline uncovered (thinner than the tolerance) is null too
        compare(Logic.recoverSlot(usableR, [{ x: 0, y: 0, w: 2040, h: 1254 }], params), null)
    }
    function test_recover_slot_clips_others_to_rect() {
        // a window poking left of the usable rect must not create a phantom column outside it
        slotEq(Logic.recoverSlot(usableR, [{ x: -100, y: 0, w: 1124, h: 1254 }], params),
               1024, 0, 1024, 1254, "clipped")
    }
    // Thin projected-edge rows just inside the slot must not be peeled one after another: the
    // trim removes at most one gap band (< tol) per side. Old per-cell peel returned a bottom
    // edge of 482 here, 45px short of the true slot {1059,20,626,507}.
    function test_recover_slot_trim_peels_at_most_one_gap_band() {
        var big = { x: 0, y: 0, w: 2560, h: 1554 }
        var others = [{x:20,y:20,w:482,h:462},{x:20,y:492,w:482,h:1062},{x:512,y:20,w:537,h:507},
                      {x:512,y:537,w:1173,h:1017},{x:1695,y:20,w:367,h:486},{x:2072,y:20,w:468,h:486},
                      {x:1695,y:516,w:845,h:1038}]
        var s = Logic.recoverSlot(big, others, params), tol = params.slotGapTolerance
        verify(s !== null)
        verify(s.y + s.h >= 527 - tol, "bottom edge within one gap band of the true slot: " + (s.y + s.h))
        verify(s.x <= 1059 && s.x + s.w >= 1685 - tol && s.y <= 20, "contains the true slot within tol on every side")
    }
    function test_recover_slot_missing_param_still_rejects_hairline() {
        compare(Logic.recoverSlot(usableR, [{ x: 0, y: 0, w: 2040, h: 1254 }], {}), null,
                "missing slotGapTolerance still rejects a hairline")
    }

    // ---- layout(): fullscreen windows are placed in the recovered slot; every tile carries a
    // stacking layer (0 backdrop, 1 tiled, 2 floating) and the fullscreen mode.
    function fsInput(windows) {
        return { monitors: [edp()],
                 workspaces: [{ id: 1, monitorName: "eDP-1", focused: true, occupied: true }],
                 windows: windows, focusedMonitorName: "eDP-1", availW: 1632, params: params }
    }
    // eDP: R = 2048x1254, cell mini-map 308x188 → height-limited, k = 188/1254.
    readonly property real kEdp: 188 / 1254
    function test_fullscreen_tiled_lands_in_recovered_slot() {
        var r = Logic.layout(fsInput([
            { address: "0xT", cls: "teams", ax: 0, ay: 26, sw: 825, sh: 1254, workspaceId: 1, floating: false, fullscreen: 0 },
            { address: "0xF", cls: "chrome", ax: 0, ay: 0, sw: 2048, sh: 1280, workspaceId: 1, floating: false, fullscreen: 2 }
        ]))
        var t = tilesByAddr(r, "0xT"), f = tilesByAddr(r, "0xF")
        fuzzyCompare(f.x, t.x + t.w, 0.6, "starts where the neighbour ends")
        fuzzyCompare(f.w, 1223 * kEdp, 0.6, "spans the uncovered width")
        fuzzyCompare(f.h, 188, 0.6, "full usable height")
        compare(f.layer, 1); compare(f.fullscreen, 2)
        compare(t.layer, 1); compare(t.fullscreen, 0)
        fuzzyCompare(t.w, 825 * kEdp, 0.6, "neighbour drawn from its real geometry")
    }
    function test_lone_fullscreen_still_fills_usable_rect() {
        var r = Logic.layout(fsInput([
            { address: "0xF", cls: "x", ax: 0, ay: 0, sw: 2048, sh: 1280, workspaceId: 1, floating: false, fullscreen: 2 }]))
        var f = tilesByAddr(r, "0xF")
        fuzzyCompare(f.h, 188, 0.5); fuzzyCompare(f.w, 2048 * kEdp, 0.6)
        compare(f.layer, 1)
    }
    // Stale data: the others already cover everything → fill R but sit BELOW the tiled tiles.
    function test_fullscreen_with_no_hole_is_backdrop() {
        var r = Logic.layout(fsInput([
            { address: "0xT", cls: "x", ax: 0, ay: 26, sw: 2048, sh: 1254, workspaceId: 1, floating: false, fullscreen: 0 },
            { address: "0xF", cls: "x", ax: 0, ay: 0, sw: 2048, sh: 1280, workspaceId: 1, floating: false, fullscreen: 2 }]))
        var f = tilesByAddr(r, "0xF")
        fuzzyCompare(f.h, 188, 0.5); compare(f.layer, 0)
        compare(tilesByAddr(r, "0xT").layer, 1)
    }
    // A floating window that is fullscreen has no slot: centred at 60% of R, floating layer.
    function test_floating_fullscreen_is_centred_60_percent() {
        var r = Logic.layout(fsInput([
            { address: "0xF", cls: "x", ax: 0, ay: 0, sw: 2048, sh: 1280, workspaceId: 1, floating: true, fullscreen: 2 }]))
        var f = tilesByAddr(r, "0xF"), b = boxById(r, 1)
        fuzzyCompare(f.w, 0.6 * 2048 * kEdp, 0.6); fuzzyCompare(f.h, 0.6 * 188, 0.6)
        fuzzyCompare(f.x - b.x, (b.w - f.w) / 2, 1.0, "horizontally centred in the box")
        compare(f.layer, 2); compare(f.fullscreen, 2)
    }
    function test_layers_and_mode_are_carried() {
        var r = Logic.layout(fsInput([
            { address: "0xA", cls: "x", ax: 100, ay: 100, sw: 400, sh: 300, workspaceId: 1, floating: true, fullscreen: 0 },
            { address: "0xB", cls: "x", ax: 600, ay: 100, sw: 400, sh: 300, workspaceId: 1, floating: false, fullscreen: 0 },
            { address: "0xM", cls: "x", ax: 0, ay: 26, sw: 2048, sh: 1254, workspaceId: 1, floating: false, fullscreen: 1 }]))
        compare(tilesByAddr(r, "0xA").layer, 2)
        compare(tilesByAddr(r, "0xB").layer, 1)
        compare(tilesByAddr(r, "0xM").fullscreen, 1, "maximized mode carried as 1")
        // legacy boolean still means fullscreen (mode 2)
        var legacy = Logic.layout(fsInput([{ address: "0xL", cls: "x", ax: 0, ay: 0, sw: 2048, sh: 1280,
                                              workspaceId: 1, floating: false, fullscreen: true }]))
        compare(tilesByAddr(legacy, "0xL").fullscreen, 2)
    }

    function scratchInput(extra) {
        var wss = [ { id: 1, monitorName: "eDP-1", focused: true, occupied: true },
                    { id: 2, monitorName: "eDP-1", focused: false, occupied: false },
                    { id: Logic.SCRATCHPAD_ID, monitorName: "eDP-1", special: "scratchpad",
                      focused: false, occupied: true } ]
        return { monitors: [edp()], workspaces: wss, windows: extra || [],
                 focusedMonitorName: "eDP-1", availW: 1632, params: params }
    }
    // Distinguishes: the scratchpad laid out inside the monitor group (a third cell on the
    // row), or without its own header band in single-monitor mode.
    function test_scratchpad_group_is_appended_below_with_a_header() {
        var r = Logic.layout(scratchInput())
        compare(r.groups.length, 2)
        compare(r.groups[0].headerH, 0, "single-monitor group keeps no band")
        compare(r.groups[1].special, "scratchpad")
        compare(r.groups[1].headerH, 22, "the scratchpad row always has a band")
        compare(r.groups[1].focused, false)
        verify(r.groups[1].y >= r.groups[0].y + r.groups[0].h + params.rowSpacing - 0.5, "below the last group")
        var s = boxById(r, Logic.SCRATCHPAD_ID)
        verify(s !== null, "one box for the scratchpad")
        compare(s.special, "scratchpad")
        compare(s.synthetic, false, "the scratchpad is never a pad slot")
        compare(s.active, false, "the scratchpad is never a monitor's activeWorkspace")
        compare(s.w, r.cell.w); compare(s.h, boxById(r, 1).h, "same monitor, same cell height")
        fuzzyCompare(s.x + s.w / 2, r.canvasSize.w / 2, 1, "centred in the row")
        compare(r.groups[1].w, r.canvasSize.w, "the row spans the canvas")
        compare(s.y, r.groups[1].y + 22, "under the band")
        fuzzyCompare(r.canvasSize.h, s.y + s.h, 0.5)
    }
    // Distinguishes: the row height taken from the focused monitor instead of the scratchpad's.
    function test_scratchpad_box_height_follows_its_own_monitor() {
        var input = scratchInput()
        input.monitors = [edp(), hdmi()]
        input.workspaces.push({ id: 6, monitorName: "HDMI-A-1", focused: false, occupied: false })
        input.workspaces[2].monitorName = "HDMI-A-1"
        var r = Logic.layout(input)
        compare(boxById(r, Logic.SCRATCHPAD_ID).h, boxById(r, 6).h)
        verify(boxById(r, Logic.SCRATCHPAD_ID).h !== boxById(r, 1).h)
        compare(r.groups.length, 3); compare(r.groups[2].special, "scratchpad")
    }
    // Distinguishes: a special group that appears even when no special workspace is in the input.
    function test_no_scratchpad_group_without_a_special_workspace() {
        var input = scratchInput(); input.workspaces.pop()
        var r = Logic.layout(input)
        compare(r.groups.length, 1); compare(boxById(r, Logic.SCRATCHPAD_ID), null)
    }
    // Distinguishes: a placeholder workspace still emitting tiles (a capture would start), and
    // the flags not reaching the box (the delegate could not draw badge/glyph).
    function test_placeholder_workspace_has_flags_and_no_tiles() {
        var input = scratchInput([
            { address: "0xA", cls: "x", ax: 0, ay: 26, sw: 1024, sh: 1254, workspaceId: 1, floating: false, fullscreen: 0 },
            { address: "0xB", cls: "x", ax: 0, ay: 26, sw: 1024, sh: 1254, workspaceId: 2, floating: false, fullscreen: 0 }])
        input.workspaces[0].armed = true; input.workspaces[0].placeholder = true    // ws 1
        input.workspaces[1].armed = true                                           // ws 2: armed, not sharing
        var r = Logic.layout(input)
        compare(boxById(r, 1).armed, true); compare(boxById(r, 1).placeholder, true)
        compare(boxById(r, 2).armed, true); compare(boxById(r, 2).placeholder, false)
        compare(boxById(r, Logic.SCRATCHPAD_ID).armed, false); compare(boxById(r, Logic.SCRATCHPAD_ID).placeholder, false)
        var addrs = r.tiles.map(function (t) { return t.address })
        compare(addrs.indexOf("0xA"), -1, "no tile on the placeholder workspace")
        verify(addrs.indexOf("0xB") >= 0, "armed-but-visible workspace keeps its tiles")
    }
    // Distinguishes: a tiled scratchpad window dropped or drawn as floating (layer 2).
    function test_tiled_window_on_the_scratchpad_renders_as_a_tiled_tile() {
        var r = Logic.layout(scratchInput([
            { address: "0xT", cls: "x", ax: 0, ay: 26, sw: 1024, sh: 1254, workspaceId: Logic.SCRATCHPAD_ID,
              floating: false, fullscreen: 0 }]))
        var t = null
        for (var i = 0; i < r.tiles.length; i++) if (r.tiles[i].address === "0xT") t = r.tiles[i]
        verify(t !== null); compare(t.layer, 1); compare(t.workspaceId, Logic.SCRATCHPAD_ID)
    }
    // Distinguishes: `hasWs` written as `>= 0` (rejects -2) or as `!== undefined` (accepts -1).
    function test_hasWs_accepts_the_scratchpad_and_rejects_none() {
        verify(Logic.hasWs(Logic.SCRATCHPAD_ID)); verify(Logic.hasWs(1)); verify(Logic.hasWs(10))
        verify(!Logic.hasWs(-1)); verify(!Logic.hasWs(undefined)); verify(!Logic.hasWs(null)); verify(!Logic.hasWs(NaN))
    }
    // Distinguishes: dispatching the scratchpad by id (Hyprland's id is dynamic) instead of by name.
    function test_wsSelector_names_the_scratchpad() {
        compare(Logic.wsSelector(Logic.SCRATCHPAD_ID), "special:scratchpad")
        compare(Logic.wsSelector(3), "3")
        verify(Logic.isScratchpad(Logic.SCRATCHPAD_ID)); verify(!Logic.isScratchpad(2)); verify(!Logic.isScratchpad(-1))
        compare(Logic.wsSelector(undefined), ""); compare(Logic.wsSelector(NaN), "")
    }
    // Distinguishes: floatingMoveLua emitting a numeric target for the scratchpad ("-2" is not a
    // workspace Hyprland knows) or comparing "same workspace" by id.
    function test_floating_move_to_the_scratchpad_uses_the_name() {
        var lua = Logic.floatingMoveLua("0xabc", Logic.SCRATCHPAD_ID, { x: 10, y: 20 })
        verify(lua.indexOf('workspace = "special:scratchpad"') >= 0)
        verify(lua.indexOf('w.workspace.name == "special:scratchpad"') >= 0)
        verify(lua.indexOf('"-2"') < 0)
        var normal = Logic.floatingMoveLua("0xabc", 3, { x: 10, y: 20 })
        verify(normal.indexOf('workspace = "3"') >= 0); verify(normal.indexOf('w.workspace.id == 3') >= 0)
    }

    // Distinguishes: a builder that interpolates any string into the Lua array (a selector with
    // a quote or a Lua comment would break out of the chunk).
    function test_lock_selectors_are_validated() {
        compare(Logic.validLockSelector("3"), true)
        compare(Logic.validLockSelector("10"), true)
        compare(Logic.validLockSelector("special:scratchpad"), true)
        compare(Logic.validLockSelector("special:my-pad_2"), true)
        compare(Logic.validLockSelector(""), false)
        compare(Logic.validLockSelector("-2"), false)
        // Hyprland parses "007" as workspace 7 (leading zeros stripped): a hand-edited "007"
        // would arm workspace 7 with no badge to show it, so leading zeros are refused; "0" is
        // refused too (Hyprland workspaces are 1-indexed).
        compare(Logic.validLockSelector("0"), false)
        compare(Logic.validLockSelector("007"), false)
        compare(Logic.validLockSelector("3\"); error(\"x"), false)
        compare(Logic.validLockSelector("special:a b"), false)
        compare(Logic.validLockSelector(undefined), false)
    }
    // Distinguishes: the sync chunk carrying an invalid selector, or dropping valid ones.
    function test_lock_sync_chunk_carries_only_valid_selectors() {
        var lua = Logic.lockSyncLua(["3", "bad one", "special:scratchpad"])
        verify(lua.indexOf('"3"') >= 0 && lua.indexOf('"special:scratchpad"') >= 0)
        verify(lua.indexOf("bad one") < 0)
        verify(lua.indexOf("omascape-lock-") >= 0, "rules are named")
        compare(Logic.lockSyncLua([]).indexOf("local ARMED = {}") >= 0, true)
    }
    // Distinguishes: a parser that accepts a bad selector (it would reach a Lua chunk) or
    // rejects a valid file.
    function test_parseLocks() {
        compare(Logic.parseLocks('{ "armed": ["3", "special:scratchpad", "3"] }').armed, ["3", "special:scratchpad"])
        compare(Logic.parseLocks('{ "armed": [] }').ok, true)
        compare(Logic.parseLocks('nope').ok, false)
        compare(Logic.parseLocks('{ "armed": ["x y"] }').ok, false)
        compare(Logic.parseLocks('{}').ok, false)
    }
    // Distinguishes: a load reducer that treats every "missing" status the same regardless of
    // whether armed has already resolved — a later missing load (the file was deleted after a
    // successful first read) must keep the in-memory set, not silently disarm it.
    function test_applyLocksTo_missing() {
        var first = Logic.applyLocksTo(null, "", "missing")
        compare(first.armed, []); compare(first.changed, true); compare(first.error, null)
        var later = Logic.applyLocksTo(["3"], "", "missing")
        compare(later.armed, ["3"]); compare(later.changed, false); compare(later.error, null)
    }
    // Distinguishes: a read error (permission, a directory in its place, …) mistaken for
    // "missing" — that would silently disarm every rule the compositor holds.
    function test_applyLocksTo_error() {
        var first = Logic.applyLocksTo(null, "", "error:boom")
        compare(first.armed, null); compare(first.changed, false); compare(first.error, "boom")
        var later = Logic.applyLocksTo(["3"], "", "error:boom")
        compare(later.armed, ["3"]); compare(later.changed, false); compare(later.error, "boom")
    }
    // Distinguishes: a malformed file's parse error not surfacing, or clobbering a good set.
    function test_applyLocksTo_malformed() {
        var first = Logic.applyLocksTo(null, "nope", "ok")
        compare(first.armed, null); compare(first.changed, false); verify(first.error)
        var later = Logic.applyLocksTo(["3"], "nope", "ok")
        compare(later.armed, ["3"]); compare(later.changed, false); verify(later.error)
    }
    function test_applyLocksTo_ok() {
        var r = Logic.applyLocksTo(null, '{ "armed": ["3", "special:scratchpad"] }', "ok")
        compare(r.armed, ["3", "special:scratchpad"]); compare(r.changed, true); compare(r.error, null)
        // A first load of an empty set must still count as a change — the start-up
        // reconciliation sync depends on it firing even when nothing is armed.
        compare(Logic.applyLocksTo(null, '{ "armed": [] }', "ok").changed, true)
    }
    // Distinguishes: every successful parse being reported as a change (a reload echo —
    // watchChanges/reload() re-emitting `loaded` with unchanged bytes — would then re-dispatch
    // a sync, and while open a rebuild, for nothing) from one that actually compares against
    // the current set, order included.
    function test_applyLocksTo_unchanged_reload_is_not_a_change() {
        var same = Logic.applyLocksTo(["3", "special:scratchpad"], '{ "armed": ["3", "special:scratchpad"] }', "ok")
        compare(same.armed, ["3", "special:scratchpad"]); compare(same.changed, false)
        var reordered = Logic.applyLocksTo(["3", "special:scratchpad"], '{ "armed": ["special:scratchpad", "3"] }', "ok")
        compare(reordered.changed, true, "a different order still counts as changed")
        var different = Logic.applyLocksTo(["3"], '{ "armed": ["4"] }', "ok")
        compare(different.changed, true)
    }
    // Distinguishes: a toggle that mutates in place (aliasing the caller's array) or accepts an
    // unresolved/invalid selector.
    function test_toggleSelector() {
        var armed = ["3"]
        var next = Logic.toggleSelector(armed, "3")
        compare(next, []); compare(armed, ["3"], "the input array is untouched")
        compare(Logic.toggleSelector([], "3"), ["3"])
        compare(Logic.toggleSelector(null, "3"), null, "refuses while unresolved")
        compare(Logic.toggleSelector([], "bad selector"), null, "refuses an invalid selector")
    }

    // ---- Share-time reminder frame (docs/specs/2026-09-12-lock-design.md, addendum) ----------
    // The frame is drawn on the workspace SHOWN on a monitor, which is its special workspace when
    // one is open and its active workspace otherwise. Distinguishes: a selector taken from the
    // active workspace even while a special workspace covers it (the frame would then follow the
    // workspace underneath the scratchpad), and a special workspace read by its dynamic id rather
    // than the name the locks file stores.
    function test_lockFrameShownSelector_prefers_the_open_special_workspace() {
        compare(Logic.lockFrameShownSelector(
            { activeWorkspace: { id: 3, name: "3" }, specialWorkspace: { id: -98, name: "special:scratchpad" } }),
            "special:scratchpad")
        compare(Logic.lockFrameShownSelector(
            { activeWorkspace: { id: 3, name: "3" }, specialWorkspace: { id: 0, name: "" } }), "3")
    }
    // Hyprland reports `specialWorkspace: { id: 0, name: "" }` when no special workspace is open
    // (verified on 0.56.2), which is also what the `activespecialv2>>,,eDP-1` payload announces:
    // the empty name must fall back to the active workspace, not become a selector of its own.
    // Distinguishes: a truthiness test on `specialWorkspace` alone (the object is always present).
    function test_lockFrameShownSelector_falls_back_when_the_special_closed() {
        compare(Logic.lockFrameShownSelector(
            { activeWorkspace: { id: 7, name: "7" }, specialWorkspace: { id: 0, name: "" } }), "7")
        compare(Logic.lockFrameShownSelector({ activeWorkspace: { id: 7, name: "7" } }), "7",
                "no specialWorkspace key at all")
    }
    // Distinguishes: a malformed/absent snapshot throwing (the binding runs on every monitor
    // event, including ones that arrive before the first refresh has landed) instead of
    // resolving to "no workspace shown".
    function test_lockFrameShownSelector_malformed_is_null_and_never_throws() {
        compare(Logic.lockFrameShownSelector(null), null)
        compare(Logic.lockFrameShownSelector(undefined), null)
        compare(Logic.lockFrameShownSelector({}), null)
        compare(Logic.lockFrameShownSelector({ activeWorkspace: null }), null)
        compare(Logic.lockFrameShownSelector({ activeWorkspace: { name: "3" } }), null, "no id")
        compare(Logic.lockFrameShownSelector("eDP-1"), null)
    }
    // Distinguishes: a frame shown whenever the workspace is armed (it must also need a live
    // share), shown for a share alone (every monitor would be framed), or shown for an armed
    // workspace that is not the one on this monitor.
    function test_lockFrameVisible() {
        var mon3 = { activeWorkspace: { id: 3, name: "3" }, specialWorkspace: { id: 0, name: "" } }
        var mon4 = { activeWorkspace: { id: 4, name: "4" }, specialWorkspace: { id: 0, name: "" } }
        var scratch = { activeWorkspace: { id: 3, name: "3" },
                        specialWorkspace: { id: -98, name: "special:scratchpad" } }
        compare(Logic.lockFrameVisible(true, ["3"], mon3), true)
        compare(Logic.lockFrameVisible(false, ["3"], mon3), false, "no share, no frame")
        compare(Logic.lockFrameVisible(true, ["3"], mon4), false, "another monitor's workspace is armed")
        compare(Logic.lockFrameVisible(true, [], mon3), false)
        compare(Logic.lockFrameVisible(true, null, mon3), false, "armed still unresolved")
        compare(Logic.lockFrameVisible(true, ["3"], null), false, "no monitor snapshot")
        // The scratchpad covers ws 3: armed ws 3 alone must NOT frame it, and arming the
        // scratchpad must.
        compare(Logic.lockFrameVisible(true, ["3"], scratch), false)
        compare(Logic.lockFrameVisible(true, ["special:scratchpad"], scratch), true)
    }
    // `HyprlandMonitor.lastIpcObject` is a snapshot, so the frame is only correct if these exact
    // events trigger a `Hyprland.refreshMonitors()`. Distinguishes: a handler that refreshes on
    // every raw event (an IPC round trip per window title change) or one that misses the v2
    // payload names Hyprland 0.56.2 actually emits.
    function test_lockFrameRefreshEvent() {
        var want = ["workspacev2", "focusedmonv2", "activespecialv2", "moveworkspacev2",
                    "monitoraddedv2", "monitorremovedv2", "configreloaded"]
        for (var i = 0; i < want.length; i++)
            compare(Logic.lockFrameRefreshEvent(want[i]), true, want[i] + " must refresh monitors")
        var no = ["workspace", "activespecial", "monitoradded", "focusedmon", "openwindow",
                  "windowtitlev2", "activewindowv2", "", undefined, null]
        for (var j = 0; j < no.length; j++)
            compare(Logic.lockFrameRefreshEvent(no[j]), false, String(no[j]) + " must not refresh")
    }
    // The config colour is Hyprland's `rgb(rrggbb)` / `rgba(rrggbbaa)`; QML wants `#rrggbb` /
    // `#aarrggbb`. Distinguishes: an alpha left at the END (`#rrggbbaa` is read by Qt as
    // #aarrggbb, so `rgba(ff444480)` would render as a nearly-black 0xff-alpha colour) and a
    // rejected value producing an invalid colour string instead of the default.
    function test_lockColorToQml() {
        compare(Logic.lockColorToQml("rgb(ff4444)"), "#ff4444")
        compare(Logic.lockColorToQml("rgba(ff444480)"), "#80ff4444", "alpha moves to the front")
        compare(Logic.lockColorToQml("rgb(3355FF)"), "#3355FF")
        compare(Logic.lockColorToQml("red"), "#ff4444")
        compare(Logic.lockColorToQml("rgb(zz)"), "#ff4444")
        compare(Logic.lockColorToQml(""), "#ff4444")
        compare(Logic.lockColorToQml(undefined), "#ff4444")
        compare(Logic.lockColorToQml("#ff4444"), "#ff4444", "already-QML input is not accepted, but degrades to the default")
    }
    // A frame strip's surface must land on WHOLE device pixels, or the `no_screen_share` blanking
    // box — floored origin, truncated size — misses one device line of it and the frame leaks into
    // the capture. This picks the smallest surface at least one logical px thicker than the paint
    // whose device size is integral. Distinguishes: no snapping at all (always thickness + 1, which
    // is 8.75 device px at scale 1.25), a search that stops at the first candidate without checking
    // the product, and one that never gives up (an irrational-ish scale must fall back rather than
    // grow the frame without bound).
    function test_lockFrameSurfaceSize() {
        compare(Logic.lockFrameSurfaceSize(6, 1.25), 8, "7*1.25 = 8.75 is fractional; 8*1.25 = 10 is not")
        compare(Logic.lockFrameSurfaceSize(6, 1), 7, "scale 1: thickness + 1 is already whole")
        compare(Logic.lockFrameSurfaceSize(6, 1.5), 8, "7*1.5 = 10.5 fractional, 8*1.5 = 12 whole")
        compare(Logic.lockFrameSurfaceSize(6, 2), 7, "any integer scale takes the smallest surface")
        compare(Logic.lockFrameSurfaceSize(7, 1.25), 8, "the search starts at thickness + 1, not at a fixed size")
        compare(Logic.lockFrameSurfaceSize(6, 1.2), 10, "needs 4 more px than the minimum")
        compare(Logic.lockFrameSurfaceSize(6, 1.6), 10)
        compare(Logic.lockFrameSurfaceSize(6, 1.666667), 9, "a rounded 5/3 counts as whole within the tolerance")
        compare(Logic.lockFrameSurfaceSize(6, 1.333333), 9, "same for a rounded 4/3")
        compare(Logic.lockFrameSurfaceSize(6, NaN), 7, "a nonsense scale degrades to thickness + 1")
        compare(Logic.lockFrameSurfaceSize(6, 0), 7, "and so does a zero scale, which would divide the world by zero")
    }

    // Distinguishes: layout() dropping the flags menuItems needs. A padded (never-created)
    // workspace must arrive on its box as synthetic, and the monitor's active workspace as
    // active — a fixture that builds box records by hand could never catch this.
    function test_boxes_carry_synthetic_and_active() {
        var mon = { name: "M", x: 0, y: 0, width: 1920, height: 1080, scale: 1, reserved: [0, 0, 0, 0] }
        var wss = Logic.padWorkspaces(
            [{ id: 1, monitorName: "M", focused: true, occupied: true, active: true },
             { id: 2, monitorName: "M", focused: false, occupied: false, active: false }], 3, "M")
        var res = Logic.layout({ monitors: [mon], workspaces: wss, windows: [],
                                 focusedMonitorName: "M", availW: 1600,
                                 params: { maxCols: 5, minCellW: 140, maxCellW: 380, cellInset: 3,
                                           cellSpacing: 4, rowSpacing: 8, headerH: 22, groupInset: 6,
                                           minTileW: 8, minTileH: 6, slotGapTolerance: 24 } })
        function box(id) {
            for (var i = 0; i < res.boxes.length; i++) if (res.boxes[i].workspaceId === id) return res.boxes[i]
            fail("no box for workspace " + id)
        }
        compare(box(1).synthetic, false, "a real workspace is not synthetic")
        compare(box(1).active, true, "workspace 1 is the monitor's active one")
        compare(box(2).active, false)
        compare(box(3).synthetic, true, "workspace 3 exists only as a pad slot")
        compare(box(3).active, false, "a workspace Hyprland never created cannot be active")
    }

    // ---- peek (docs/specs/2026-09-18-peek-design.md) ------------------------------------

    // Distinguishes: a peekTiles that calls _tileRect directly instead of the shared placement,
    // which is exactly the defect the spec's "Workspace target" section forbids. The fullscreen
    // window must land in its recovered slot (the left half) and leave its neighbour visible; a
    // bare _tileRect call places it across the whole box and swallows 0xR.
    function test_peekTiles_recovers_a_fullscreen_slot_like_the_grid() {
        var mon = edp()
        var wins = [
            { address: "0xF", workspaceId: 1, ax: 0, ay: 26, sw: 2048, sh: 1254,
              floating: false, fullscreen: 2, cls: "full", title: "full" },
            { address: "0xR", workspaceId: 1, ax: 1024, ay: 26, sw: 1024, sh: 1254,
              floating: false, fullscreen: 0, cls: "right", title: "right" }
        ]
        var rows = Logic.peekTiles(wins, mon, 1200, 750, params)
        compare(rows.length, 2)
        var f = rows[0].address === "0xF" ? rows[0] : rows[1]
        var rt = rows[0].address === "0xF" ? rows[1] : rows[0]
        compare(f.fullscreen, 2); compare(f.layer, 1)
        verify(f.x + f.w <= rt.x + 1, "the fullscreen peek tile must not cover its neighbour")
        verify(rt.w > 0 && rt.h > 0, "the neighbour must still be drawn")
    }

    // Distinguishes: a peek that re-derives geometry instead of sharing the grid's. This
    // compares peekTiles against `layout`'s OWN output for the same workspace — the grid cell at
    // one size, the peek box at another — which is what the spec asks for. The fixed-px
    // `cellInset` changes the INNER box's aspect by a different amount at each scale (6px is
    // 1.6% of a 380px-wide grid cell and 0.5% of a 1200px peek box), so the grid cell and the
    // peek box are not similarly constrained even though they share a monitor — a small residual
    // drift between them is expected, and that is exactly why the comparison below is normalised
    // against each box's own INNER rect (box minus 2*cellInset) rather than its outer one.
    function test_peekTiles_geometry_matches_the_grid() {
        var mon = edp()
        // Asymmetric split (70/30, not 50/50): a symmetric fixture makes the width-ratio check
        // below compare 1.0 against 1.0 no matter what breaks, so nothing could ever move it.
        var wins = [
            { address: "0xA", workspaceId: 1, ax: 0, ay: 26, sw: 1434, sh: 1254,
              floating: false, fullscreen: 0, cls: "a", title: "a" },
            { address: "0xB", workspaceId: 1, ax: 1434, ay: 26, sw: 614, sh: 1254,
              floating: false, fullscreen: 0, cls: "b", title: "b" }
        ]
        var r = Logic.layout({ monitors: [mon],
            workspaces: [{ id: 1, monitorName: "eDP-1", focused: true, occupied: true }],
            windows: wins, focusedMonitorName: "eDP-1", availW: 1632, params: params })
        var b = boxById(r, 1)
        verify(b !== null, "the grid must have a box for workspace 1")
        var pk = Logic.peekTiles(wins, mon, 1200, 750, params)
        compare(pk.length, 2)
        function gridRow(a) {
            for (var i = 0; i < r.tiles.length; i++) if (r.tiles[i].address === a) return r.tiles[i]
            fail("no grid row for " + a); return null
        }
        var ci = params.cellInset
        for (var i = 0; i < pk.length; i++) {
            var g = gridRow(pk[i].address)
            // Each tile's centre as a fraction of its box's INNER rect — scale-invariant, so
            // this compares the arrangement and not raw pixels, and isolates the residual
            // cellInset drift described above instead of the (larger, and here irrelevant)
            // difference between a box's outer and inner aspect. Both axes matter: `reserved`
            // ([0,26,0,0], eDP-1 above) is purely vertical, so a peek that ignores it drifts on y
            // while leaving x untouched, and a fraction-of-x-only comparison is blind to it by
            // construction.
            //
            // Measured on this fixture (the 70/30 split above): correct code drifts 1.09e-3 on x
            // and 0.00000 on y. A peek that ignores `reserved` drifts 1.03e-3 on x (untouched,
            // as expected — x alone cannot see it) and 1.02e-2 on y; one that drops `cellInset`
            // drifts 4.63e-3 on x; one with no letterbox centring drifts 1.09e-3 on x and
            // 7.17e-3 on y. So the x threshold's real headroom over correct code is 0.002 /
            // 1.09e-3 ≈ 1.8x, not the wider margin a rounder number would suggest — worth
            // knowing before tightening it further. Both thresholds clear correct code with that
            // margin and catch all three defects. The x threshold of 0.002 is calibrated to
            // `params.cellInset: 6` above; a future change to that shared value (many other
            // tests use it) would raise correct code's own x drift and should be read as a
            // calibration question for this comment, not as new geometry drift.
            var gfX = (g.x - b.x - ci + g.w / 2) / (b.w - 2 * ci)
            var gfY = (g.y - b.y - ci + g.h / 2) / (b.h - 2 * ci)
            var pfX = (pk[i].x - ci + pk[i].w / 2) / (1200 - 2 * ci)
            var pfY = (pk[i].y - ci + pk[i].h / 2) / (750 - 2 * ci)
            verify(Math.abs(gfX - pfX) < 0.002,
                   pk[i].address + " x centre drifted from the grid: " + gfX + " vs " + pfX)
            verify(Math.abs(gfY - pfY) < 0.005,
                   pk[i].address + " y centre drifted from the grid: " + gfY + " vs " + pfY)
        }
        // The ratio BETWEEN the two tiles' widths, which carries no inset at all and so needs no
        // tolerance beyond rounding. Hoisted out of the loop above: it does not depend on `i`, and
        // inside the loop it silently repeated the same comparison twice.
        verify(Math.abs((pk[0].w / pk[1].w) - (gridRow(pk[0].address).w / gridRow(pk[1].address).w)) < 0.05,
               "tile width ratio must hold across sizes")
    }

    // Distinguishes: an empty workspace returning null/undefined instead of an empty array, which
    // a Repeater turns into a binding error rather than an empty mini-map. The spec makes an
    // empty workspace a legal peek target, so this is a real state, not a defensive check.
    function test_peekTiles_on_an_empty_workspace_returns_an_empty_array() {
        var rows = Logic.peekTiles([], edp(), 1200, 750, params)
        verify(Array.isArray(rows), "must be an array, got " + typeof rows)
        compare(rows.length, 0)
    }

    // Distinguishes: min-clamping dropped at peek scale. A sliver window is widened to minTileW
    // in the grid; at peek size the same clamp must still apply, and the clamped tile must stay
    // inside the box's inset rather than spilling past its right edge.
    function test_peekTiles_clamps_slivers_to_the_minimum_tile_size() {
        var mon = edp()
        var wins = [{ address: "0xS", workspaceId: 1, ax: 2040, ay: 26, sw: 8, sh: 1254,
                      floating: false, fullscreen: 0, cls: "sliver", title: "s" }]
        var rows = Logic.peekTiles(wins, mon, 1200, 750, params)
        compare(rows.length, 1)
        verify(rows[0].w >= params.minTileW, "sliver widened to minTileW")
        verify(rows[0].x + rows[0].w <= 1200 - params.cellInset + 0.01,
               "the widened tile must stay inside the box inset")
    }

    // Distinguishes: a fit that stretches. A 16:9 source in a 16:10 box must letterbox
    // vertically — full width, short of full height — never fill both.
    function test_peekFit_letterboxes_instead_of_stretching() {
        var f = Logic.peekFit(1920, 1080, 1600, 1000)     // 16:9 into 16:10
        compare(Math.round(f.w), 1600, "the constraining axis is filled")
        verify(f.h < 1000, "the other axis is short: " + f.h)
        // The load-bearing assertion: the OUTPUT aspect equals the INPUT aspect. Comparing
        // against the box would pass for a stretch.
        verify(Math.abs((f.w / f.h) - (1920 / 1080)) < 0.001, "aspect preserved, got " + (f.w / f.h))
    }

    // Distinguishes: a fit that upscales past the box on the other axis. Portrait into landscape
    // is the mirror case, and an implementation using max() instead of min() passes the previous
    // test and fails this one.
    function test_peekFit_fits_a_portrait_source_inside_a_landscape_box() {
        var f = Logic.peekFit(1080, 1920, 1600, 1000)
        verify(f.w <= 1600 + 0.001 && f.h <= 1000 + 0.001, "never exceeds the box")
        compare(Math.round(f.h), 1000, "height is the constraining axis")
        verify(Math.abs((f.w / f.h) - (1080 / 1920)) < 0.001, "aspect preserved")
    }

    // Distinguishes: a degenerate monitor (the "?" phantom, scale 0) producing NaN in the peek,
    // the same class of bug that once blanked the whole card (see the phantom test above).
    function test_peekFit_never_yields_NaN() {
        var f = Logic.peekFit(0, 0, 1600, 1000)
        verify(isFinite(f.w) && isFinite(f.h), "got " + f.w + "x" + f.h)
        verify(f.w >= 0 && f.h >= 0)
    }

    // ---- Screen margin (docs/specs/2026-09-18-card-presence-design.md) --------------------
    // Breathing room between the picker and the screen edge. A FRACTION, because the two
    // absolute constants this replaces were sized for a ~1600-logical card and left 10 px on
    // a 1920-logical one (a 4K panel at 2x — the commonest laptop logical width there is).
    function test_screen_margin_is_five_percent_with_a_floor() {
        compare(Logic.screenMargin(1920), 96, "4K at 2x: the reported case")
        compare(Logic.screenMargin(2048), 102, "2560 at 1.25x: 102.4 rounds down")
        compare(Logic.screenMargin(1080), 54, "the vertical axis uses the same function")
        // THE case that discriminates Math.round from Math.floor. Every other width above is
        // either exact (1920 x 0.05 = 96) or rounds the same way under both (102.4, 54.0), so
        // without this line a floor() implementation passes the whole function.
        compare(Logic.screenMargin(1919), 96, "95.95 rounds UP; flooring would give 95")
    }
    // The floor is what keeps a genuinely narrow screen behaving as it does today rather than
    // losing its margin entirely: 5% of 200 is 10, less than the 16 the old constants used.
    function test_screen_margin_floors_at_sixteen() {
        compare(Logic.screenMargin(200), 16, "the floor binds below 320")
        compare(Logic.screenMargin(320), 16, "exactly at the floor's crossover")
    }
    // panel.width is 0 until the surface maps, and a NaN would flow into availW, cell width,
    // every box, the canvas and finally the card — which a Rectangle paints as nothing at all.
    // The same failure mode as the phantom-monitor guard above.
    function test_screen_margin_never_yields_a_non_number() {
        compare(Logic.screenMargin(0), 16, "unmapped surface")
        compare(Logic.screenMargin(-5), 16, "nonsense width")
        compare(Logic.screenMargin(NaN), 16, "NaN must not propagate")
        compare(Logic.screenMargin(undefined), 16, "missing argument")
    }

    // The glass mix behind the wells, checked with REAL theme colours -- which is why it lives
    // here and not in the UI suite: that fixture rewrites every theme token to a flat grey, so
    // "darkens rather than washes" cannot even be expressed there.
    function test_glass_darkens_rather_than_washes() {
        function rgb(h) { return { r: parseInt(h.substr(0,2),16)/255,
                                   g: parseInt(h.substr(2,2),16)/255,
                                   b: parseInt(h.substr(4,2),16)/255 } }
        function lum(c) { return 0.2126*c.r + 0.7152*c.g + 0.0722*c.b }
        var bg = rgb("191724"), accent = rgb("ebbcba")          // rose-pine dark
        verify(lum(accent) > 0.7, "premise: this theme's accent is LIGHT, " + lum(accent))
        verify(lum(bg) < 0.2, "premise: and its background is dark, " + lum(bg))

        var g = Logic.glassMix(bg, accent)
        // THE property. An accent-dominant mix would land near the accent's 0.78 and wash the
        // photograph; this has to stay near the background so it darkens and the numerals read.
        verify(lum(g) < 0.30, "the glass must stay dark, luminance is " + lum(g))
        verify(lum(g) > lum(bg), "but carry a visible tint, not be the plain background")
        verify(Math.abs(lum(g) - lum(bg)) < Math.abs(lum(g) - lum(accent)),
               "and sit far closer to the background than to the accent")

        // A light theme must not invert the logic: the mix follows whatever background it is
        // given, so it darkens or lightens with the theme rather than assuming dark.
        var lightBg = rgb("faf4ed")
        var lg = Logic.glassMix(lightBg, accent)
        verify(lum(lg) > 0.7, "on a light theme the glass stays light, " + lum(lg))
    }

    function test_glass_mix_survives_a_broken_palette() {
        var bg = { r: 0.1, g: 0.1, b: 0.2 }
        var same = Logic.glassMix(bg, null)
        compare(same.r, bg.r, "a missing accent degrades to the plain background")
        var nan = Logic.glassMix(bg, { r: NaN, g: NaN, b: NaN })
        compare(nan.r, bg.r, "and so does a non-finite one, rather than propagating NaN")
        var none = Logic.glassMix(null, null)
        compare(none.r, 0, "no background at all yields black, never undefined")
    }

    // A malformed config is currently SILENT: parseConfig is total, so every setting reverts to
    // its default and nothing says why. This is what lets the user be told. The locks file has
    // had this treatment since it shipped; the config file never adopted it.
    function test_a_broken_config_reports_why() {
        // The cases that must stay quiet. Empty is what a MISSING file looks like by the time
        // apply("") runs, and an empty file legitimately means "use every default" -- reporting
        // either would put a notification in front of most users, who have no config at all.
        compare(Logic.configParseError(""), "", "no file")
        compare(Logic.configParseError("   \n  "), "", "an empty file")
        compare(Logic.configParseError('{}'), "", "an empty object")
        compare(Logic.configParseError('{"scrim":false}'), "", "a valid file")
        compare(Logic.configParseError(undefined), "", "never loaded")

        // ...and the cases that must speak up.
        verify(Logic.configParseError('{"scrim":false,}').length > 0, "a trailing comma")
        verify(Logic.configParseError("not json at all").length > 0, "not JSON")
        verify(Logic.configParseError('{"anchor": "bar"').length > 0, "an unclosed brace")
        // THE cases a truthiness check would miss: these all PARSE, and parseConfig then reads
        // no properties off them and returns every default -- silently, and indistinguishably
        // from an empty file. A user who wrote a JSON array would get no hint at all.
        verify(Logic.configParseError('[1,2,3]').length > 0, "an array parses but is unusable")
        verify(Logic.configParseError('"a string"').length > 0, "so does a bare string")
        verify(Logic.configParseError('42').length > 0, "and a bare number")
        verify(Logic.configParseError('null').length > 0, "and null")
    }

    // The wallpaper path comes from `readlink -f`, so it arrives with a trailing newline and
    // may contain spaces. Everything that is not an absolute path must yield "" -- the view
    // reads that as "no wallpaper" and falls back to a painted colour, which is what it did
    // before wallpaper backing existed.
    function test_wallpaper_url_is_built_defensively() {
        compare(Logic.wallpaperUrl("/home/d/bg.jpg\n"), "file:///home/d/bg.jpg", "readlink's newline")
        compare(Logic.wallpaperUrl("  /home/d/bg.jpg  "), "file:///home/d/bg.jpg", "surrounding space")
        // THE discriminator against a bare "file://" + path: a space in the path would make a
        // URL Qt silently fails to open, and the card would fall back to painting nothing.
        compare(Logic.wallpaperUrl("/home/d/my wall.jpg"), "file:///home/d/my%20wall.jpg", "space encoded")
        compare(Logic.wallpaperUrl("/home/d/a#b.jpg"), "file:///home/d/a%23b.jpg", "fragment char encoded")
        // ...but the path structure must survive: encoding the slashes would break it entirely.
        compare(Logic.wallpaperUrl("/a/b/c.jpg"), "file:///a/b/c.jpg", "slashes are left alone")
        compare(Logic.wallpaperUrl("relative.jpg"), "", "not absolute")
        compare(Logic.wallpaperUrl(""), "", "readlink found nothing")
        compare(Logic.wallpaperUrl("\n"), "", "whitespace only")
        compare(Logic.wallpaperUrl(undefined), "", "never probed")
    }

    // The bar's transparency lives in the SHELL's config, not ours, and the card falls back
    // to the menu ground when it is on. Every failure mode must yield false -- "paint the
    // bar's colour" -- because that is what the code did before this key was consulted.
    function test_shell_bar_transparency_is_read_defensively() {
        compare(Logic.shellBarTransparent('{"bar":{"transparent":true}}'), true, "the real case")
        compare(Logic.shellBarTransparent('{"bar":{"transparent":false}}'), false, "explicitly off")
        compare(Logic.shellBarTransparent('{"bar":{}}'), false, "bar subtree, no key")
        compare(Logic.shellBarTransparent('{}'), false, "no bar subtree")
        compare(Logic.shellBarTransparent('{"bar":"yes"}'), false, "bar is not an object")
        // THE discriminator against a truthy test: only the boolean true counts, so a config
        // written by hand with a string does not silently flip the card's background.
        compare(Logic.shellBarTransparent('{"bar":{"transparent":"true"}}'), false, "string, not bool")
        compare(Logic.shellBarTransparent('{"bar":{"transparent":1}}'), false, "number, not bool")
        compare(Logic.shellBarTransparent('not json'), false, "unparseable")
        compare(Logic.shellBarTransparent(''), false, "missing file")
    }

    // Config keys are validated, never trusted: an unknown value must fall back rather than
    // reach a binding. The "left" case is the one that discriminates real validation from
    // `o.anchor || "center"`, which would happily return "left" and anchor the card nowhere.
    function test_anchor_accepts_only_the_two_known_modes() {
        compare(Logic.parseConfig('{"anchor":"bar"}').anchor, "bar", "the opt-in value")
        compare(Logic.parseConfig('{"anchor":"center"}').anchor, "center", "the default, stated")
        compare(Logic.parseConfig('{"anchor":"left"}').anchor, "center", "unknown value")
        compare(Logic.parseConfig('{"anchor":7}').anchor, "center", "wrong type")
        compare(Logic.parseConfig('{}').anchor, "center", "missing key")
        compare(Logic.parseConfig('not json').anchor, "center", "unparseable file")
    }

    // Fed the REAL output of layout(), not hand-written boxes. That is the whole point: a
    // hand-built input would only prove the function sorts, while saying nothing about whether
    // boxes that share a row actually carry an identical `y`. If layout() ever computed row y
    // per-box instead of from one accumulator, hand-built inputs would keep passing while the
    // stagger tore rows in half on screen.
    function test_row_ranks_come_from_real_layout_rows() {
        var mons = []
        var wss = []
        for (var m = 0; m < 3; m++) {
            mons.push({ name: "M" + m, x: 0, y: m * 1080, width: 1920, height: 1080, scale: 1,
                        reserved: [0, 26, 0, 0], transform: 0 })
            for (var w = 1; w <= 10; w++)
                wss.push({ id: m * 10 + w, monitorName: "M" + m, focused: false, occupied: false })
        }
        // `params` is the TestCase property already defined at the top of this file, and
        // layout() reads it as input.params -- omit it and the call throws rather than fails.
        // There is no availH: layout() takes availW only.
        var out = Logic.layout({ monitors: mons, workspaces: wss, windows: [],
                                 focusedMonitorName: "M0", availW: 1876, params: params })
        var r = Logic.rowRanks(out.boxes)
        // 10 workspaces at maxCols 5 is two sub-rows per monitor, three monitors. Verified by
        // executing logic.js directly: the distinct y values are 28, 246, 498, 716, 968, 1186.
        compare(r.rowCount, 6, "six distinct row y values across the three groups")
        // THE discriminator between global and per-monitor ranking: monitor 1's first sub-row
        // must rank 2, not 0. Rank per group and the stagger restarts at every monitor.
        compare(r.ranks[11], 2, "M1's first sub-row follows M0's two")
        compare(r.ranks[1], 0, "M0's first sub-row is the top one")
        compare(r.ranks[6], 1, "M0's second sub-row")
        // Boxes sharing a row must share a rank exactly -- this is the float-equality claim.
        compare(r.ranks[1], r.ranks[5], "same sub-row, same rank")
    }

    function test_row_ranks_survive_a_degenerate_layout() {
        var r = Logic.rowRanks([])
        compare(r.rowCount, 0, "no boxes")
        compare(JSON.stringify(r.ranks), "{}", "no ranks")
        var bad = Logic.rowRanks([{ workspaceId: 1, y: NaN }, { workspaceId: 2, y: 40 }])
        compare(bad.ranks[1], 0, "a NaN y ranks first rather than propagating")
        compare(bad.rowCount, 1, "only the finite y counts as a row")
    }

    // The stagger's whole observable behaviour. Note what is NOT asserted: any particular
    // duration. The animation's length lives in Overview.qml; this function only decides how a
    // shared 0..1 progress is divided between rows.
    function test_row_phase_staggers_rows_without_lengthening_the_entrance() {
        // THE discriminator. Get the rank wiring backwards, or drop the stride entirely, and
        // every row returns the same phase -- which still animates, and still looks plausible,
        // and is not a stagger at all.
        verify(Logic.rowPhase(0.3, 1, 3) < Logic.rowPhase(0.3, 0, 3), "row 1 lags row 0")
        verify(Logic.rowPhase(0.3, 2, 3) < Logic.rowPhase(0.3, 1, 3), "row 2 lags row 1")
        // Every row completes exactly at the end -- the property that keeps the total fixed
        // however many rows there are.
        for (var k = 0; k < 3; k++) compare(Logic.rowPhase(1, k, 3), 1, "row " + k + " done at 1")
        for (var j = 0; j < 8; j++) compare(Logic.rowPhase(1, j, 8), 1, "8 rows also done at 1")
        // ...and the last row is genuinely still moving just before the end, so "done at 1" is
        // not merely the p >= 1 guard firing early for everyone.
        verify(Logic.rowPhase(0.99, 2, 3) < 1, "the last row is still arriving at 0.99")
        verify(Logic.rowPhase(0.99, 7, 8) < 1, "still true with more rows")
    }

    function test_row_phase_is_total_at_the_ends_and_safe_in_between() {
        compare(Logic.rowPhase(0, 0, 3), 0, "nothing has started")
        compare(Logic.rowPhase(0, 2, 3), 0, "including the last row")
        compare(Logic.rowPhase(0.5, 0, 1), 0.5, "a single row just follows progress")
        // A NaN must leave the grid VISIBLE, not invisible. The opposite default would produce
        // a card that holds keyboard focus while painting nothing -- the same failure mode
        // screenMargin's guard exists to prevent.
        compare(Logic.rowPhase(NaN, 0, 3), 1, "NaN progress")
        compare(Logic.rowPhase(0.5, NaN, 3), Logic.rowPhase(0.5, 0, 3), "NaN rank ranks first")
        compare(Logic.rowPhase(0.5, 0, NaN), 0.5, "NaN rowCount degrades to no stagger")
        compare(Logic.rowPhase(0.5, 99, 3), Logic.rowPhase(0.5, 2, 3), "rank clamps to the last row")
    }

    // The panel's model. SETTING_ORDER must cover the entire schema — this is the assertion
    // that catches drift. The key-set comparison below documents the contract but cannot fail,
    // because the fallback loop guarantees rows.keys == cfg.keys by construction. The fallback's
    // job is to keep a drifted build honest to the user, not to catch drift in CI.
    function test_settings_rows_cover_every_config_key() {
        var cfg = Logic.parseConfig("{}")
        var rows = Logic.settingsRows(cfg)
        var keys = []
        for (var i = 0; i < rows.length; i++) keys.push(rows[i].key)
        var schema = []
        for (var k in cfg) schema.push(k)
        // SETTING_ORDER is the drift detector: it must name every schema key, no more, no less.
        compare(Logic.SETTING_ORDER.slice().sort().join(","),
                schema.slice().sort().join(","),
                "SETTING_ORDER must name every schema key")
        // The key-set assertion documents the contract — every parseConfig key gets exactly one row.
        // It cannot fail because the fallback loop appends rows for any cfg key SETTING_ORDER omits.
        compare(keys.slice().sort().join(","), schema.slice().sort().join(","),
                "every parseConfig key needs a row, and no row may invent one")
        // lockBorder is present but not editable: a colour needs a real picker.
        for (var j = 0; j < rows.length; j++)
            if (rows[j].key === "lockBorder")
                compare(rows[j].editable, false, "lockBorder is shown, not edited")
        // ...and everything else IS editable, or the panel is decorative.
        var editable = rows.filter(function (r) { return r.editable }).length
        compare(editable, rows.length - 1, "seven of the eight must be editable")
    }

    // Every row the panel can land on must be able to say what it is. The panel shows the
    // selection's description with no key to press, so a setting that reached SETTING_ORDER
    // without a SETTING_HELP entry would render as a blank line under a name like "lock frame"
    // -- the exact confusion the description exists to answer. Asserted against SETTING_ORDER
    // and against the built rows, so neither a missing map entry nor a row that drops `help`
    // on the way through settingsRows() can pass.
    function test_every_setting_has_a_description() {
        var missing = []
        for (var i = 0; i < Logic.SETTING_ORDER.length; i++) {
            var k = Logic.SETTING_ORDER[i]
            if (!Logic.SETTING_HELP[k] || String(Logic.SETTING_HELP[k]).length === 0) missing.push(k)
        }
        compare(missing.join(","), "", "every setting needs a description")
        var rows = Logic.settingsRows(Logic.parseConfig("{}")), blank = []
        for (var j = 0; j < rows.length; j++)
            if (!rows[j].help || String(rows[j].help).length === 0) blank.push(rows[j].key)
        compare(blank.join(","), "", "and settingsRows must carry it onto the row")
        // Distinct text, not one string reused: a map built by copying an entry and forgetting
        // to edit it passes every check above.
        var seen = {}, dupes = []
        for (var m = 0; m < rows.length; m++) {
            if (seen[rows[m].help]) dupes.push(rows[m].key)
            seen[rows[m].help] = true
        }
        compare(dupes.join(","), "", "and each description must describe its own setting")
    }

    function test_settings_rows_carry_the_current_values() {
        var rows = Logic.settingsRows(Logic.parseConfig('{"anchor":"bar","scrim":false}'))
        function row(k) { return rows.filter(function (r) { return r.key === k })[0] }
        compare(row("anchor").value, "bar", "a set value is shown, not the default")
        compare(row("scrim").value, false, "including a false boolean, which must not read as unset")
        compare(row("motion").value, "auto", "and an unset one shows its default")
    }

    // Cycling. Every enum wraps in both directions and every stepper clamps -- and the function
    // is TOTAL: anything it does not understand comes back unchanged, because a settings panel
    // that silently rewrites a value it did not recognise is worse than one that does nothing.
    function test_next_setting_value_cycles_and_clamps() {
        compare(Logic.nextSettingValue("anchor", "center", 1), "bar", "two-state forward")
        compare(Logic.nextSettingValue("anchor", "bar", 1), "center", "and wraps")
        compare(Logic.nextSettingValue("anchor", "center", -1), "bar", "backwards wraps too")
        compare(Logic.nextSettingValue("scrim", true, 1), false, "booleans toggle")
        compare(Logic.nextSettingValue("scrim", false, -1), true, "in both directions")
        // THE three-state case: a two-state implementation passes every line above.
        compare(Logic.nextSettingValue("motion", "auto", 1), "full", "three-state steps")
        compare(Logic.nextSettingValue("motion", "full", 1), "off", "through the middle")
        compare(Logic.nextSettingValue("motion", "off", 1), "auto", "and wraps at the end")
        // Steppers CLAMP rather than wrap: wrapping 0 -> 20 on a Left press would be startling.
        compare(Logic.nextSettingValue("workspaces", 10, 1), 11, "steppers step")
        compare(Logic.nextSettingValue("workspaces", 20, 1), 20, "and clamp at the top")
        compare(Logic.nextSettingValue("workspaces", 0, -1), 0, "and at the bottom")
        compare(Logic.nextSettingValue("lockBorderSize", 6, -1), 5, "the other stepper too")
        // Every row the panel renders as EDITABLE must have somewhere to cycle to. Without this, a
        // setting added to the schema and to SETTING_ORDER but forgotten here shows arrows that do
        // nothing -- and `nextSettingValue` being TOTAL means it fails silently rather than throwing.
        var rows = Logic.settingsRows(Logic.parseConfig("{}"))
        var uncovered = []
        for (var i = 0; i < rows.length; i++)
            if (rows[i].editable && !Logic.SETTING_CYCLES[rows[i].key]
                                 && !Logic.SETTING_RANGES[rows[i].key])
                uncovered.push(rows[i].key)
        compare(uncovered.join(","), "", "every editable row needs a cycle or a range")
    }

    function test_next_setting_value_is_total() {
        compare(Logic.nextSettingValue("lockBorder", "rgb(ff4444)", 1), "rgb(ff4444)",
                "a non-editable key is never rewritten")
        compare(Logic.nextSettingValue("nosuchkey", "x", 1), "x", "nor is an unknown one")
        compare(Logic.nextSettingValue("workspaces", NaN, 1), 0, "a non-finite number restarts at 0")
        compare(Logic.nextSettingValue("anchor", "barr", 1), "center",
                "an out-of-set value lands on the first valid one, not on itself")
        compare(Logic.nextSettingValue("anchor", "barr", -1), "center",
                "an out-of-set value recovers in BOTH directions, not just forward")
    }

    // The write payload. Four of these came out of a review that found the first design
    // unsafe, and each one corresponds to a way a real file gets damaged.
    function test_config_with_key_writes_without_losing_the_rest() {
        // The ordinary case, and the one that stops defaults being pinned into the file: only
        // what was there plus the change.
        var out = Logic.configWithKey('{"scrim":false}', "anchor", "bar")
        var back = JSON.parse(out)
        compare(back.anchor, "bar", "the change lands")
        compare(back.scrim, false, "and the existing key survives")
        compare(Object.keys(back).length, 2, "nothing else is added — no pinned defaults")

        // THE guarantee that matters across versions: a key this build has never heard of must
        // not be deleted by it. An older panel must not eat a newer version's setting.
        var future = JSON.parse(Logic.configWithKey('{"futureThing":42}', "anchor", "bar"))
        compare(future.futureThing, 42, "an unknown key survives")

        // A file that does not exist yet.
        compare(JSON.parse(Logic.configWithKey("", "anchor", "bar")).anchor, "bar",
                "an empty file becomes a file with just this key")
        compare(JSON.parse(Logic.configWithKey("   \n ", "anchor", "bar")).anchor, "bar",
                "and so does a whitespace-only one")
    }

    function test_config_with_key_refuses_what_it_cannot_safely_edit() {
        // Verified behaviour, not theory: setting a property on a parsed array is DROPPED by
        // stringify, on null it THROWS, and on a scalar it is dropped. Each would either lose
        // the user's change silently or destroy a file they were mid-way through writing.
        compare(Logic.configWithKey("[1,2]", "anchor", "bar"), "", "a JSON array root")
        compare(Logic.configWithKey("null", "anchor", "bar"), "", "a null root")
        compare(Logic.configWithKey("42", "anchor", "bar"), "", "a scalar root")
        compare(Logic.configWithKey('"a string"', "anchor", "bar"), "", "a string root")
        // ...and the obvious one.
        compare(Logic.configWithKey('{"scrim":false,', "anchor", "bar"), "",
                "a file that does not parse is never overwritten with a guess")

        // A write that cannot be REPRESENTED must be refused, not reported as success. Both of
        // these return a perfectly valid JSON document that simply does not contain the change.
        compare(Logic.configWithKey('{"scrim":false}', "__proto__", "bar"), "",
                "__proto__ sets no own property, so the write would vanish")
        compare(Logic.configWithKey('{"scrim":false}', "anchor", undefined), "",
                "an undefined value is dropped by stringify, so the write would vanish")
    }

    // ---- proportional spacing (docs/specs/2026-09-20-proportional-spacing-design.md) ----

    // Distinguishes: an implementation that reads `gapRatio` unguarded — Number(undefined) is
    // NaN and would poison every width — or one that lets 0, a negative, Infinity, a numeric
    // STRING or `true` switch the ratio model on. Green before the feature exists, on purpose:
    // it is the regression guard for the pixel model every other fixture in this file pins. The
    // second fixture wraps a sub-row, has two monitor groups and shows the scratchpad, so every
    // seam and the scratchpad row are on the guarded path — the single-monitor fixture reaches
    // none of them. The third fixture has no width at all, so the fallback expression is on the
    // path too.
    function test_an_invalid_ratio_leaves_the_pixel_model_untouched() {
        var base = JSON.stringify(fiveOn(1632, params))
        var baseMulti = JSON.stringify(multiWithScratchpad(params))
        var baseNoWidth = JSON.stringify(fiveOn(undefined, params))
        var invalid = [undefined, null, 0, -0.1, NaN, Infinity, -Infinity, "0.08", true, {}]
        for (var i = 0; i < invalid.length; i++) {
            var out = JSON.stringify(fiveOn(1632, withRatio(params, invalid[i])))
            compare(out, base, "invalid[" + i + "] = " + String(invalid[i]) + " must not change the layout")
            compare(JSON.stringify(multiWithScratchpad(withRatio(params, invalid[i]))), baseMulti,
                    "invalid[" + i + "] = " + String(invalid[i]) + " must not change a wrapped, two-monitor, scratchpad layout either")
            compare(JSON.stringify(fiveOn(undefined, withRatio(params, invalid[i]))), baseNoWidth,
                    "invalid[" + i + "] = " + String(invalid[i]) + " must not change the missing-width fallback either")
        }
    }

    // Distinguishes: the real-valued formula the first spec draft carried, which put the 2024
    // and 1820 rows 1-2 px OVER availW (found in review, 2026-09-20), and a fit step that shrinks
    // when it need not (2536 and 3816 take no step and must not lose a pixel).
    function test_ratio_mode_fits_the_row_to_whole_pixels() {
        var rows = [ { availW: 2024, cw: 368, gap: 29, canvas: 2014, h: 230 },   // one fit step
                     { availW: 2536, cw: 462, gap: 37, canvas: 2532, h: 289 },
                     { availW: 3816, cw: 696, gap: 56, canvas: 3816, h: 435 },
                     { availW: 1820, cw: 331, gap: 26, canvas: 1811, h: 207 } ]  // one fit step
        for (var i = 0; i < rows.length; i++) {
            var e = rows[i], r = fiveOn(e.availW), b1 = boxById(r, 1), b2 = boxById(r, 2), b5 = boxById(r, 5)
            var at = "availW " + e.availW + ": "
            compare(b1.w, e.cw, at + "cell width")
            compare(b1.h, e.h, at + "cell height follows the monitor's 1.6 aspect")
            compare(b1.x, e.gap, at + "the first box starts one gap in from the edge")
            compare(b2.x, e.gap + e.cw + e.gap, at + "the second column is one cell and one gap on")
            compare(b5.x + b5.w + e.gap, e.canvas, at + "the last box ends one gap short of the canvas edge")
            compare(r.canvasSize.w, e.canvas, at + "canvas width")
            verify(r.canvasSize.w <= e.availW, at + "the canvas must never be wider than availW")
            assertFinite(r, at)
        }
    }

    // Distinguishes: a column test that forgets the outer gaps — `(availW + gapMin) /
    // (minCellW + gapMin)`, the pixel formula — which gives five columns at 765 and then a row
    // 766 px wide in a 765 px canvas. The integer rule is the largest n with
    // n*140 + (n+1)*11 <= availW: 766 is the first width that seats five.
    function test_column_count_counts_both_outer_gaps() {
        var below = fiveOn(765), above = fiveOn(766)
        compare(firstRowCount(below), 4, "765: four columns")
        compare(boxById(below, 1).w, 173, "765: cells widen to fill four columns")
        compare(below.canvasSize.w, 762, "765: 4*173 + 5*14")
        compare(firstRowCount(above), 5, "766: five columns of the minimum cell")
        compare(boxById(above, 1).w, 140, "766: minCellW")
        compare(above.canvasSize.w, 766, "766: 5*140 + 6*11, exactly the width")
        compare(boxById(above, 1).x, 11, "766: the edge is the minimum gap")
        assertFinite(below, "765"); assertFinite(above, "766")
    }

    // Distinguishes: a fallback that omits the outer gaps (744, the first draft's) — step 2 then
    // resolves FOUR columns at 169 wide instead of five at the minimum — and a fallback that
    // takes 0, a negative or NaN as a width. The output must be the same for every shape of
    // "no width", and it must be the five-column minimum grid the pixel model also falls to.
    function test_a_missing_width_falls_back_to_five_minimum_columns() {
        var shapes = [undefined, 0, -5, NaN, null, "2024"]
        for (var i = 0; i < shapes.length; i++) {
            var r = fiveOn(shapes[i]), at = "availW " + String(shapes[i]) + ": "
            compare(firstRowCount(r), 5, at + "five columns")
            compare(boxById(r, 1).w, 140, at + "minCellW")
            compare(boxById(r, 1).x, 11, at + "one minimum gap in")
            compare(r.canvasSize.w, 766, at + "5*140 + 6*11")
            assertFinite(r, at)
        }
    }

    // Distinguishes: a column floor that lets cols reach 0 — which does not divide by zero but
    // spins layout()'s row loop (s += cols) forever, hanging the runner — and a fit step that
    // shrinks BELOW minCellW to satisfy a width nothing legal fits: at 100 the row is 162 wide
    // and that overflow is the documented behaviour, not a bug to fit away.
    function test_a_width_below_one_minimum_cell_still_lays_out_one_column() {
        var r = fiveOn(100)
        compare(firstRowCount(r), 1, "one column")
        compare(boxById(r, 1).w, 140, "the cell does not go below minCellW")
        compare(boxById(r, 1).x, 11, "one gap in")
        compare(r.canvasSize.w, 162, "140 + 2*11: wider than the 100 it was given, by design")
        compare(r.boxes.length, 5, "all five workspaces are laid out, one per row")
        assertFinite(r, "100")
    }

    // Distinguishes: a missing fit step (some width in 162..4384 overflows — the first draft
    // did at 2024 and 1820) and an over-eager one (a canvas more than 2*cols px short of
    // the width it was given, the most a single strict-condition step can leave behind). Stated once as
    // the property, for every integer width up to 4384, the last width before maxCellW binds
    // (from 4385 the cell pins at 800 and the canvas freezes at 5*800 + 6*64 = 4384), rather than for the widths the table happens to name.
    function test_ratio_mode_never_overflows_and_never_over_shrinks() {
        var worstSlack = 0
        for (var w = 162; w <= 4384; w++) {
            var r = fiveOn(w), cols = firstRowCount(r), canvas = r.canvasSize.w
            if (!isFinite(canvas)) fail("availW " + w + ": canvas is not finite")
            if (canvas > w)
                fail("availW " + w + ": canvas " + canvas + " overflows")
            if (canvas < w - 2 * cols)
                fail("availW " + w + ": canvas " + canvas + " is " + (w - canvas) + " short with " + cols + " columns")
            if (w - canvas > worstSlack) worstSlack = w - canvas
        }
        compare(worstSlack, 10, "five columns leave at most 10 px, at availW 791 (cols 5, cw 143, gap 11, canvas 781)")
    }

    // Distinguishes: an implementation that widened the columns and left a row seam
    // on the 8 px `rowSpacing` — a 5x2 grid 29 px apart sideways and 8 px apart downwards — at
    // any of the three seams: between sub-rows, between monitor groups, and above the
    // scratchpad. With one seam regressed the wrong value is 265, 529 or 798 respectively, each
    // 21 short; with all three it is 265, 508, 756.
    function test_every_row_seam_is_the_ratio_gap() {
        var r = multiWithScratchpad()
        compare(boxById(r, 1).w, 367, "precondition: 2012 / 5.48 floors to 367")
        compare(boxById(r, 1).h, 229, "precondition: eDP row height")
        compare(boxById(r, 7).h, 206, "precondition: HDMI row height (16:9)")
        // group 0: inset 6 + header 22 = 28, first row at 28, second sub-row after 229 + gap 29
        compare(boxById(r, 1).y, 28, "first row sits under the chip band")
        compare(boxById(r, 6).y, 28 + 229 + 29, "the sub-row seam is the gap, not rowSpacing")
        // group 0 ends at 28 + 229 + 29 + 229 + inset 6 = 521; group 1 starts one gap later
        compare(r.groups[0].h, 521, "group 0 height")
        compare(r.groups[1].y, 521 + 29, "the monitor-group seam is the gap")
        // group 1: 28 in, one 206 row, inset 6 -> ends at 550 + 28 + 206 + 6 = 790
        compare(r.groups[1].y + r.groups[1].h, 790, "group 1 bottom")
        compare(r.groups[2].special, "scratchpad", "precondition: the third group is the scratchpad")
        compare(r.groups[2].y, 790 + 29, "the scratchpad seam is the gap")
        assertFinite(r, "multi")
    }

    // Distinguishes: an edge applied to the boxes but not the group backdrops (a backdrop
    // hugging x = 0 while its cells start 29 px in), or to the monitor groups but not the
    // scratchpad row, or a canvas width that forgot to add the edges back. Every group starts
    // one gap in; the canvas is the widest group plus two gaps; the scratchpad cell is centred
    // on that canvas.
    function test_the_edge_frames_every_group_and_the_canvas_reports_it() {
        var r = multiWithScratchpad(), gap = 29, inset = 6
        for (var g = 0; g < r.groups.length; g++)
            compare(r.groups[g].x, gap, "group " + g + " starts one gap in")
        compare(boxById(r, 1).x, gap + inset, "the first cell sits inside the edge and the inset")
        compare(boxById(r, 7).x, gap + inset, "so does the second monitor's")
        var widest = 5 * 367 + 4 * gap + 2 * inset              // 1963
        compare(r.groups[0].w, widest, "group width excludes the edge")
        compare(r.canvasSize.w, widest + 2 * gap, "the canvas adds one gap each side: 2021")
        verify(r.canvasSize.w <= 2024, "and still fits the width it was given")
        var s = boxById(r, Logic.SCRATCHPAD_ID)
        compare(s.x + s.w / 2, r.canvasSize.w / 2, "the scratchpad cell is centred on the canvas")
        compare(r.groups[2].w, widest, "the scratchpad row spans the widest group")
        compare(r.canvasSize.h, r.groups[2].y + r.groups[2].h, "the canvas ends with the scratchpad row, 1082")
        compare(r.canvasSize.h, 1082, "the canvas ends with the scratchpad row")
    }

    // Distinguishes: a cap applied AFTER the fit — the gap would then be 8% of the UNCAPPED
    // 1094, putting the first cell 88 px in and the canvas at 4528 — or a cap that stopped
    // binding altogether when the formula changed (cw 1094, x 88, canvas 5998). At 6000 the
    // cell stops at 800, the gap at 64, and the 1616 px left over is slack for the Flickable
    // to centre — the one path that still produces real slack.
    function test_max_cell_width_caps_the_cell_and_leaves_the_rest_as_slack() {
        var r = fiveOn(6000)
        compare(boxById(r, 1).w, 800, "capped")
        compare(boxById(r, 1).x, 64, "gap is 8% of the CAPPED width")
        compare(r.canvasSize.w, 5 * 800 + 6 * 64, "4384: the canvas does not stretch to fill the 6000 it was given")
        assertFinite(r, "6000")
    }
}
