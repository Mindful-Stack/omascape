#!/usr/bin/env bash
set -euo pipefail
# The qs.Ui stubs (tests/ui/stubs/qs/Ui) must not promise a member the real shell no longer has:
# if Omarchy renames WidgetButton.pressed or BarWidget.setting, the UI suite would stay green
# while the real button breaks. Every `property`, `signal` and `function` name declared in a stub
# must still be declared in the host file of the same name.
# Local only: CI has no Omarchy shell, so there this prints SKIP and checks nothing (ADR-0003: a
# SKIP is not a pass; the PR says so).
root=$(cd "$(dirname "$0")/.." && pwd)
host=${OMARCHY_SHELL_UI:-/usr/share/omarchy/shell/Ui}
if [[ ! -d $host ]]; then
    echo "SKIP: bar-widget-api.sh — no Omarchy shell at $host; stub drift unchecked"
    exit 0
fi
fail=0
for stub in "$root"/tests/ui/stubs/qs/Ui/*.qml; do
    name=$(basename "$stub")
    real="$host/$name"
    [[ -f $real ]] || { echo "FAIL: host has no $name"; fail=1; continue; }
    while read -r kind member; do
        if ! grep -qE "^[[:space:]]*(readonly[[:space:]]+)?${kind}[[:space:]]+([A-Za-z]+[[:space:]]+)?${member}[[:space:](:]" "$real"; then
            echo "FAIL: $name: host no longer declares $kind $member"; fail=1
        fi
    done < <(sed -nE 's/^[[:space:]]*(readonly[[:space:]]+)?(property)[[:space:]]+[A-Za-z]+[[:space:]]+([A-Za-z_]+).*/\2 \3/p;
                      s/^[[:space:]]*(signal|function)[[:space:]]+([A-Za-z_]+).*/\1 \2/p' "$stub")
done
(( fail == 0 )) && echo "bar-widget-api.sh: ok"
exit $fail
