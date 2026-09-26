#!/usr/bin/env bash
set -euo pipefail
src=$(cd "$(dirname "$0")/../.." && pwd)
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
python3 "$src/tests/ui/prepare.py" "$src" "$fixture"
# The bar button loads the host's qs.Ui; the fixture supplies stubs (tests/ui/stubs, see their
# header) and the PRODUCTION BarWidget.qml under its own name in its own directory, so the
# qs.Ui-BarWidget vs ./BarWidget.qml name resolution is the one the shell performs.
cp -r "$src/tests/ui/stubs" "$fixture/imports"
mkdir -p "$fixture/plugin"
cp "$src/BarWidget.qml" "$fixture/plugin/BarWidget.qml"
cp "$src/tests/ui/barwidget.qml" "$fixture/tst_barwidget_ui.qml"
cp "$src/tests/ui/drag.qml" "$fixture/tst_drag.qml"
cp "$src/tests/ui/find.qml" "$fixture/tst_find_ui.qml"
cp "$src/tests/ui/scratchpad.qml" "$fixture/tst_scratchpad_ui.qml"
cp "$src/tests/ui/lock.qml" "$fixture/tst_lock_ui.qml"
cp "$src/tests/ui/close.qml" "$fixture/tst_close_ui.qml"
cp "$src/tests/ui/actions.qml" "$fixture/tst_actions_ui.qml"
cp "$src/tests/ui/monitors.qml" "$fixture/tst_monitors_ui.qml"
cp "$src/tests/ui/peek.qml" "$fixture/tst_peek_ui.qml"
cp "$src/tests/ui/presence.qml" "$fixture/tst_presence_ui.qml"
cp "$src/tests/ui/dropdown.qml" "$fixture/tst_dropdown_ui.qml"
cp "$src/tests/ui/activate.qml" "$fixture/tst_activate_ui.qml"
cp "$src/tests/ui/settings.qml" "$fixture/tst_settings_ui.qml"
runner=/usr/lib/qt6/bin/qmltestrunner
command -v qmltestrunner6 >/dev/null 2>&1 && runner=qmltestrunner6
[[ -n ${QMLTESTRUNNER:-} ]] && runner=$QMLTESTRUNNER   # pinned install (CI), see tests/run.sh
QT_QPA_PLATFORMTHEME=generic QT_QPA_PLATFORM=offscreen "$runner" -import "$fixture/imports" -input "$fixture" "$@"
