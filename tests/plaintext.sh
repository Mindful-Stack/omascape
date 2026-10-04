#!/usr/bin/env bash
set -euo pipefail
# Every Text/Label renders plain text (marketplace#9564, reviewer HANCORE-linux, 2026-10-02):
# Overview.qml passes untrusted application/window titles unchanged to WindowTile.qml's title
# Text, whose Qt default textFormat is Text.AutoText — which renders markup, including
# `<img src=...>`, and makes the shell fetch an attacker-selected URL. The rule this guards is
# broader than the untrusted sites found so far: every Text/Label in a shipped root .qml must
# declare `textFormat: Text.PlainText`, because "every Text is plain" is mechanically checkable
# and "only the untrusted ones" is a judgement a future label can silently get wrong.
#
# Scans the published runtime set only (root *.qml — not tests/). For each `Text {` / `Label {`
# block, requires a `textFormat: Text.PlainText` line at the block's OWN nesting level; a nested
# child Text must carry its own.
root=$(cd "$(dirname "$0")/.." && pwd)
python3 - "$root" <<'PY'
import glob, os, re, sys

root = sys.argv[1]
OPEN_RE = re.compile(r'^\s*(Text|Label)\s*\{')
FIELD_RE = re.compile(r'textFormat\s*:\s*Text\.PlainText')

def strip_comment(line):
    # Good enough for this codebase: no "//" occurs inside a string on a brace-bearing line.
    idx = line.find("//")
    return line if idx < 0 else line[:idx]

def depth_before_each_line(lines):
    depths = [0] * (len(lines) + 1)
    depth = 0
    for i, raw in enumerate(lines):
        depths[i] = depth
        code = strip_comment(raw)
        depth += code.count("{") - code.count("}")
    depths[len(lines)] = depth
    return depths

def check_file(path):
    with open(path) as f:
        lines = f.readlines()
    depths = depth_before_each_line(lines)
    offenders = []
    for i, line in enumerate(lines):
        if not OPEN_RE.match(line):
            continue
        start_depth = depths[i]
        own_depth = start_depth + 1
        # Find the end of this block: the first later line whose depth-after returns to
        # start_depth. For a one-line block this is i itself.
        end = i
        while depths[end + 1] != start_depth:
            end += 1
        if end == i:
            # One-line block: the whole line is the block's own level.
            found = bool(FIELD_RE.search(strip_comment(line)))
        else:
            found = False
            for j in range(i + 1, end + 1):
                if depths[j] == own_depth and FIELD_RE.search(strip_comment(lines[j])):
                    found = True
                    break
        if not found:
            offenders.append("%s:%d" % (os.path.relpath(path, root), i + 1))
    return offenders

offenders = []
for path in sorted(glob.glob(os.path.join(root, "*.qml"))):
    offenders.extend(check_file(path))

if offenders:
    print("plaintext.sh: FAIL")
    for o in offenders:
        print("  " + o)
    sys.exit(1)
print("plaintext.sh: ok")
PY
