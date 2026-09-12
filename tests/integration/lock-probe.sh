#!/usr/bin/env bash
# Live probe of Hyprland's no_screen_share window rule on THIS session (needs grim + ImageMagick,
# a running Hyprland in Lua mode, and a workspace with at least one window that is NOT the
# active one — pass its id as $1). Captures the output the workspace is on and reports the mean
# brightness of the workspace area with the rule enabled / disabled / re-enabled. A black capture
# has mean ~0; a normal desktop is well above 0.05.
set -euo pipefail
WS="${1:?workspace id with windows}"
for bin in grim magick jq hyprctl; do command -v "$bin" >/dev/null || { echo "SKIP: $bin missing"; exit 0; }; done
OUT=$(hyprctl -j workspaces | jq -r ".[] | select(.id == $WS) | .monitor")
[ -n "$OUT" ] || { echo "FAIL: workspace $WS not found"; exit 1; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"; hyprctl eval "if _G.omyview_probe_rule then _G.omyview_probe_rule:set_enabled(false) end; _G.omyview_probe_rule = nil" >/dev/null' EXIT
mean() { magick "$1" -crop "100%x90%+0+40" -colorspace Gray -format "%[fx:mean]" info:; }
# switch to the workspace so its windows are on screen for the capture
# (this Hyprland build's `hyprctl dispatch` CLI no longer accepts the classic
# "dispatcher arg" word-split form — it wraps argv verbatim into hl.dispatch(...),
# so the argument must itself be a Lua expression producing an HL.Dispatcher)
hyprctl dispatch "hl.dsp.focus({ workspace = $WS })" >/dev/null; sleep 0.4
grim -o "$OUT" "$tmp/base.png";    B=$(mean "$tmp/base.png")
hyprctl eval "_G.omyview_probe_rule = hl.window_rule({ name = 'omyview-probe', match = { workspace = '$WS' }, no_screen_share = true, enabled = true })" >/dev/null; sleep 0.4
grim -o "$OUT" "$tmp/on.png";      ON=$(mean "$tmp/on.png")
hyprctl eval "_G.omyview_probe_rule:set_enabled(false)" >/dev/null; sleep 0.4
grim -o "$OUT" "$tmp/off.png";     OFF=$(mean "$tmp/off.png")
hyprctl eval "_G.omyview_probe_rule:set_enabled(true)" >/dev/null; sleep 0.4
grim -o "$OUT" "$tmp/on2.png";     ON2=$(mean "$tmp/on2.png")
echo "base=$B on=$ON off=$OFF on2=$ON2"
awk -v b="$B" -v on="$ON" -v off="$OFF" -v on2="$ON2" 'BEGIN {
  if (b < 0.05) { print "FAIL: baseline is already dark; pick a workspace with visible windows"; exit 1 }
  if (on > 0.02) { print "FAIL: rule enabled but capture not black"; exit 1 }
  if (off < 0.05) { print "FAIL: rule disabled but capture still black (set_enabled(false) has no effect)"; exit 1 }
  if (on2 > 0.02) { print "FAIL: re-enable has no effect"; exit 1 }
  print "PASS: create-enabled → black; set_enabled(false) → visible; set_enabled(true) → black" }'
