import QtQuick
import QtTest
import "../logic.js" as Logic

TestCase {
    name: "Layout"

    readonly property var params: ({
        maxCols: 5, minCellW: 140, maxCellW: 380, cellInset: 6, cellSpacing: 8,
        rowSpacing: 12, headerH: 22, groupInset: 6, minTileW: 8, minTileH: 6, slotGapTolerance: 24
    })

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
                { address: "0xL", workspaceId: 1, ax: 400, ay: 300, sw: 300, sh: 200,
                  floating: true, fullscreen: 0, cls: "floaty", title: "floaty" }
            ],
            focusedMonitorName: "eDP-1", availW: 1632, params: params })
        function row(a) {
            for (var i = 0; i < r.tiles.length; i++) if (r.tiles[i].address === a) return r.tiles[i]
            fail("no tile row for " + a); return null
        }
        var f = row("0xF"), rt = row("0xR"), fl = row("0xL")
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
}
