import QtQuick
import QtTest

TestCase {
    id: tc
    name: "Drag"
    when: windowShown
    width: 1200; height: 800; visible: true
    property var view
    property var client
    Component { id: overview; Overview {} }
    // Emulates the shell's per-plugin panel Loader (shell.qml:623-626): active while the
    // manifest says keepLoaded, or while the shell has this id in openPanelIds (`open` here).
    Component { id: shellLikeLoader
        Loader {
            property bool open: false
            Manifest { id: manifest }
            active: manifest.keepLoaded || open
            sourceComponent: overview
        }
    }
    SignalSpy { id: boxesSpy; signalName: "boxesChanged" }   // rebuild() assigns root.boxes a fresh array each call
    // Compositor fixture shared by init() and any test that drives its own Overview instance
    // (e.g. through shellLikeLoader) instead of the `view` init() creates.
    function seed(v) {
        var mon = {name:"TEST", x:0, y:1440, width:1920, height:1080,
                   scale:1, lastIpcObject:{reserved:[0,26,0,0],transform:0}}
        client = {address:"0x123", at:[100,1540], size:[600,400], floating:false,
                  title:"Test", "class":"test", fullscreen:0}
        v.compositor.monitors = {values:[mon]}
        v.compositor.focusedMonitor = mon
        v.compositor.focusedWorkspace = {id:1}
        v.compositor.workspaces = {values:[
            {id:1,monitor:mon,toplevels:{values:[{lastIpcObject:client}]}},
            {id:2,monitor:mon,toplevels:{values:[]}}
        ]}
    }
    function init() {
        view = createTemporaryObject(overview, tc)
        verify(view !== null)
        view.motion.scale = 0     // instant by default; timing tests set it to 1 themselves
        seed(view)
        view.open()
        wait(400)      // past the 200 ms entrance and the 300 ms open-settle window, with slack
        // Lock plumbing (Component.onCompleted + open()) dispatches install chunks that are not
        // under test here; drop them so command-count assertions see only the test's own action.
        view.compositor.commands = []
    }
    function cleanup() { view.close() }
    function tileOf(addr) {
        var children = view.testCanvas.children
        for (var i=0;i<children.length;i++)
            if (children[i].model && children[i].model.address === addr) return children[i]
        fail("Tile not found: " + addr)
    }
    function tile() { return tileOf("0x123") }
    function dragBy(dx, dy) {
        var t = tile(), p = t.mapToItem(tc, t.width/2, t.height/2)
        mousePress(tc, p.x, p.y, Qt.LeftButton)
        mouseMove(tc, p.x + 12, p.y + 2, 20)
        mouseMove(tc, p.x + dx, p.y + dy, 20)
        mouseRelease(tc, p.x + dx, p.y + dy, Qt.LeftButton)
    }
    function test_float_toggle_updates_existing_tile() {
        client.floating = true
        view.rebuild()
        compare(view.testModel.get(0).floating, true)
        dragBy(35, 20)
        verify(view.compositor.commands.some(function(c) {return c.indexOf('x = "') >= 0}),
               "Floating drag must dispatch a coordinate move after toggling")
    }
    function test_drop_survives_stale_refresh() {
        client.floating = true
        // Recreate the row so this test isolates pending geometry from floating-role refresh.
        view.testModel.clear(); view.rebuild()
        var before = tile().x
        dragBy(35, 20)
        var dropped = tile().x
        verify(dropped > before + 10, "Tile must move with the pointer")
        view.rebuild()
        compare(tile().x, dropped, "Stale geometry must not undo a pending drop")
    }
    function test_cancel_restores_drag_state() {
        var t=tile(), p=t.mapToItem(tc,t.width/2,t.height/2)
        mousePress(tc,p.x,p.y,Qt.LeftButton)
        mouseMove(tc,p.x+12,p.y+2,20)
        mouseMove(tc,p.x+35,p.y+20,20)
        view.close()
        mouseRelease(tc,p.x+35,p.y+20,Qt.LeftButton)
        compare(t.x,view.testModel.get(0).wx)
        verify(t.z < 100, "Cancel must restore tile stacking")
        compare(view.compositor.commands.length,0,"Closing mid-drag must not dispatch a drop")
    }
    function test_acknowledgement_releases_pending_geometry() {
        client.floating = true; view.rebuild()
        dragBy(35,20)
        var pending = view.pendingMoves[client.address]
        verify(pending !== undefined)
        client.at = [pending.pos.x,pending.pos.y]
        view.rebuild()
        verify(view.pendingMoves[client.address] === undefined)
        client.at = [200,1600]; view.rebuild()
        verify(Math.abs(tile().x - view.testModel.get(0).wx) < 0.01)
    }
    function test_rejected_move_times_out() {
        client.floating = true; view.rebuild()
        var before = tile().x
        dragBy(35,20)
        view.pendingMoves[client.address].deadline = Date.now()-1
        view.rebuild()
        compare(tile().x,before)
        verify(view.pendingMoves[client.address] === undefined)
    }
    function test_cross_workspace_floating_move_is_one_dispatch() {
        client.floating = true; view.rebuild()
        dragBy(view.boxes[1].x-view.boxes[0].x,20)
        compare(view.compositor.commands.length,1,"transfer and positioning are one atomic chunk")
        var cmd=view.compositor.commands[0]
        verify(cmd.indexOf('workspace = "2"')>=0, "transfer to workspace 2")
        verify(cmd.indexOf('x = "')>=0, "position is in the same chunk")
        verify(cmd.indexOf('workspace = "2"') < cmd.indexOf('x = "'), "transfer before positioning")
        var dropped = tile().x
        view.rebuild(); compare(tile().x,dropped,"stale geometry must not undo the optimistic drop")
        var ws = view.compositor.workspaces.values
        ws[0].toplevels.values=[]
        ws[1].toplevels.values=[{lastIpcObject:client}]
        view.rebuild()
        compare(view.compositor.commands.length,1,"no second phase once the transfer lands")
        compare(tile().x,dropped)
        var p=view.pendingMoves[client.address].pos
        client.at=[p.x,p.y]; view.rebuild()
        verify(view.pendingMoves[client.address] === undefined, "acknowledged by geometry")
        compare(view.testModel.get(0).wsid,2)
    }
    function test_outside_drop_does_not_move_floating_window() {
        client.floating=true; view.rebuild()
        var before=tile().x
        dragBy(-160,0)
        compare(view.compositor.commands.length,0)
        compare(tile().x,before)
    }
    function test_window_closing_mid_drag_cancels() {
        var t=tile(), p=t.mapToItem(tc,t.width/2,t.height/2)
        mousePress(tc,p.x,p.y,Qt.LeftButton)
        mouseMove(tc,p.x+12,p.y+2,20)
        mouseMove(tc,p.x+35,p.y+20,20)
        verify(view.draggingAddress !== "")
        view.compositor.workspaces.values[0].toplevels.values=[]
        view.rebuild()
        compare(view.draggingAddress,"")
        compare(view.dropTargetWs,-1)
        compare(view.testModel.count,0)
        mouseRelease(tc,p.x+35,p.y+20,Qt.LeftButton)
        compare(view.compositor.commands.length,0)
    }
    function test_edge_scroll_keeps_tile_under_pointer() {
        var ws=view.compositor.workspaces.values
        for (var i=3;i<=45;i++) ws.push({id:i,monitor:ws[0].monitor,toplevels:{values:[]}})
        view.rebuild()
        var t=tile(), p=t.mapToItem(tc,t.width/2,t.height/2)
        var edge=view.testFlick.mapToItem(tc,100,view.testFlick.height-4)
        mousePress(tc,p.x,p.y,Qt.LeftButton)
        mouseMove(tc,p.x+12,p.y+2,20)
        mouseMove(tc,edge.x,edge.y,20)
        var before=view.testFlick.contentY
        // The grab point is the ghost's scale origin, so it is invariant under the in-transit
        // shrink animation and is exactly the point that must stay under the pointer.
        var visual=t.mapToItem(tc,t.grabX,t.grabY)
        wait(100)
        verify(view.testFlick.contentY > before, "Holding near the edge must scroll")
        var after=t.mapToItem(tc,t.grabX,t.grabY)
        verify(Math.abs(visual.y-after.y)<1, "Scrolling must keep the tile under the pointer")
        view.close()
        mouseRelease(tc,edge.x,edge.y,Qt.LeftButton)
        var stopped=view.testFlick.contentY
        wait(50); compare(view.testFlick.contentY,stopped)
    }

    function test_second_drop_uses_actual_source_workspace() {
        client.floating=true; view.rebuild()
        var b=view.boxes[1]
        // The tile may already show workspace 2 while the real transfer is pending.
        view.testModel.setProperty(0,"wsid",2)
        view.submitDrop(client.address,2,b.x+30,b.y+30)
        verify(view.compositor.commands[0].indexOf('workspace = "2", follow = false') >= 0,
               "a transfer is dispatched because the real source is workspace 1")
    }

    function test_app_class_refreshes_existing_tile() {
        var original = tile()
        compare(original.cls, "test")
        client["class"] = "updated-app"
        client.title = "Updated title"
        view.rebuild()
        compare(view.testModel.count, 1)
        compare(tile(), original, "Metadata refresh must preserve the tile instance")
        compare(original.cls, "updated-app", "Fallback icon must follow updated app identity")
        compare(original.title, "Updated title")
    }

    function addTarget(ws) {
        var other={address:"0x456",at:[1000,1540],size:[600,400],floating:false,
                   title:"Other", "class":"test",fullscreen:0}
        view.compositor.workspaces.values[ws-1].toplevels.values.push({lastIpcObject:other})
        view.rebuild()
        return other
    }
    function dragOntoTarget(ws) {
        var source=view.testModel.get(0), target=view.testModel.get(1)
        dragBy(target.wx-source.wx+12,target.wy-source.wy+2)
    }
    // Size-agnostic alternative to dragOntoTarget: releases exactly on the target tile's centre
    // (canvas-space) instead of a left-edge delta, which assumes near-equal tile sizes and
    // overshoots when they are not (e.g. a fullscreen window's recovered slot vs. an ordinary
    // tile).
    function dragToCentreOf(targetIndex) {
        var target = view.testModel.get(targetIndex)
        var t = tile(), p = t.mapToItem(tc, t.width/2, t.height/2)
        mousePress(tc, p.x, p.y, Qt.LeftButton)
        mouseMove(tc, p.x + 12, p.y + 2, 20)
        var goal = view.testCanvas.mapToItem(tc, target.wx + target.ww/2, target.wy + target.wh/2)
        mouseMove(tc, goal.x, goal.y, 20)
        mouseRelease(tc, goal.x, goal.y, Qt.LeftButton)
    }
    // A tiled drop replays a native drag-and-drop as ONE atomic Lua dispatch (float → cursor →
    // un-float); nothing else is sent, and the tile holds the drop point until the compositor's
    // fresh geometry differs from the pre-drop one.
    function test_tiled_drop_replays_native_insert_in_one_dispatch() {
        addTarget(1)
        dragOntoTarget(1)
        compare(view.compositor.commands.length,1)
        var cmd=view.compositor.commands[0]
        verify(cmd.indexOf('hl.dsp.window.float(')>=0)
        verify(cmd.indexOf('hl.dsp.cursor.move(')>=0)
        verify(cmd.indexOf('"address:0x123"')>=0)
        verify(cmd.indexOf('smart_split = true')>=0)
        verify(cmd.indexOf('window.swap')<0)
        var pending=view.pendingMoves[client.address]
        verify(pending !== undefined && pending.pos === null)
        var shown=tile().x
        view.rebuild()
        compare(tile().x,shown,"Stale geometry must not undo the optimistic drop")
        client.at=[1000,1540]; view.rebuild()   // the compositor re-tiled it
        verify(view.pendingMoves[client.address] === undefined)
        compare(view.compositor.commands.length,1,"No follow-up dispatch after the atomic insert")
    }
    function test_tiled_drag_previews_insertion_side() {
        addTarget(1)
        var source=view.testModel.get(0), target=view.testModel.get(1)
        var t=tile(), p=t.mapToItem(tc,t.width/2,t.height/2)
        mousePress(tc,p.x,p.y,Qt.LeftButton)
        mouseMove(tc,p.x+12,p.y+2,20)
        // hover the right quarter of the target tile, vertically centred → "right"
        var dx=(target.wx+target.ww*0.9)-(source.wx+source.ww/2)
        var dy=(target.wy+target.wh/2)-(source.wy+source.wh/2)
        mouseMove(tc,p.x+dx,p.y+dy,20)
        compare(view.dropTargetAddress,"0x456")
        compare(view.dropTargetSide,"right")
        // and the top edge → "top"
        mouseMove(tc,p.x+(target.wx+target.ww/2)-(source.wx+source.ww/2),p.y+(target.wy+2)-(source.wy+source.wh/2),20)
        compare(view.dropTargetSide,"top")
        view.close()
        mouseRelease(tc,p.x+dx,p.y+dy,Qt.LeftButton)
        compare(view.dropTargetSide,"")
    }
    function test_tiled_cross_workspace_inserts_in_one_dispatch() {
        addTarget(2)
        dragOntoTarget(2)
        compare(view.compositor.commands.length,1)
        var cmd=view.compositor.commands[0]
        verify(cmd.indexOf('workspace = "2"')>=0)
        verify(cmd.indexOf('hl.dsp.window.float(')>=0)
        compare(view.testModel.get(0).wsid,2,"tile shows the target workspace at once")
        var ws=view.compositor.workspaces.values
        ws[0].toplevels.values=[]
        client.at=[400,1540]
        ws[1].toplevels.values.push({lastIpcObject:client})
        view.rebuild()
        compare(Object.keys(view.pendingMoves).length,0)
        compare(view.compositor.commands.length,1,"No follow-up dispatch after the atomic insert")
        compare(view.testModel.get(0).wsid,2)
    }
    function test_lone_tiled_window_dropped_in_own_workspace_snaps_back() {
        var other=addTarget(1);other.floating=true;view.rebuild()
        var before=tile().x
        dragOntoTarget(1)
        compare(view.compositor.commands.length,0)
        compare(tile().x,before)
    }
    function test_ghost_shrinks_and_fades_while_dragging_and_restores() {
        view.motion.scale = 1
        var t=tile(), p=t.mapToItem(tc,t.width/2,t.height/2)
        mousePress(tc,p.x,p.y,Qt.LeftButton)
        mouseMove(tc,p.x+12,p.y+2,20)
        mouseMove(tc,p.x+40,p.y+20,20)
        wait(200)
        fuzzyCompare(t.opacity,0.6,0.02,"translucent in transit")
        fuzzyCompare(t.ghostScale,0.6,0.02,"shrunk in transit")
        mouseRelease(tc,p.x+40,p.y+20,Qt.LeftButton)
        wait(200)
        fuzzyCompare(t.opacity,1,0.02,"opaque after release")
        fuzzyCompare(t.ghostScale,1,0.02,"full size after release")
    }
    // The pointer picks the target and side, not the ghost's centre: grab the tile at its
    // right edge (so the ghost's centre trails well left of the pointer, further still by the
    // drag threshold) and point at the target's RIGHT quarter — centre-based targeting would
    // say "left".
    function test_pointer_not_ghost_centre_picks_target_and_side() {
        addTarget(1)
        var target=view.testModel.get(1), t=tile()
        var g=t.mapToItem(tc,t.width-4,4)
        mousePress(tc,g.x,g.y,Qt.LeftButton)
        mouseMove(tc,g.x+12,g.y+2,20)
        var goal=view.testCanvas.mapToItem(tc,target.wx+target.ww*0.9,target.wy+target.wh/2)
        mouseMove(tc,goal.x,goal.y,20)
        compare(view.dropTargetAddress,"0x456")
        compare(view.dropTargetSide,"right")
        verify(t.x+t.width/2 < target.wx+target.ww/2, "ghost centre is on the target's left half")
        view.close()
        mouseRelease(tc,goal.x,goal.y,Qt.LeftButton)
    }
    // Re-grabbing while the release animation (motion.fast, 90 ms) is still running must not shift the tile:
    // the Scale origin moves to the new grab point while the scale is still on its way back
    // to 1, which would displace the rendered tile by (grab − oldOrigin)·(1 − scale).
    function test_regrab_during_release_animation_keeps_grab_point_under_pointer() {
        view.motion.scale = 1
        var t=tile(), g=t.mapToItem(tc,t.width-4,4)   // first grab: right edge
        mousePress(tc,g.x,g.y,Qt.LeftButton)
        mouseMove(tc,g.x+12,g.y+2,20)
        mouseMove(tc,g.x+30,g.y+10,20)
        mouseRelease(tc,g.x+30,g.y+10,Qt.LeftButton)
        wait(30)                                        // release animation in flight
        verify(t.ghostScale < 0.98, "precondition: still animating back to full size")
        var g2=t.mapToItem(tc,4,4)                      // second grab: left edge, as rendered now
        mousePress(tc,g2.x,g2.y,Qt.LeftButton)
        var p=t.mapToItem(tc,t.grabX,t.grabY)
        fuzzyCompare(p.x,g2.x,1,"grab point under the pointer right after the press")
        fuzzyCompare(p.y,g2.y,1)
        mouseMove(tc,g2.x+12,g2.y+2,20)                 // activates the drag
        var off=t.mapToItem(tc,t.grabX,t.grabY)
        var offX=off.x-(g2.x+12), offY=off.y-(g2.y+2)
        mouseMove(tc,g2.x+40,g2.y+16,20)
        wait(120)                                       // let the shrink animation finish
        var after=t.mapToItem(tc,t.grabX,t.grabY)
        fuzzyCompare(after.x-(g2.x+40),offX,1,"no jump-back when the drag activates or animates")
        fuzzyCompare(after.y-(g2.y+16),offY,1)
        view.close()
        mouseRelease(tc,g2.x+40,g2.y+16,Qt.LeftButton)
    }
    // A drag that never leaves the window's own slot is a no-op on release, so it must not
    // preview an insertion into another tile either: preview and release share one check.
    function test_short_drag_inside_own_slot_previews_nothing_and_dispatches_nothing() {
        addTarget(1)
        var t=tile(), p=t.mapToItem(tc,t.width/2,t.height/2)
        mousePress(tc,p.x,p.y,Qt.LeftButton)
        mouseMove(tc,p.x+12,p.y+2,20)
        mouseMove(tc,p.x+20,p.y+6,20)
        compare(view.dropTargetWs,1,"still over its own workspace")
        compare(view.dropTargetAddress,"","no anchor while inside the own slot")
        compare(view.dropTargetSide,"")
        mouseRelease(tc,p.x+20,p.y+6,Qt.LeftButton)
        compare(view.compositor.commands.length,0,"release must not dispatch")
        verify(view.pendingMoves[client.address] === undefined)
    }
    // The dispatched Lua names the anchor and the side the preview showed; the point is
    // measured inside the compositor after detaching, not taken from the overview's layout.
    function test_tiled_drop_dispatches_previewed_anchor_and_side() {
        addTarget(1)
        var target=view.testModel.get(1), t=tile(), p=t.mapToItem(tc,t.width/2,t.height/2)
        mousePress(tc,p.x,p.y,Qt.LeftButton)
        mouseMove(tc,p.x+12,p.y+2,20)
        var goal=view.testCanvas.mapToItem(tc,target.wx+target.ww/2,target.wy+target.wh-2)
        mouseMove(tc,goal.x,goal.y,20)
        compare(view.dropTargetAddress,"0x456")
        compare(view.dropTargetSide,"bottom")
        mouseRelease(tc,goal.x,goal.y,Qt.LeftButton)
        compare(view.compositor.commands.length,1)
        var cmd=view.compositor.commands[0]
        verify(cmd.indexOf('"address:0x456"')>=0,"anchor identity is passed to Lua")
        verify(cmd.indexOf('== "bottom" then')>=0,"side is passed to Lua")
        verify(cmd.indexOf('hl.get_window(anchorSel)')>=0,"anchor geometry is measured in Lua")
    }
    function test_grouped_tiled_window_is_not_retiled() {
        addTarget(1); client.grouped=["0x123"]; view.rebuild()
        dragOntoTarget(1)
        compare(view.compositor.commands.length,0)
    }
    // Hover a floating drag over a workspace whose only window is fullscreen (its preview fills
    // the well, hiding the well tint): the drop wash must show on that box, above the preview.
    function test_floating_drag_over_fullscreen_workspace_shows_wash_above_preview() {
        client.floating=true
        var full={address:"0x456",at:[0,1440],size:[1920,1080],floating:false,
                  title:"Full","class":"test",fullscreen:1}
        view.compositor.workspaces.values[1].toplevels.values.push({lastIpcObject:full})
        view.rebuild()
        var wash=view.testDropWash, b=view.boxes[1]
        verify(!wash.visible,"no wash before a drag")
        var t=tile(), p=t.mapToItem(tc,t.width/2,t.height/2)
        mousePress(tc,p.x,p.y,Qt.LeftButton)
        mouseMove(tc,p.x+12,p.y+2,20)
        var goal=view.testCanvas.mapToItem(tc,b.x+b.w/2,b.y+b.h/2)
        mouseMove(tc,goal.x,goal.y,20)
        compare(view.dropTargetWs,2)
        verify(wash.visible,"wash shows over the target box")
        compare(wash.x,b.x); compare(wash.y,b.y); compare(wash.width,b.w)
        var children=view.testCanvas.children, fullTile=null
        for (var i=0;i<children.length;i++)
            if (children[i].model && children[i].model.address==="0x456") fullTile=children[i]
        verify(fullTile!==null && wash.z > fullTile.z,"wash stacks above the fullscreen preview")
        view.close()
        mouseRelease(tc,goal.x,goal.y,Qt.LeftButton)
        verify(!wash.visible,"wash gone after release")
    }
    // A tiled drag with an insertion preview keeps the cue on the anchor tile: no wash.
    function test_tiled_drag_with_insertion_preview_shows_no_wash() {
        addTarget(1)
        var target=view.testModel.get(1), t=tile(), p=t.mapToItem(tc,t.width/2,t.height/2)
        mousePress(tc,p.x,p.y,Qt.LeftButton)
        mouseMove(tc,p.x+12,p.y+2,20)
        var goal=view.testCanvas.mapToItem(tc,target.wx+target.ww*0.9,target.wy+target.wh/2)
        mouseMove(tc,goal.x,goal.y,20)
        compare(view.dropTargetAddress,"0x456")
        verify(!view.testDropWash.visible,"insertion preview replaces the wash")
        view.close()
        mouseRelease(tc,goal.x,goal.y,Qt.LeftButton)
    }
    function canvasItems(name) {
        var out=[], children=view.testCanvas.children
        for (var i=0;i<children.length;i++) if (children[i].objectName===name) out.push(children[i])
        return out
    }
    // Every workspace carries a number badge stacked above its previews; the big numeral
    // shows only on empty workspaces, where nothing can hide it.
    function test_badge_on_every_box_above_tiles_numeral_only_when_empty() {
        var badges=canvasItems("wsBadge")
        compare(badges.length, view.boxes.length, "one badge per workspace box")
        var t=tile()
        for (var i=0;i<badges.length;i++) {
            var b=view.boxForWs(badges[i].model.workspaceId)
            verify(badges[i].visible)
            verify(badges[i].x >= b.x && badges[i].y >= b.y, "badge sits inside its box")
            verify(badges[i].z > t.z, "badge stacks above a resting tile")
        }
        var numerals=[], boxes=view.testCanvas.children
        for (var j=0;j<boxes.length;j++) {
            var kids=boxes[j].children||[]
            for (var k=0;k<kids.length;k++) if (kids[k].objectName==="wsNumeral") numerals.push(kids[k])
        }
        compare(numerals.length, 2)
        verify(!numerals[0].visible, "occupied workspace 1 hides the big numeral")
        verify(numerals[1].visible, "empty workspace 2 shows the big numeral")
    }
    function shadowOf(t) {
        for (var i=0;i<t.children.length;i++) if (t.children[i].objectName==="floatShadow") return t.children[i]
        fail("floatShadow not found")
    }
    // Only floating windows cast a shadow, and never while they are the drag ghost.
    function test_floating_tile_shadow_follows_role_and_hides_in_transit() {
        var t=tile()
        verify(!shadowOf(t).visible, "tiled window: no shadow")
        client.floating=true; view.rebuild()
        verify(shadowOf(t).visible, "floating window: shadow")
        var p=t.mapToItem(tc,t.width/2,t.height/2)
        mousePress(tc,p.x,p.y,Qt.LeftButton)
        mouseMove(tc,p.x+12,p.y+2,20)
        mouseMove(tc,p.x+30,p.y+10,20)
        verify(!shadowOf(t).visible, "no shadow under the drag ghost")
        view.close()
        mouseRelease(tc,p.x+30,p.y+10,Qt.LeftButton)
    }

    // The floating window is the FIRST model entry, the tiled one is appended later (a later
    // sibling paints on top by default). Without a layer-based z the floating tile is hidden.
    function test_floating_tile_stacks_above_later_tiled_tile() {
        client.floating = true; view.rebuild()
        addTarget(1)                               // tiled, index 1
        var floating = tileOf("0x123"), tiled = tileOf("0x456")
        verify(floating.z > tiled.z, "floating z " + floating.z + " must exceed tiled z " + tiled.z)
        compare(view.testModel.get(0).layer, 2); compare(view.testModel.get(1).layer, 1)
        compare(view.testModel.get(0).fsPending, false)
        compare(view.testModel.get(1).fullscreen, 0)
    }
    // Hover raises a tile within its layer only: a hovered tiled tile stays below a floating one.
    function test_hovered_tiled_tile_stays_below_floating() {
        client.floating = true; view.rebuild()
        addTarget(1)
        var floating = tileOf("0x123"), tiled = tileOf("0x456")
        var away = tiled.mapToItem(tc, -30, -30), p = tiled.mapToItem(tc, tiled.width/2, tiled.height/2)
        mouseMove(tc, away.x, away.y, 20)
        mouseMove(tc, p.x, p.y, 20)
        tryVerify(function () { return tiled.z === 11 }, 500)          // hovered within layer 1
        verify(floating.z > tiled.z, "floating z " + floating.z + " must exceed hovered tiled z " + tiled.z)
        mouseMove(tc, away.x, away.y, 20)
        tryVerify(function () { return tiled.z === 10 }, 500)
    }

    function badgeOf(addr) {
        var t = tileOf(addr), kids = t.children
        for (var i=0;i<kids.length;i++) if (kids[i].objectName === "fsBadge") return kids[i]
        fail("badge not found")
    }
    // The badge shows on a fullscreen tile; clicking it dispatches ONE guarded un-fullscreen
    // chunk, never a drag or a focus, hides the badge optimistically, and leaves no drag state.
    function test_badge_click_unfullscreens_without_drag_or_focus() {
        client.fullscreen = 2; view.rebuild()
        addTarget(1)
        var badge = badgeOf("0x123")
        verify(badge.visible, "badge shown while fullscreen")
        var p = badge.mapToItem(tc, badge.width/2, badge.height/2)
        mouseClick(tc, p.x, p.y, Qt.LeftButton)
        compare(view.compositor.commands.length, 1)
        var cmd = view.compositor.commands[0]
        verify(cmd.indexOf('hl.dsp.window.fullscreen(') >= 0)
        verify(cmd.indexOf('"address:0x123"') >= 0)
        verify(cmd.indexOf('nowW.address ~= prevW.address') >= 0, "focus restored only if it moved")
        compare((cmd.match(/hl\.dsp\.focus\(/g) || []).length, 1, "exactly one (guarded) focus dispatch")
        verify(cmd.indexOf('window.float(') < 0, "not a drag")
        compare(view.draggingAddress, "", "a badge press never starts a drag")
        verify(view.pendingFullscreen["0x123"] !== undefined)
        verify(!badge.visible, "badge hidden while pending")
        view.rebuild()                                   // stale data: still fullscreen 2
        verify(!badge.visible, "stays hidden until confirmed")
        client.fullscreen = 0; view.rebuild()
        verify(view.pendingFullscreen["0x123"] === undefined, "confirmed by fresh data")
        verify(!badge.visible, "now hidden because the window is no longer fullscreen")
    }
    function test_badge_returns_when_unfullscreen_is_rejected() {
        client.fullscreen = 2; view.rebuild()
        var badge = badgeOf("0x123"), p = badge.mapToItem(tc, badge.width/2, badge.height/2)
        mouseClick(tc, p.x, p.y, Qt.LeftButton)
        verify(!badge.visible)
        view.pendingFullscreen["0x123"].deadline = Date.now() - 1
        view.rebuild()
        verify(view.pendingFullscreen["0x123"] === undefined)
        verify(badge.visible, "rejected: the window is still fullscreen, badge back")
    }
    // A new grab (mousePress on the tile body) supersedes a pending un-fullscreen for that
    // address, exactly as it supersedes a pending move: the badge returns immediately.
    function test_grab_supersedes_pending_unfullscreen() {
        client.fullscreen = 2; view.rebuild()
        var badge = badgeOf("0x123"), p = badge.mapToItem(tc, badge.width/2, badge.height/2)
        mouseClick(tc, p.x, p.y, Qt.LeftButton)
        verify(view.pendingFullscreen["0x123"] !== undefined, "un-fullscreen pending")
        verify(!badge.visible, "badge hidden while pending")
        var t = tileOf("0x123"), body = t.mapToItem(tc, 8, t.height - 8)   // bottom-left, away from the badge
        mousePress(tc, body.x, body.y, Qt.LeftButton)
        verify(view.pendingFullscreen["0x123"] === undefined, "grab clears the pending un-fullscreen")
        verify(badge.visible, "badge shown again once the pending entry is cleared")
        view.close()                                    // release would focus+close; not under test here
        mouseRelease(tc, body.x, body.y, Qt.LeftButton)
    }
    // A plain click on the tile body still focuses + closes and does not touch fullscreen.
    function test_tile_body_click_on_fullscreen_tile_focuses_only() {
        client.fullscreen = 2; view.rebuild()
        var t = tileOf("0x123"), p = t.mapToItem(tc, 8, t.height - 8)     // bottom-left, away from the badge
        mouseClick(tc, p.x, p.y, Qt.LeftButton)
        compare(view.compositor.commands.length, 1)
        verify(view.compositor.commands[0].indexOf('hl.dsp.focus(') >= 0)
        verify(view.compositor.commands[0].indexOf('fullscreen') < 0)
    }
    // A middle click on the badge must be swallowed, not fall through to the drag area's
    // close-window branch. Contrast with a middle click on the tile body, which still closes.
    function test_middle_click_on_badge_does_not_close_window() {
        client.fullscreen = 2; view.rebuild()
        var badge = badgeOf("0x123"), p = badge.mapToItem(tc, badge.width/2, badge.height/2)
        mouseClick(tc, p.x, p.y, Qt.MiddleButton)
        compare(view.compositor.commands.length, 0, "middle click on the badge must not close the window")
        var t = tileOf("0x123"), body = t.mapToItem(tc, 8, t.height - 8)
        mouseClick(tc, body.x, body.y, Qt.MiddleButton)
        compare(view.compositor.commands.length, 1)
        verify(view.compositor.commands[0].indexOf('window.close(') >= 0, "middle click on the tile body still closes")
    }

    // A fullscreen window can be re-tiled inside its own workspace (previously refused): one
    // atomic insert that records and re-applies fullscreen, acknowledged as soon as the ANCHOR's
    // geometry changes — the window itself ends fullscreen in the same rect, so its own
    // geometry cannot be the signal.
    function test_fullscreen_window_retile_acknowledged_by_anchor_geometry() {
        client.fullscreen = 2; view.rebuild()
        var other = addTarget(1)
        // dragOntoTarget's left-edge delta assumes source and target tiles are near-equal in
        // size; the fullscreen window's recovered slot is not (it's the whole uncovered band),
        // so release exactly on the target's centre instead (canvas-space, size-agnostic).
        dragToCentreOf(1)
        compare(view.compositor.commands.length, 1, "re-tile dispatched (was refused before)")
        var cmd = view.compositor.commands[0]
        verify(cmd.indexOf('ownMode') >= 0 && cmd.indexOf('hl.dsp.window.fullscreen(') >= 0)
        var pending = view.pendingMoves[client.address]
        verify(pending !== undefined && pending.before.anchor.address === "0x456")
        view.rebuild()                                     // nothing changed yet
        verify(view.pendingMoves[client.address] !== undefined, "still pending on stale data")
        other.at = [1000, 1740]; other.size = [600, 200]   // the anchor got split
        view.rebuild()
        verify(view.pendingMoves[client.address] === undefined, "anchor change acknowledges")
    }
    // dragOntoTarget's left-edge delta overshoots for this geometry (lands in workspace 2, not
    // 1), so use dragToCentreOf and assert the drop actually landed where intended and reached
    // pending.before before exercising the deadline path.
    function test_retile_pending_kept_until_deadline_when_nothing_changes() {
        client.fullscreen = 2; view.rebuild()
        addTarget(1)
        dragToCentreOf(1)
        var pending = view.pendingMoves[client.address]
        verify(pending !== undefined && pending.workspaceId === 1, "landed in the target's workspace")
        verify(pending.before.anchor.address === "0x456", "reached pending.before")
        view.rebuild(); view.rebuild()
        verify(view.pendingMoves[client.address] !== undefined)
        view.pendingMoves[client.address].deadline = Date.now() - 1
        view.rebuild()
        verify(view.pendingMoves[client.address] === undefined)
    }
    // A fullscreen tile is an ordinary anchor: a tiled window dropped on it previews a side and
    // dispatches the insert (previously the fullscreen tile was excluded from the candidates).
    function test_fullscreen_tile_is_an_anchor() {
        var other = addTarget(1); other.fullscreen = 2; view.rebuild()
        var target = view.testModel.get(1)
        var t = tile(), p = t.mapToItem(tc, t.width/2, t.height/2)
        mousePress(tc, p.x, p.y, Qt.LeftButton)
        mouseMove(tc, p.x+12, p.y+2, 20)
        var goal = view.testCanvas.mapToItem(tc, target.wx + target.ww*0.9, target.wy + target.wh/2)
        mouseMove(tc, goal.x, goal.y, 20)
        compare(view.dropTargetAddress, "0x456", "fullscreen tile previews as an anchor")
        compare(view.dropTargetSide, "right")
        mouseRelease(tc, goal.x, goal.y, Qt.LeftButton)
        compare(view.compositor.commands.length, 1)
        verify(view.compositor.commands[0].indexOf('"address:0x456"') >= 0)
    }
    // Same-workspace eligibility uses the tile's model rect (the recovered slot), not
    // _tileRect(win) — which for a fullscreen window is the whole cell and would swallow every
    // drop as "inside its own slot". Real fullscreen-sized geometry on the client (not the
    // stale pre-fullscreen at/size) so _tileRect(win) WOULD span the cell if used.
    function test_fullscreen_window_own_slot_is_the_recovered_slot() {
        client.at = [0, 1466]; client.size = [1920, 1054]
        client.fullscreen = 2; view.rebuild()
        addTarget(1)
        var own = view.tileRectFor("0x123"), target = view.testModel.get(1)
        verify(own.h < view.boxes[0].h - 2 * view.params.cellInset - 1, "recovered slot, not the whole cell")
        var plan = view.tiledDropPlan("0x123", view._windowByAddress["0x123"], 1,
                                      target.wx + target.ww/2, target.wy + target.wh/2)
        verify(plan !== null && plan.anchor === "0x456")
    }
    // A backdrop tile (fullscreen with no recoverable slot — another window already covers the
    // whole usable rect) never anchors a drop: it has no slot geometry for the split-side hit
    // test to work against.
    // A backdrop tile (fullscreen window whose slot is unrecoverable: its neighbours cover the
    // usable rect) is drawn over the whole cell but must never anchor. Its rect ties with the
    // tiled half under the pointer at distance 0, and tiledDropPlan gives ties to the LATER
    // candidate — so without the layer-0 exclusion the fullscreen window (appended last) wins.
    function test_backdrop_tile_does_not_anchor() {
        var ws = view.compositor.workspaces.values, mon = ws[0].monitor
        ws[0].toplevels.values = []                    // the dragged window lives on workspace 2
        ws[1].toplevels.values = [{lastIpcObject: client}]
        function win(addr, at, size, fs) {
            return {lastIpcObject: {address: addr, at: at, size: size, floating: false,
                                    title: addr, "class": "test", fullscreen: fs}}
        }
        ws[0].toplevels.values = [win("0xA", [0, 1466], [960, 1054], 0),
                                  win("0xB", [960, 1466], [960, 1054], 0),
                                  win("0xF", [0, 1440], [1920, 1080], 2)]
        view.rebuild()
        var byAddr = {}
        for (var i = 0; i < view.testModel.count; i++) byAddr[view.testModel.get(i).address] = view.testModel.get(i)
        compare(byAddr["0xF"].layer, 0, "precondition: the fullscreen tile is a backdrop")
        compare(byAddr["0xA"].layer, 1)
        var t = tileOf("0x123"), p = t.mapToItem(tc, t.width/2, t.height/2)
        mousePress(tc, p.x, p.y, Qt.LeftButton)
        mouseMove(tc, p.x + 12, p.y + 2, 20)
        var A = byAddr["0xA"]
        var goal = view.testCanvas.mapToItem(tc, A.wx + A.ww/2, A.wy + A.wh/2)
        mouseMove(tc, goal.x, goal.y, 20)
        compare(view.dropTargetWs, 1)
        compare(view.dropTargetAddress, "0xA", "the tiled half anchors, never the backdrop")
        view.close()
        mouseRelease(tc, goal.x, goal.y, Qt.LeftButton)
    }

    // Coalescing must never drop the refresh for an event that arrives after the last refresh
    // was requested: that request cannot contain the change the new event announces.
    function test_event_after_a_refresh_gets_its_own_refresh_within_a_tick() {
        wait(400)                         // open()'s settle window has ended
        view.compositor.refreshes = 0
        view.compositor.rawEvent({})      // leading edge: refresh at once
        compare(view.compositor.refreshes, 1)
        wait(10)
        view.compositor.rawEvent({})      // mid-stream: a second refresh is owed
        wait(100)
        compare(view.compositor.refreshes, 2, "the later event must trigger another refresh")
    }
    // Raw compositor events faster than the settle interval must not starve the rebuild, and
    // must not fan out into one refresh request per event.
    function test_event_flood_still_rebuilds_and_throttles_refresh() {
        boxesSpy.target = view; boxesSpy.clear()
        view.compositor.refreshes = 0
        for (var i = 0; i < 20; i++) { view.compositor.rawEvent({}); wait(25) }   // 500 ms stream
        verify(boxesSpy.count >= 5, "rebuilt during the flood (got " + boxesSpy.count + ")")
        verify(view.compositor.refreshes <= 10, "at most one refresh per settle tick (got " + view.compositor.refreshes + ")")
        var after = boxesSpy.count
        wait(400)
        verify(boxesSpy.count > after, "settles after the stream ends")
        var settled = boxesSpy.count
        wait(400)
        compare(boxesSpy.count, settled, "timer stops after five quiet ticks")
    }
    function threeWorkspaces() {
        var mon = view.compositor.monitors.values[0]
        view.compositor.workspaces = {values:[
            {id:1,monitor:mon,toplevels:{values:[{lastIpcObject:client}]}},
            {id:2,monitor:mon,toplevels:{values:[]}},
            {id:3,monitor:mon,toplevels:{values:[]}}
        ]}
        view.rebuild()
    }
    // Selection is a workspace, not a position: when a preceding workspace disappears the
    // selected id must survive the rebuild.
    // A config edit while the picker is open must re-lay the wells at once, with no
    // compositor event and after the settle ticks are long gone.
    function test_workspaces_config_change_rebuilds_while_open() {
        compare(view.boxes.length, 2)
        view.testConfig.workspaces = 10
        compare(view.boxes.length, 10, "padded wells appear on the config change itself")
        compare(canvasItems("wsBox").length, 10)
        view.testConfig.workspaces = 0
        compare(view.boxes.length, 2, "and disappear again when padding is turned off")
    }
    // The focused group's backdrop belongs to the card: it must stay through the exit fade
    // (panel still visible) instead of vanishing the moment close() drops `opened`.
    function test_group_backdrop_survives_exit_fade() {
        var a = view.compositor.monitors.values[0]
        var b = {name:"EXT", x:0, y:0, width:1920, height:1080, scale:1,
                 lastIpcObject:{reserved:[0,0,0,0],transform:0}}
        view.compositor.monitors = {values:[a, b]}
        view.compositor.workspaces.values.push({id:6, monitor:b, toplevels:{values:[]}})
        view.rebuild()
        compare(view.groups.length, 2)
        compare(canvasItems("groupBackdrop").length, 2, "one backdrop item per group")
        view.motion.scale = 1                  // a real fade, so the panel outlives `opened`
        view.close()
        verify(view.testPanel.visible, "panel still up for the exit fade")
        compare(canvasItems("groupBackdrop").length, 2, "backdrops still present during the fade")
        tryVerify(function () { return !view.testPanel.visible }, 2000)
        compare(canvasItems("groupBackdrop").length, 0, "gone once the panel unmaps")
    }
    function test_selection_keeps_workspace_when_earlier_one_vanishes() {
        threeWorkspaces()
        view.selectByNav("right")
        compare(view.selectedId, 2)
        view.compositor.workspaces.values.splice(0, 1)   // workspace 1 destroyed
        view.rebuild()
        compare(view.selectedId, 2, "still workspace 2, not whatever now sits at index 1")
    }
    // When the selected workspace itself disappears, fall back to the nearest position.
    function test_selection_falls_back_when_selected_workspace_vanishes() {
        threeWorkspaces()
        view.selectByNav("right"); view.selectByNav("right")
        compare(view.selectedId, 3)
        view.compositor.workspaces.values.splice(2, 1)   // workspace 3 destroyed
        view.rebuild()
        compare(view.selectedId, 2, "clamped to the last box")
    }

    // ---- motion vocabulary ----

    // `off` zeroes every duration and disables every Behavior: selection snaps, and the
    // window hides the instant it closes (no exit fade to wait for).
    function test_motion_off_zeroes_every_duration_and_skips_animation() {
        view.motion.scale = 1
        view.testConfig.motionEffective = "off"
        compare(view.motion.fast, 0); compare(view.motion.normal, 0)
        compare(view.motion.enter, 0); compare(view.motion.exit, 0)
        verify(!view.motion.enabled)
        view.selectByNav("right")
        compare(view.testFrame.x, view.boxes[1].x, "selection snaps")
        view.close()
        verify(!view.testPanel.visible, "hidden at once")
    }
    // With motion on, the keyboard selection frame glides: half-way through motion.normal
    // it is strictly between the two boxes, and it lands exactly.
    function test_selection_frame_glides_between_boxes() {
        view.motion.scale = 1
        var f = view.testFrame, b0 = view.boxes[0], b1 = view.boxes[1]
        compare(f.x, b0.x)
        view.selectByNav("right")
        wait(80)
        verify(f.x > b0.x + 1 && f.x < b1.x - 1, "half-way: between the boxes, x=" + f.x)
        wait(200)
        compare(f.x, b1.x)
    }
    // The frame dims while a drag is in progress, via motion.fast (instant here: scale 0).
    function test_selection_frame_recedes_during_drag() {
        var t=tile(), p=t.mapToItem(tc,t.width/2,t.height/2)
        compare(view.testFrame.opacity, 1)
        mousePress(tc,p.x,p.y,Qt.LeftButton)
        mouseMove(tc,p.x+12,p.y+2,20)
        mouseMove(tc,p.x+30,p.y+10,20)
        fuzzyCompare(view.testFrame.opacity, 0.4, 0.01)
        view.close()
        mouseRelease(tc,p.x+30,p.y+10,Qt.LeftButton)
    }

    // ---- open / close ----

    // Closing starts an exit fade: the surface stays mapped (opened=false, still visible)
    // until the card's opacity reaches 0, then hides.
    function test_window_stays_visible_through_the_exit_fade() {
        view.motion.scale = 1
        view.close()
        verify(!view.opened)
        verify(view.testPanel.visible, "still mapped while the card fades")
        verify(view.testCard.opacity > 0 && view.testCard.opacity <= 1)
        wait(250)
        verify(!view.testPanel.visible, "hidden once the fade ends")
        compare(view.testCard.opacity, 0)
        compare(view.testScrim.opacity, 0)
    }
    // Opening animates in: the card is not yet opaque right after open() and is after the
    // entrance; the scrim follows.
    function test_open_fades_and_scales_the_card_in() {
        view.motion.scale = 1
        view.close(); wait(250)
        view.open()
        verify(view.testCard.opacity < 1, "entrance in flight")
        verify(view.testCard.scale < 1, "scales up from 0.96")
        wait(350)
        compare(view.testCard.opacity, 1); compare(view.testCard.scale, 1)
        compare(view.testScrim.opacity, 1)
    }
    // The card's content must not vanish at the start of the fade: boxes, badges and tiles
    // are still there while opened is already false.
    function test_card_content_stays_through_the_exit_fade() {
        view.motion.scale = 1
        view.close()
        compare(canvasItems("wsBadge").length, view.boxes.length, "badges still present")
        compare(canvasItems("wsBox").length, view.boxes.length, "boxes still present")
        verify(tile().visible)
        wait(250)
    }
    // Pointer handlers must go dead the instant `opened` drops, not once the fade finishes:
    // a click on a box during the exit must not dispatch a jump.
    function test_clicks_during_the_exit_fade_are_ignored() {
        view.motion.scale = 1
        view.close()
        var b = view.boxes[1]
        var p = view.testCanvas.mapToItem(tc, b.x + b.w / 2, b.y + b.h / 2)
        mouseClick(tc, p.x, p.y, Qt.LeftButton)
        wait(250)
        compare(view.compositor.commands.length, 0, "no jump dispatched during the exit fade")
    }
    // Finding 1 (PR #10 review): shell.hide() calls close() and only then drops the id from
    // openPanelIds; the shell's own panel Loader stays active across that only if the manifest
    // says keepLoaded (shell.qml:480-495, 623-626) — otherwise the component is destroyed the
    // instant close() returns and the exit fade never gets to play.
    // Goes red if manifest.json ever reverts to keepLoaded: false: the emulated Loader would
    // then deactivate on `loader.open = false` and loader.item would go null before the fade.
    function test_shell_toggle_close_keeps_the_component_alive_for_the_exit_fade() {
        var loader = createTemporaryObject(shellLikeLoader, tc)
        loader.open = true
        tryVerify(function() { return loader.item !== null })
        var item = loader.item
        seed(item)
        item.motion.scale = 1
        item.open()
        wait(350)
        // Emulate shell.hide(): close() first, then the shell drops the id from openPanelIds.
        item.close()
        loader.open = false
        verify(loader.item !== null && loader.status === Loader.Ready,
               "component survives the shell's hide")
        verify(item.testPanel.visible, "surface still mapped for the fade")
        verify(item.testCard.opacity > 0)
        wait(250)
        verify(!item.testPanel.visible)
        // Re-summon through the same path: shell sets openPanelIds[id] = true, then calls open().
        loader.open = true
        item.open()
        verify(item.opened, "re-summon through the same path works")
    }
    // Finding 2 (PR #10 review): motionEffective can flip to "off" mid-entrance (a late
    // Hyprland probe, or a config edit); the already-running enterAnim must not keep going.
    // Red before change D: opacity sits around 0.5 at the 50ms mark instead of snapping to 1.
    function test_late_probe_result_off_settles_the_entrance() {
        view.motion.scale = 1
        view.close(); wait(250)
        view.open()
        wait(30)
        verify(view.testCard.opacity < 1, "precondition: entrance in flight")
        view.testConfig.motionEffective = "off"
        wait(20)
        compare(view.testCard.opacity, 1)
        compare(view.testCard.scale, 1)
        compare(view.testScrim.opacity, 1)
        verify(!view.testEnterAnim.running)
        view.close()
        verify(!view.testPanel.visible, "with motion off, close hides at once")
    }
    // Finding 2 (PR #10 review), motionResolved half: motion must not start on a guess. While
    // the first Hyprland probe hasn't answered, open() places the card at its final values with
    // no entrance; once the probe resolves, only the *next* transition animates — a late
    // resolution does not retroactively start an entrance for the one already placed.
    // Red before change C: the fixture's OmascapeConfig has no motionResolved (TypeError), or
    // once the stub carries one but Overview.qml does not gate on it (opacity < 1 while
    // unresolved).
    function test_motion_waits_for_the_first_probe() {
        view.motion.scale = 1
        view.close(); wait(250)
        view.testConfig.motionResolved = false
        view.open()
        compare(view.testCard.opacity, 1, "unresolved policy: placed, not animated")
        verify(!view.testEnterAnim.running)
        view.testConfig.motionResolved = true
        wait(20)
        compare(view.testCard.opacity, 1, "a late 'on' does not start a retroactive entrance")
        view.close()
        verify(view.testPanel.visible, "…but the next transition animates")
        wait(250)
        verify(!view.testPanel.visible)
    }
    // ---- boxes model ----
    function boxItem(ws) {
        var c = view.testCanvas.children
        for (var i = 0; i < c.length; i++)
            if (c[i].objectName === "wsBox" && c[i].model && c[i].model.workspaceId === ws) return c[i]
        fail("box " + ws + " not found")
    }
    // Boxes are reconciled in place like tiles: an identical rebuild keeps the delegate
    // instance, a new workspace adds one, a vanished workspace removes one and the survivors
    // move into the freed column.
    function test_box_delegates_are_reconciled_not_recreated() {
        var b2 = boxItem(2)
        view.rebuild()
        compare(boxItem(2), b2, "identical rebuild keeps the instance")
        var ws = view.compositor.workspaces.values
        ws.push({id:3, monitor: ws[0].monitor, toplevels:{values:[]}}); view.rebuild()
        compare(canvasItems("wsBox").length, 3)
        compare(canvasItems("wsBadge").length, 3, "badges follow the same model")
        compare(boxItem(2), b2, "adding a workspace keeps the others")
        var b3 = boxItem(3)
        compare(b3.x, view.boxes[2].x)
        ws.splice(1, 1); view.rebuild()           // workspace 2 disappears
        compare(canvasItems("wsBox").length, 2)
        compare(boxItem(3), b3, "the survivor is the same instance")
        compare(b3.x, view.boxes[1].x, "…in the freed column")
        compare(b3.width, view.boxes[1].w)
    }

    // ---- reconcile motion ----

    // Direct manipulation is never animated: once the drag is active, each pointer move is
    // reflected in x exactly — even when the grab interrupts a glide in progress, whose
    // animation must stop writing the moment the drag writes.
    function test_dragged_tile_follows_pointer_exactly_even_when_grabbed_mid_glide() {
        view.motion.scale = 1
        var t = tile(), x0 = t.x
        view.testModel.setProperty(0, "wx", x0 + 80)      // a reconcile move: the glide starts
        wait(40)
        verify(t.x > x0 + 1 && t.x < x0 + 79, "precondition: mid-glide, x=" + t.x)
        var p = t.mapToItem(tc, t.width/2, t.height/2)
        mousePress(tc, p.x, p.y, Qt.LeftButton)
        mouseMove(tc, p.x+12, p.y+2, 20)
        mouseMove(tc, p.x+40, p.y+16, 20)
        var xa = t.x
        wait(100)
        compare(t.x, xa, "the interrupted glide never writes again")
        mouseMove(tc, p.x+50, p.y+16, 20)
        compare(t.x, xa + 10, "exactly the pointer delta")
        view.close()
        mouseRelease(tc, p.x+50, p.y+16, Qt.LeftButton)
    }
    // After a release the tile settles by gliding to whatever geometry the reconcile hands
    // back (here: a rejected move returning to the authoritative position) — never a jump.
    function test_tile_settles_by_gliding_after_release() {
        view.motion.scale = 1
        client.floating = true; view.rebuild()
        var t = tile(), before = t.x
        dragBy(35, 20)
        var dropX = t.x
        verify(dropX > before + 10, "held at the drop point, x=" + dropX)
        view.pendingMoves[client.address].deadline = Date.now() - 1
        view.rebuild()                                     // rejected → wx returns to `before`
        compare(view.testModel.get(0).wx, before)
        verify(Math.abs(t.x - dropX) < 1, "glide starts from the drop point, x=" + t.x)
        wait(60)
        verify(t.x > before + 1 && t.x < dropX - 1, "half-way, x=" + t.x)
        wait(220)
        compare(t.x, before)
    }
    // A rebuild that changes nothing produces no motion: x and width hold still.
    function test_identical_rebuild_produces_no_motion() {
        view.motion.scale = 1
        var t = tile(), x = t.x, w = t.width, b2 = boxItem(2), bx = b2.x
        view.rebuild(); view.rebuild()
        wait(30)
        compare(t.x, x); compare(t.width, w); compare(b2.x, bx)
        wait(100)
        compare(t.x, x); compare(t.width, w); compare(b2.x, bx)
    }
    // Layout glides must not start while the picker is closed: `_reconcileStep` and friends
    // keep rebuilding after close, and a glide begun then would still be running (Behaviors
    // don't stop an in-flight transition) if the picker reopens within its duration.
    function test_no_layout_motion_starts_while_closed() {
        view.motion.scale = 1
        view.close(); wait(250)
        view.testModel.setProperty(0, "wx", view.testModel.get(0).wx + 80)
        compare(tile().x, view.testModel.get(0).wx, "placed, not glided, while closed")
        view.open(); wait(350)                              // leave the fixture clean
    }
    // Live-shell bug: mapping the PanelWindow is synchronous and can land ~40ms after `opened`
    // flips true, changing panel.width and firing a synchronous rebuild before the entrance even
    // starts. That rebuild must place at the new layout, not glide from the previous one — the
    // entrance gate (`!enterAnim.running`) doesn't cover this gap; only openSettle does.
    function test_layout_change_while_the_surface_maps_places_not_glides() {
        view.motion.scale = 1
        view.close(); wait(250)
        var b2 = boxItem(2), f = view.testFrame
        // Emulate the width arriving mid-map: the instant `opened` flips true, widen the panel
        // (a real shell would have this land from the compositor while mapping the surface).
        function widen() { if (view.opened) { view.testPanel.width = 900; view.openedChanged.disconnect(widen) } }
        view.openedChanged.connect(widen)
        view.open()
        compare(b2.x, view.boxes[1].x, "box placed at the new layout")
        compare(f.x, view.boxes[view.selectedIndex].x, "frame placed")
        wait(80)
        compare(b2.x, view.boxes[1].x, "box still placed, not mid-glide")
        compare(f.x, view.boxes[view.selectedIndex].x, "frame still placed, not mid-glide")
        wait(300)
    }
    // Boxes and badges glide into the freed column when a workspace disappears; the tile
    // inside a moving box glides with it (same Behavior, same duration).
    function test_boxes_badges_and_tiles_glide_when_a_workspace_disappears() {
        view.motion.scale = 1
        var ws = view.compositor.workspaces.values
        ws.push({id:3, monitor: ws[0].monitor, toplevels:{values:[]}}); view.rebuild()
        var other = addTarget(3)                            // a window on workspace 3
        var b3 = boxItem(3), from = b3.x, badges = canvasItems("wsBadge"), badge3 = badges[badges.length - 1]
        compare(badge3.model.workspaceId, 3)
        var children = view.testCanvas.children, t3 = null
        for (var i = 0; i < children.length; i++)
            if (children[i].model && children[i].model.address === "0x456") t3 = children[i]
        var tFrom = t3.x
        ws.splice(1, 1); view.rebuild()                     // workspace 2 disappears
        var to = view.boxes[1].x, tTo = view.testModel.get(1).wx
        verify(to < from && tTo < tFrom)
        wait(80)
        verify(b3.x < from - 1 && b3.x > to + 1, "box half-way, x=" + b3.x)
        verify(badge3.x < from + 6 - 1 && badge3.x > to + 6 + 1, "badge half-way")
        verify(t3.x < tFrom - 1 && t3.x > tTo + 1, "tile half-way, x=" + t3.x)
        wait(200)
        compare(b3.x, to); compare(badge3.x, to + 6); compare(t3.x, tTo)
    }
    // The card resizes with a glide when the canvas grows (a second row of workspaces).
    function test_card_size_glides_when_the_layout_grows() {
        view.motion.scale = 1
        var card = view.testCard, h0 = card.implicitHeight
        var ws = view.compositor.workspaces.values
        for (var i = 3; i <= 8; i++) ws.push({id:i, monitor: ws[0].monitor, toplevels:{values:[]}})
        view.rebuild()
        var h1 = view.testCanvas.implicitHeight + 2 * card.pad + card.hintSpace
        verify(h1 > h0 + 20, "precondition: a second row")
        verify(card.implicitHeight < h1 - 1, "glide in flight, h=" + card.implicitHeight)
        wait(250)
        fuzzyCompare(card.implicitHeight, Math.min(h1, card.maxCardH), 0.5)
    }

    // ---- drop cues and appearance ----

    // The workspace-level wash fades in over the target and fades out after release; it keeps
    // its last geometry while fading out (no slide to 0,0).
    function test_drop_wash_fades_in_and_out() {
        view.motion.scale = 1
        client.floating = true; view.rebuild()
        var wash = view.testDropWash, b = view.boxes[1]
        var t = tile(), p = t.mapToItem(tc, t.width/2, t.height/2)
        mousePress(tc, p.x, p.y, Qt.LeftButton)
        mouseMove(tc, p.x+12, p.y+2, 20)
        var goal = view.testCanvas.mapToItem(tc, b.x + b.w/2, b.y + b.h/2)
        mouseMove(tc, goal.x, goal.y, 20)
        wait(40)
        verify(wash.opacity > 0 && wash.opacity < 1, "fading in, o=" + wash.opacity)
        wait(150)
        compare(wash.opacity, 1)
        view.close()
        mouseRelease(tc, goal.x, goal.y, Qt.LeftButton)
        wait(40)
        verify(wash.opacity > 0 && wash.opacity < 1, "fading out, o=" + wash.opacity)
        compare(wash.x, b.x, "keeps the last box while fading out")
        wait(150)
        compare(wash.opacity, 0); verify(!wash.visible)
    }
    function insertHalfOf(t) {
        for (var i = 0; i < t.children.length; i++)
            if (t.children[i].objectName === "insertHalf") return t.children[i]
        fail("insertHalf not found")
    }
    // The tiled-insert half on the anchor tile fades in, and keeps its side while fading out.
    function test_insertion_half_fades_and_keeps_its_side_while_fading_out() {
        view.motion.scale = 1
        addTarget(1)
        var target = view.testModel.get(1), t = tile(), p = t.mapToItem(tc, t.width/2, t.height/2)
        var children = view.testCanvas.children, anchor = null
        for (var i = 0; i < children.length; i++)
            if (children[i].model && children[i].model.address === "0x456") anchor = children[i]
        var half = insertHalfOf(anchor)
        mousePress(tc, p.x, p.y, Qt.LeftButton)
        mouseMove(tc, p.x+12, p.y+2, 20)
        var goal = view.testCanvas.mapToItem(tc, target.wx + target.ww*0.9, target.wy + target.wh/2)
        mouseMove(tc, goal.x, goal.y, 20)
        compare(view.dropTargetSide, "right")
        wait(40)
        verify(half.opacity > 0 && half.opacity < 0.45, "fading in, o=" + half.opacity)
        wait(150)
        fuzzyCompare(half.opacity, 0.45, 0.01)
        view.close()
        mouseRelease(tc, goal.x, goal.y, Qt.LeftButton)
        compare(view.dropTargetSide, "")
        wait(40)
        verify(half.opacity > 0, "still fading out")
        compare(half.x, anchor.width / 2, "keeps the right half while fading out")
        wait(150)
        compare(half.opacity, 0); verify(!half.visible)
    }
    // A window opened while the picker is showing fades and scales its tile in.
    function test_new_window_while_open_fades_and_scales_in() {
        view.motion.scale = 1
        var other = addTarget(2)
        var children = view.testCanvas.children, nt = null
        for (var i = 0; i < children.length; i++)
            if (children[i].model && children[i].model.address === "0x456") nt = children[i]
        verify(nt !== null)
        verify(nt.opacity < 1, "appears from transparent, o=" + nt.opacity)
        verify(nt.scale < 1, "appears from 0.9, s=" + nt.scale)
        wait(60)
        verify(nt.opacity > 0.05 && nt.opacity < 0.95, "mid-way: still fading, o=" + nt.opacity)
        verify(nt.appearScale > 0.905 && nt.appearScale < 0.995, "mid-way: still scaling, s=" + nt.appearScale)
        wait(300)
        compare(nt.opacity, 1); compare(nt.appearScale, 1)
    }
    // Tiles created by the first layout at open do not animate in: the entrance covers that.
    function test_tiles_present_at_open_do_not_animate_in() {
        view.motion.scale = 1
        view.close(); wait(250)
        view.testModel.clear()
        view.open()
        var t = tile()
        compare(t.opacity, 1); compare(t.appearScale, 1)
        wait(350)
    }
}
