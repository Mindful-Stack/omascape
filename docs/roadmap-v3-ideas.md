# Omascape v3 — ideas & roadmap (research-backed)

Date: 2026-09-09 · Post-v2. Synthesised from research across macOS, Windows, Linux DEs,
Wayland tiling-WM overviews, and Quickshell/AGS peers. Each idea is rated **easy / medium /
hard** for a Quickshell/QML overlay.

## The five wishlist items → recommended approach

### 1. Larger tiles — *strong cross-platform consensus*
Replace the fixed 160×100 grid: size cells as a function of screen size + workspace/monitor
count, biased toward **fewer, bigger, legible** cells (niri, hyprexpo, Windows Task View all
do this). Enforce a **minimum legible size** and **scroll/paginate** rather than shrink to
postage stamps ("grid density regret" is a repeated, real complaint). — **easy–medium**;
biggest felt improvement. Lever lives in `logic.js` (`params.cellW/cellH` are constants today).
- *Optional/deferred:* a KDE-style **strip-packing / justified** declutter layout gives even
  bigger tiles but **abandons real relative position** (our differentiator) — opt-in/heuristic
  only. Cheaper middle ground: KDE's old "Natural" pass that **nudges only overlapping windows
  apart**, preserving base position. Whatever packs, **preserve relative window-size ratios**
  (uneven scaling was the #1 complaint that killed KDE's old algorithm).

### 2. Rearrange windows *within* a workspace — split by window type
(end-4 does exactly this; it also explains the current "always lands bottom-right" bug — there
is no reposition dispatch at all yet.)
- **Floating** windows → `movewindowpixel exact <x%> <y%>,address:..` (convert drop point to %
  of the workspace). This is literally end-4's within-box drag.
- **Tiled** windows → **drop one window onto another = swap**: `swapwindow` /
  `layoutmsg swapsplit` (dwindle) or `swapwithmaster` / `swapnext` (master). **No Quickshell
  peer does this** — a genuine differentiator. Branch on `.floating` from `hyprctl clients`.
- Caveat: `movewindow`/`swapwindow` semantics are **layout-dependent and version-flaky**
  (hyprwm/Hyprland#2804); test against the user's actual layout, and reuse the v2 post-move
  reconcile (IPC lag is real). — **medium**.

### 3. Distinguish which screen — use the reserved row header
`rowLabelH` (16px) is reserved in the layout math but renders nothing today. Fill it with a
**monitor name/number chip + a per-row accent color**; optionally order rows to mirror the
physical monitor arrangement. Bonus passive cue: render **empty workspaces as a cropped
wallpaper thumbnail** (each monitor's wallpaper differs). — **easy**.

### 4. Style / polish
- Rounded `ScreencopyView` via **`ClippingRectangle`** (GPU clip, cheaper than end-4's
  OpacityMask shader) or `MultiEffect{maskEnabled}`.
- Soft **selection glow/shadow** instead of a thicker border.
- **Centralized easing/duration constants** applied uniformly (end-4 pattern).
- **Semantic motion**: tiles animate *from their real position* on open; QtQuick
  **`SpringAnimation`** for an "alive" settle (niri uses spring physics).
- end-4's **corner-radius-matching** trick: a maximized window's corners match the cell's.
— **easy–medium**.

### 5. Zoom on hover/select — qs-hyprview's mechanic (cleanest)
Non-selected tiles rest at `scale 0.95`; hovered/selected grows to `1.05` with **`z:1000`**
(draws over neighbours, **no reflow**), one `Behavior { NumberAnimation { duration:100 } }`,
and **hover + keyboard nav write the same `currentIndex`** so both share the highlight. Keep it
subtle and non-reflowing (the macOS Dock-magnification annoyance). — **easy**; a differentiator.

## Net-new ideas worth stealing
- **Highlight the drop target *during* drag** (call `hitWorkspace` in `onPositionChanged`) —
  kills the "did that register?" feeling. — easy, high value.
- **"Shrink-to-drop"** feedback on the dragged tile over a valid target. — easy.
- **Close-on-hover** button + always-visible title/icon badge. — easy.
- **Drag past the last workspace → create a new one** (GNOME). — easy.
- **Hold-over-a-workspace-to-focus** during long drags (niri). — easy.

## Explicitly avoid (others' scars)
Pluggable-layout "zoo" (qs-hyprview's 11 layouts — over-engineered for a single-file plugin) ·
a second separate "spread" mode (elementary had to dedupe theirs) · aggressive/3D zoom
transitions (KDE caused motion-sickness reports) · gesture/hot-corner entry (needs
compositor-level input Quickshell can't get) · drag-to-reorder-workspaces (fragile on Hyprland).

## Priority

- **Milestone A (chosen 2026-09-09):** #1 bigger dynamic tiles · #5 hover/select zoom ·
  #3 monitor distinction · #4 drag polish + style.
- **Milestone B:** #2 in-workspace rearrange (floating reposition + tiled swap) · semantic
  motion + spring settle · corner-radius match.
- **Later/optional:** opt-in declutter layout · empty-workspace wallpaper · hold-to-focus ·
  drag-to-create-workspace.

## Source pointers (who implements what)
- **Hover-zoom mechanic:** dom0/qs-hyprview `modules/WindowThumbnail.qml` (0.95/1.05 + z + unified index).
- **Within-workspace floating drag:** end-4/dots-hyprland `ii/overview/OverviewWidget.qml` (~L246–281) + `OverviewWindow.qml`.
- **Corner-radius matching:** end-4 `OverviewWidget.qml` (~L206–230).
- **Rounded clip:** Caelestia `components/StyledClippingRect.qml` (`ClippingRectangle`); shanu-overview uses `MultiEffect{maskEnabled}`.
- **Monitor chip:** DankMaterialShell `Modules/WorkspaceOverlays/OverviewWidget.qml` (~L463–508).
- **Empty-workspace wallpaper:** Shanu-Kumawat/quickshell-overview `modules/overview/OverviewWidget.qml`.
- **Strip-packing layout:** KDE KWin RFC #189 / MR !4916 (Next-Fit Decreasing Height + aspect binary-search).
- **Hyprland rearrange dispatchers:** `layoutmsg swapsplit`/`movewindowsplit` (dwindle), `swapwithmaster`/`swapnext` (master), `movewindowpixel exact`/`moveactive exact` (floating).
- **Spring motion:** niri overview (spring physics); QtQuick `SpringAnimation`.
