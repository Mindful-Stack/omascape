#!/usr/bin/env bash
# Shared bootstrap for the nested-Hyprland integration scripts. Source it after `set -euo pipefail`.
# Provides: require_bins; hc, ipc, $tmp and the EXIT trap (set at source time); start_nested (sets
# $nested $socket $hypr_pid); start_quickshell (sets $qs_pid); spawn_window, box, boxof, geometry,
# fsmode, wsof, dump; and the waits: wait_pending, wait_fs, wait_ws, settled_cursor.
require_bins() {
    for bin in Hyprland hyprctl quickshell foot jq rg; do
        command -v "$bin" >/dev/null || { echo "SKIP: $bin not installed"; exit 0; }
    done
}
src=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
tmp=$(mktemp -d)
nested=""; socket=""; hypr_pid=""; qs_pid=""
cleanup() {
    [[ -z "$qs_pid" ]] || kill "$qs_pid" 2>/dev/null || true
    [[ -z "$nested" ]] || HYPRLAND_INSTANCE_SIGNATURE="$nested" hyprctl dispatch 'hl.dsp.exit()' >/dev/null 2>&1 || true
    [[ -z "$hypr_pid" ]] || kill "$hypr_pid" 2>/dev/null || true
    rm -rf "$tmp"
}
trap cleanup EXIT
hc() { [[ -n "$nested" ]] || { echo "BUG: hc before start_nested" >&2; exit 1; }; HYPRLAND_INSTANCE_SIGNATURE="$nested" hyprctl "$@"; }
# start_nested [extra Lua config lines...]: isolated Lua-mode Hyprland on an offset headless output.
start_nested() {
    {
        # Offset output catches the global-vs-local coordinate regression.
        cat <<'CONF'
hl.config({ misc = { disable_hyprland_logo = true, disable_splash_rendering = true } })
hl.monitor({output="", mode="1280x720", position="0x1440", scale=1})
hl.workspace_rule({workspace="3", persistent=true})
CONF
        [[ $# -eq 0 ]] || printf '%s\n' "$@"
    } > "$tmp/hypr.lua"
    Hyprland -c "$tmp/hypr.lua" > "$tmp/hypr.log" 2>&1 & hypr_pid=$!
    for _ in $(seq 1 60); do
        nested=$(hyprctl instances -j | jq -r --argjson p "$hypr_pid" '.[] | select(.pid==$p) | .instance')
        [[ -z "$nested" ]] || break
        sleep 0.25
    done
    [[ -n "$nested" ]] || { cat "$tmp/hypr.log"; exit 1; }
    local mon; mon=$(hc monitors -j | jq -r '.[0].name')
    case "$mon" in WAYLAND-*|WL-*|HEADLESS-*) ;; *) echo "REFUSE: $mon is not nested"; exit 1;; esac
    socket=$(hyprctl instances -j | jq -r --argjson p "$hypr_pid" '.[] | select(.pid==$p) | .wl_socket')
}
# start_quickshell: production Overview + the dragtest IPC shell, theme-only adapters.
start_quickshell() {
    mkdir -p "$tmp/Commons" "$tmp/Ui"
    # Theme-only adapters: actual Quickshell, Wayland and Hyprland modules remain intact.
    printf 'module qs.Commons\nsingleton Color 1.0 Color.qml\nsingleton Style 1.0 Style.qml\n' > "$tmp/Commons/qmldir"
    printf 'pragma Singleton\nimport QtQuick\nQtObject { readonly property var menu: ({background:"#222",text:"#fff",border:"#888",scrim:"#000",selectedBackground:"#444",selectedText:"#fff"}) }\n' > "$tmp/Commons/Color.qml"
    # Mirrors the shell's Commons/Style.qml members the plugin reads (Style.font.*, Style.space).
    cat > "$tmp/Commons/Style.qml" <<'QML'
pragma Singleton
import QtQuick
QtObject {
    readonly property int cornerRadius: 8
    readonly property real normalFillAlpha: 0.08
    readonly property real selectedFillAlpha: 0.2
    readonly property QtObject font: QtObject {
        readonly property string menuFamily: "monospace"
        readonly property int bodySmall: 11
        readonly property int caption: 10
    }
    function space(px) { return px }
}
QML
    printf 'module qs.Ui\nUnused 1.0 Unused.qml\n' > "$tmp/Ui/qmldir"
    printf 'import QtQuick\nItem {}\n' > "$tmp/Ui/Unused.qml"
    cp "$src"/*.qml "$src/logic.js" "$tmp/"   # every component the plugin ships (SoftShadow, OmascapeConfig, ...)
    cp "$src/tests/integration/drag.qml" "$tmp/shell.qml"
    HYPRLAND_INSTANCE_SIGNATURE="$nested" WAYLAND_DISPLAY="$socket" quickshell -p "$tmp/shell.qml" > "$tmp/qs.log" 2>&1 & qs_pid=$!
    for _ in $(seq 1 40); do
        ipc pending >/dev/null 2>&1 && break
        sleep 0.1
    done
    ipc pending >/dev/null || { cat "$tmp/qs.log"; exit 1; }
}
ipc() { WAYLAND_DISPLAY="$socket" quickshell ipc -p "$tmp/shell.qml" call dragtest "$@"; }
spawn_window() {
    local old found
    old=$(hc clients -j | jq '[.[].address]')
    hc dispatch 'hl.dsp.exec_cmd("foot")' >/dev/null
    for _ in $(seq 1 40); do
        found=$(hc clients -j | jq -r --argjson old "$old" 'first(.[]|.address as $a|select($old|index($a)|not)|.address)')
        [[ -z "$found" ]] || { echo "$found"; return; }
        sleep 0.1
    done
    return 1
}
geometry() { hc clients -j | jq -c --arg a "$1" '.[]|select(.address==$a)|{at,size}'; }
box() { hc clients -j | jq -r --arg a "$1" '.[]|select(.address==$a)|"\(.at[0]) \(.at[1]) \(.size[0]) \(.size[1]) \(.workspace.id)"'; }
# `box` for a window that must exist: a gone window would otherwise be an empty line that reads as
# zeroes and turns a real regression into a confusing geometry mismatch. Prints the failure from
# the subshell and exits it, so the caller's `read` sees EOF and `set -e` stops the script:
#     read -r x y w h ws < <(boxof "$addr")
boxof() {
    local out; out=$(box "$1")
    [[ -n "$out" ]] || { { echo "FAIL: window $1 is not in the client list"; dump; } >&2; exit 1; }
    echo "$out"
}
fsmode() { hc clients -j | jq -r --arg a "$1" '.[]|select(.address==$a)|.fullscreen'; }
wsof() { hc clients -j | jq -r --arg a "$1" '.[]|select(.address==$a)|.workspace.id'; }
dump() { hc clients -j | jq '[.[]|{address,at,size,workspace:.workspace.id,fullscreen}]'; [[ -f "$tmp/qs.log" ]] && cat "$tmp/qs.log" || true; }
wait_pending() {
    for _ in $(seq 1 40); do
        [[ "$(ipc pending)" == '{}' ]] && return
        sleep 0.1
    done
    echo 'FAIL: drop not acknowledged'; dump; exit 1
}
wait_fs() {   # $1 addr, $2 mode: wait until the client reports that fullscreen mode
    for _ in $(seq 1 40); do [[ "$(fsmode "$1")" == "$2" ]] && return; sleep 0.1; done
    echo "FAIL: $1 did not reach fullscreen mode $2"; dump; exit 1
}
wait_ws() {   # $1 addr, $2 workspace: wait until the client reports that workspace
    for _ in $(seq 1 40); do [[ "$(wsof "$1")" == "$2" ]] && return; sleep 0.1; done
    echo "FAIL: $1 did not reach workspace $2"; dump; exit 1
}
# The cursor a chunk must put back is the one it reads when it starts, so never sample one that is
# still moving (a preceding dispatch can warp it a frame later): take it once two reads agree.
settled_cursor() {
    local p q; p=$(hc cursorpos -j | jq -c .)
    for _ in $(seq 1 20); do
        sleep 0.05; q=$(hc cursorpos -j | jq -c .)
        [[ "$p" == "$q" ]] && { echo "$p"; return; }
        p=$q
    done
    echo "WARN: cursor never settled, using $p" >&2
    echo "$p"
}
