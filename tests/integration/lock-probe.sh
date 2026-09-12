#!/usr/bin/env bash
# Live probe of Hyprland's no_screen_share window rule. Unlike the rest of
# tests/integration (which drives a nested Hyprland), this one runs against the
# LIVE session — it switches the active workspace to take captures and restores
# it afterward. Needs grim + ImageMagick, a running Hyprland in Lua mode, and a
# workspace with at least one window that is NOT the active one — pass its id
# as $1. Captures the output the workspace is on and reports the mean
# brightness of the workspace area with the rule enabled / disabled /
# re-enabled, plus a scoping check against another workspace on the same
# output. A black capture has mean ~0; a normal desktop is well above 0.05.
# The crop excludes the top 40 px (the bar, at UI scale 1.25) and the bottom
# 10%.
#
# This Hyprland build's `hyprctl dispatch` CLI no longer accepts the classic
# "dispatcher arg..." word-split form — it wraps argv verbatim into
# hl.dispatch(...), which then fails to parse — so every dispatch below passes
# a Lua expression producing an HL.Dispatcher instead (e.g.
# hl.dsp.focus({ workspace = "N" })).
set -euo pipefail
WS="${1:?workspace id with windows}"
case "$WS" in ''|*[!0-9]*) echo "FAIL: numeric workspace id required (special workspaces are not probed by this script)" >&2; exit 1;; esac
for bin in grim magick jq hyprctl; do command -v "$bin" >/dev/null || { echo "SKIP: $bin missing"; exit 0; }; done

ev() { local out; out=$(hyprctl eval "$1") || { echo "FAIL: hyprctl eval: $out" >&2; exit 1; }; }

OUT=$(hyprctl -j workspaces | jq -r ".[] | select(.id == $WS) | .monitor // empty")
[ -n "$OUT" ] || { echo "FAIL: workspace $WS not found"; exit 1; }
WIN=$(hyprctl -j workspaces | jq -r ".[] | select(.id == $WS) | .windows")
[ "$WIN" -gt 0 ] || { echo "FAIL: workspace $WS has no windows"; exit 1; }

ORIG_WS=$(hyprctl -j activeworkspace | jq -r .id)
tmp=$(mktemp -d)

status=0
cleanup() {
  local rc=$?; [ "$status" -ne 0 ] && rc=$status
  local out
  if ! out=$(hyprctl eval "if _G.omyview_probe_rule then _G.omyview_probe_rule:set_enabled(false) end; _G.omyview_probe_rule = nil"); then
    echo "WARNING: could not disable the probe rule — run: hyprctl eval '_G.omyview_probe_rule:set_enabled(false)'  ($out)" >&2; rc=1
  fi
  [ -n "${ORIG_WS:-}" ] && hyprctl dispatch "hl.dsp.focus({ workspace = \"$ORIG_WS\" })" >/dev/null 2>&1 || echo "WARNING: could not restore workspace $ORIG_WS" >&2
  rm -rf "$tmp"
  exit "$rc"
}
trap cleanup EXIT

mean() { magick "$1" -crop "100%x90%+0+40" -colorspace Gray -format "%[fx:mean]" info:; }

# Switch to a workspace and confirm the switch actually landed (poll up to 2s)
# before treating it as done.
switch_and_wait() {
  local target="$1" waited=0
  hyprctl dispatch "hl.dsp.focus({ workspace = \"$target\" })" >/dev/null
  while [ "$(hyprctl -j activeworkspace | jq -r .id)" != "$target" ]; do
    if [ "$waited" -ge 20 ]; then
      echo "FAIL: workspace switch to $target did not land within 2s"
      exit 1
    fi
    sleep 0.1
    waited=$((waited + 1))
  done
  sleep 0.3
}

# switch to the workspace so its windows are on screen for the capture
switch_and_wait "$WS"
grim -o "$OUT" "$tmp/base.png";    B=$(mean "$tmp/base.png")
ev "_G.omyview_probe_rule = hl.window_rule({ name = 'omyview-probe', match = { workspace = '$WS' }, no_screen_share = true, enabled = true })"; sleep 0.4
grim -o "$OUT" "$tmp/on.png";      ON=$(mean "$tmp/on.png")

# Scoping check: the rule must be scoped to $WS, not leak to the rest of the output.
OTHER_WS=$(hyprctl -j workspaces | jq -r ".[] | select(.id > 0 and .id != $WS and .windows > 0 and .monitor == \"$OUT\") | .id" | head -n1)
if [ -n "$OTHER_WS" ]; then
  switch_and_wait "$OTHER_WS"
  grim -o "$OUT" "$tmp/other.png"; OTHER=$(mean "$tmp/other.png")
  switch_and_wait "$WS"
else
  OTHER="SKIP-SCOPING"
  echo "SKIP-SCOPING: no other workspace with windows on $OUT"
fi

ev "_G.omyview_probe_rule:set_enabled(false)"; sleep 0.4
grim -o "$OUT" "$tmp/off.png";     OFF=$(mean "$tmp/off.png")
ev "_G.omyview_probe_rule:set_enabled(true)"; sleep 0.4
grim -o "$OUT" "$tmp/on2.png";     ON2=$(mean "$tmp/on2.png")
echo "base=$B on=$ON off=$OFF on2=$ON2 other=$OTHER"
awk -v b="$B" -v on="$ON" -v off="$OFF" -v on2="$ON2" -v other="$OTHER" 'BEGIN {
  if (b < 0.05) { print "FAIL: baseline too dark to distinguish from a blanked capture; pick a workspace with brighter content"; exit 1 }
  if (on > 0.02) { print "FAIL: rule enabled but capture not black"; exit 1 }
  if (off < 0.05) { print "FAIL: rule disabled but capture still black (set_enabled(false) has no effect)"; exit 1 }
  if (on2 > 0.02) { print "FAIL: re-enable has no effect"; exit 1 }
  if (other != "SKIP-SCOPING" && other+0 < 0.05) { print "FAIL: rule leaks to other workspaces (scoping broken)"; exit 1 }
  print "PASS: create-enabled → black; set_enabled(false) → visible; set_enabled(true) → black" }' || status=$?
