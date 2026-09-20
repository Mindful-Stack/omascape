#!/usr/bin/env bash
# The one claim about OmascapeConfig.qml that no offscreen tier can reach: that a setting written
# through saveAll() actually arrives in the component's PROPERTIES, and not merely on disk.
#
# Every other suite stubs this component away -- tests/ui/prepare.py replaces it wholesale,
# because FileView needs Quickshell.Io and the offscreen fixture has no Quickshell at all. That
# stub records writes and returns; it cannot model the write/reload round trip, which is exactly
# where the defect this guards against lived:
#
#   FileView's inotify event for an atomic write lands while the writer is still the live
#   operation, so `reload()` starts no read (fileview.cpp:302), `loaded` never fires a second
#   time, and the component's properties keep the pre-write values forever. The panel showed the
#   new value optimistically while the picker went on using the old one -- "changing a setting
#   doesn't work... or maybe it did after a while".
#
# So this runs the REAL component under a REAL Quickshell, with HOME pointed at a scratch tree so
# `cfg.path` resolves inside it. No compositor is involved; the only requirement is the
# `quickshell` binary, and the check SKIPs (loudly) without it -- including on CI, which has Qt
# but not Quickshell.
set -euo pipefail
src=$(cd "$(dirname "$0")/.." && pwd)

if ! command -v quickshell >/dev/null 2>&1; then
  echo "SKIP: config-save needs the quickshell binary (not packaged on CI)"; exit 0
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/home/.config/omarchy"
cp "$src/OmascapeConfig.qml" "$src/logic.js" "$work/"

# `keptByHand` is an unknown key: saveAll must carry it through untouched (Logic.configWithKey
# edits the file's own text rather than rebuilding from the parsed properties). Asserted below,
# so this suite covers preservation as well as propagation.
printf '{"scrim": true, "keptByHand": 7}\n' > "$work/home/.config/omarchy/omascape.json"

cat > "$work/shell.qml" <<'QML'
import QtQuick
import Quickshell
ShellRoot {
    OmascapeConfig { id: cfg }
    // 600ms: long enough for the initial async load to have applied the file. The probe asserts
    // the pre-state below, so a load that had NOT landed fails loudly rather than making the
    // after-state trivially true.
    Timer { running: true; interval: 600; onTriggered: {
        console.log("PROBE before scrim=" + cfg.scrim + " workspaces=" + cfg.workspaces)
        console.log("PROBE saveAll=" + cfg.saveAll({ scrim: false, workspaces: 14 }))
    } }
    Timer { running: true; interval: 1800; onTriggered: {
        console.log("PROBE after scrim=" + cfg.scrim + " workspaces=" + cfg.workspaces)
        Qt.quit()
    } }
}
QML

out=$(HOME="$work/home" QT_QPA_PLATFORM=offscreen timeout 30 quickshell -p "$work/shell.qml" 2>&1 \
      | sed 's/\x1b\[[0-9;]*m//g' | grep "PROBE" || true)

fail() { echo "FAIL: $1" >&2; echo "--- probe output ---" >&2; echo "$out" >&2
         echo "--- file ---" >&2; cat "$work/home/.config/omarchy/omascape.json" >&2; exit 1; }

# The pre-state, checked first: without it an "after" that never changed from a DEFAULT would
# read as success for two of the three values.
grep -q "PROBE before scrim=true workspaces=10" <<<"$out" \
  || fail "the initial load did not apply the file (expected scrim=true workspaces=10)"
grep -q "PROBE saveAll=true" <<<"$out" || fail "saveAll refused the write"

# THE assertion. Both keys, and both changed away from the file's and the schema's own values:
# scrim true -> false is a value the file supplied, workspaces 10 -> 14 one the default supplied,
# so neither can pass by accident.
grep -q "PROBE after scrim=false workspaces=14" <<<"$out" \
  || fail "the written settings never reached the component's properties"

# ...and the file itself: the write must be real, and must not have dropped the unknown key.
disk=$(tr -d ' \n' < "$work/home/.config/omarchy/omascape.json")
[[ $disk == *'"scrim":false'* ]]     || fail "scrim was not written to disk: $disk"
[[ $disk == *'"workspaces":14'* ]]   || fail "workspaces was not written to disk: $disk"
[[ $disk == *'"keptByHand":7'* ]]    || fail "an unknown key was dropped by the write: $disk"

echo "PASS: a setting written through saveAll reaches the component and the file"
