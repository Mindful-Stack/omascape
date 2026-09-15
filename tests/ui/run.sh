#!/usr/bin/env bash
set -euo pipefail
src=$(cd "$(dirname "$0")/../.." && pwd)
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
python3 "$src/tests/ui/prepare.py" "$src" "$fixture"
cp "$src/tests/ui/drag.qml" "$fixture/tst_drag.qml"
cp "$src/tests/ui/find.qml" "$fixture/tst_find_ui.qml"
cp "$src/tests/ui/scratchpad.qml" "$fixture/tst_scratchpad_ui.qml"
runner=/usr/lib/qt6/bin/qmltestrunner
command -v qmltestrunner6 >/dev/null 2>&1 && runner=qmltestrunner6
QT_QPA_PLATFORMTHEME=generic QT_QPA_PLATFORM=offscreen "$runner" -input "$fixture" "$@"
