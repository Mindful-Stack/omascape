#!/usr/bin/env bash
# Real-Lua check of the atomic chunks logic.js builds: render them through a throwaway QML
# test (importing logic.js the way the plugin does), parse each with a real interpreter's
# `load()` -- an unparseable chunk is dropped silently by the compositor, not reported
# anywhere -- then run the behaviour suite (tests/lua/tst_chunks.lua) against a mock `hl`.
set -euo pipefail
src=$(cd "$(dirname "$0")/.." && pwd)

# The chunks are rendered by the same Qt6 qmltestrunner tests/run.sh uses (a one-test
# TestCase that console.logs them): one Qt tool for everything, and no dependence on the
# `qml` runtime's per-version behaviour (Qt 6.4's refuses a non-visual root with exit 2).
RUNNER=""
if command -v qmltestrunner6 >/dev/null 2>&1; then RUNNER=qmltestrunner6
elif [ -x /usr/lib/qt6/bin/qmltestrunner ]; then RUNNER=/usr/lib/qt6/bin/qmltestrunner; fi
LUA_BIN=""
for c in lua5.4 lua luajit; do
  if command -v "$c" >/dev/null 2>&1; then LUA_BIN="$c"; break; fi
done

if [ -z "$RUNNER" ] || [ -z "$LUA_BIN" ]; then
  msg="lua-check needs the Qt6 qmltestrunner (qmltestrunner6 or /usr/lib/qt6/bin/qmltestrunner) and a Lua interpreter (lua5.4/lua/luajit) -- missing one of them"
  if [ -n "${CI:-}" ]; then echo "FAIL: $msg (CI must install them)" >&2; exit 1; fi
  echo "SKIP: $msg"; exit 0
fi

fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
cat > "$fixture/tst_dump.qml" <<EOF
import QtQuick
import QtTest
import "$src/logic.js" as Logic
TestCase {
    name: "Dump"
    function test_dump() {
        console.log("CHUNK UNFULLSCREEN " + Logic.unfullscreenLua("0xabc"))
        console.log("CHUNK TILED_INSERT " + Logic.tiledInsertLua("0xabc", 3, { anchor: "0xdef", side: "left", x: 1, y: 2 }))
        console.log("CHUNK TILED_INSERT_NO_ANCHOR " + Logic.tiledInsertLua("0xabc", 3, { anchor: "", side: "", x: 10, y: 20 }))
        console.log("CHUNK FLOATING_MOVE " + Logic.floatingMoveLua("0xabc", 3, { x: 200, y: 1600 }))
        console.log("CHUNK FLOATING_MOVE_SCRATCH " + Logic.floatingMoveLua("0xabc", Logic.SCRATCHPAD_ID, { x: 200, y: 1600 }))
        console.log("CHUNK SCRATCHPAD_SHOW " + Logic.scratchpadShowLua())
        console.log("CHUNK SCRATCHPAD_FOCUS " + Logic.scratchpadFocusLua("0xabc"))
    }
}
EOF

# console.log routes through qDebug, which on a systemd session defaults to the journal rather
# than this process's stderr -- QT_FORCE_STDERR_LOGGING pins it back to stderr. Only what
# follows "CHUNK " is kept (the runner's "QDEBUG : ... qml: " prefix is dropped). Chunks are
# single-line by construction, so one line per chunk is sound. The raw output is kept and
# shown on failure so a runtime problem is diagnosable from the CI log.
qml_status=0
QT_QPA_PLATFORMTHEME=generic QT_QPA_PLATFORM=offscreen QT_FORCE_STDERR_LOGGING=1 \
  "$RUNNER" -input "$fixture" > "$fixture/qml.out" 2>&1 || qml_status=$?
sed -n 's/^.*CHUNK //p' "$fixture/qml.out" > "$fixture/chunks.txt"

count=$(grep -c . "$fixture/chunks.txt" || true)
if [ "$qml_status" -ne 0 ] || [ "$count" -lt 7 ]; then
  echo "FAIL: $RUNNER exited $qml_status; expected 7 generated Lua chunks, got $count (silent/empty output must not pass)" >&2
  echo "--- raw qml output:" >&2; cat "$fixture/qml.out" >&2
  exit 1
fi

# stdin, not an argument: `lua -e stat file` would run `file` as a script.
"$LUA_BIN" -e '
for line in io.lines() do
  local name, body = line:match("^(%S+) (.+)$")
  local f, err = load("return " .. body, name)
  if not f then io.stderr:write("LUA PARSE FAIL (" .. name .. "): " .. err .. "\n" .. body .. "\n"); os.exit(1) end
end' < "$fixture/chunks.txt"
echo "PASS: $count generated Lua chunks parse"

"$LUA_BIN" "$src/tests/lua/tst_chunks.lua" "$fixture/chunks.txt"
