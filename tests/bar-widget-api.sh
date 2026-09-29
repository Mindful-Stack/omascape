#!/usr/bin/env bash
set -euo pipefail
# The qs.Ui stubs (tests/ui/stubs/qs/Ui) must not promise a member the real shell no longer has:
# if Omarchy renames WidgetButton.pressed or BarWidget.setting, the UI suite would stay green
# while the real button breaks. Every `property`, `signal` and `function` name declared in a stub
# must still be declared in the host file of the same name (ADR-0011: BarWidget.qml imports
# qs.Ui from the host, and its stubs can drift from the real ones).
#
# This is the one Tier 1 gate whose runtime -- an installed Omarchy shell -- CI can never have,
# so the usual CI: guard (lore/knowledge/general/testing.md, lua-check.sh:23) is inverted here:
# on CI, a missing host is expected and this prints a NOTE and exits 0; on a developer machine, a
# missing host means the environment cannot run this check at all, which is a FAIL, not a SKIP
# (ADR-0003: a SKIP is not a pass).
root=$(cd "$(dirname "$0")/.." && pwd)
host=${OMARCHY_SHELL_UI:-/usr/share/omarchy/shell/Ui}
if [[ ! -d $host ]]; then
    if [[ -n ${CI:-} ]]; then
        echo "NOTE: bar-widget-api.sh not applicable on CI (no Omarchy shell); stub drift is checked on every local run"
        exit 0
    fi
    echo "FAIL: bar-widget-api.sh — no Omarchy shell at $host (set OMARCHY_SHELL_UI to its Ui directory)"
    exit 1
fi

shopt -s nullglob
stubs=("$root"/tests/ui/stubs/qs/Ui/*.qml)
if (( ${#stubs[@]} == 0 )); then
    echo "FAIL: no stub files found under tests/ui/stubs/qs/Ui"
    exit 1
fi

fail=0
for stub in "${stubs[@]}"; do
    name=$(basename "$stub")
    real="$host/$name"
    [[ -f $real ]] || { echo "FAIL: host has no $name"; fail=1; continue; }
    declared=0
    while read -r kind member; do
        declared=1
        if ! grep -qE "^[[:space:]]*((readonly|required|default)[[:space:]]+)?${kind}[[:space:]]+([A-Za-z_][A-Za-z0-9_.<>]*[[:space:]]+)?${member}([[:space:](:]|\$)" "$real"; then
            echo "FAIL: $name: host no longer declares $kind $member"; fail=1
        fi
    done < <(sed -nE 's/^[[:space:]]*((readonly|required|default)[[:space:]]+)?(property)[[:space:]]+[A-Za-z_][A-Za-z0-9_.<>]*[[:space:]]+([A-Za-z_]+).*/\3 \4/p;
                      s/^[[:space:]]*(signal|function)[[:space:]]+([A-Za-z_]+).*/\1 \2/p' "$stub")
    if (( declared == 0 )); then
        echo "FAIL: $name: no declarations extracted — the guard would check nothing"; fail=1
    fi
done
(( fail == 0 )) && echo "bar-widget-api.sh: ok"
exit $fail
