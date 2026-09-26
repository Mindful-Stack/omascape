#!/usr/bin/env bash
set -euo pipefail
# manifest.json shape for the bar icon (docs/specs/2026-09-24-bar-icon-design.md). Catches a
# kinds/entryPoints edit that drops the button or the overlay, an entry point that names a file
# that is not at the repo root, and a default section other than "left" (which is what lands the
# icon right after omarchy.workspaces, PluginRegistry.barTarget).
root=$(cd "$(dirname "$0")/.." && pwd)
python3 - "$root" <<'PY'
import json, sys, os
root = sys.argv[1]
m = json.load(open(os.path.join(root, "manifest.json")))
errs = []
if sorted(m.get("kinds", [])) != ["bar-widget", "overlay"]:
    errs.append("kinds must be exactly overlay + bar-widget, got %r" % m.get("kinds"))
ep = m.get("entryPoints", {})
for kind, want in (("overlay", "Overview.qml"), ("barWidget", "BarWidget.qml")):
    if ep.get(kind) != want:
        errs.append("entryPoints.%s must be %s, got %r" % (kind, want, ep.get(kind)))
    elif not os.path.isfile(os.path.join(root, want)):
        errs.append("entryPoints.%s names %s, which is not at the repo root" % (kind, want))
bw = m.get("barWidget", {})
if bw.get("defaultSection") != "left":
    errs.append("barWidget.defaultSection must be 'left', got %r" % bw.get("defaultSection"))
if bw.get("allowMultiple") is not False:
    errs.append("barWidget.allowMultiple must be false")
for k in ("displayName", "description", "category"):
    if not isinstance(bw.get(k), str) or not bw.get(k):
        errs.append("barWidget.%s must be a non-empty string" % k)
if errs:
    print("manifest.sh: FAIL\n  " + "\n  ".join(errs)); sys.exit(1)
print("manifest.sh: ok")
PY
