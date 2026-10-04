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
# Scans the published runtime set only (root *.qml — not tests/, and not an overridden root
# below, which exists only so tests/plaintext-selftest.sh can point this same scanner at
# throwaway fixture directories instead of duplicating its logic). For each `Text {` / `Label {`
# block — however it is introduced (`delegate: Text {`, a qualified `QQ.Text {`, several on one
# line, one nested inside another) — requires a `textFormat: Text.PlainText` line at the block's
# OWN nesting level; a nested child Text must carry its own. Comments and string literals are
# stripped before any of this is checked, so neither can forge compliance, and braces inside a
# string never shift the nesting count. Independently, anywhere in the file: any `textFormat`
# write (`:` or `=`) whose value is not the literal token `Text.PlainText` fails — numeric
# (`textFormat = 2`), parenthesised (`textFormat = (Label.RichText)`) and any other shape, not
# only a bare enum name; any `<ident>.(AutoText|StyledText|RichText|MarkdownText)` token fails,
# whatever its qualifier; any `createQmlObject` call fails outright, since a string it builds
# from could contain a `Text` this scanner never sees; and the quoted string `"textFormat"` /
# `'textFormat'` fails wherever it appears in the RAW source (before comment/string stripping,
# since stripping would hide exactly this — `t["textFormat"] = 2` or a `Binding { property:
# "textFormat"; … }` both reach the real property without ever writing the bare identifier
# `textFormat` our other checks key on).
#
# Known limit of a static scan: the stripper does not model JS regex literals, so a `/"/` pair
# could in principle hide a `Text` the same way a string does — root `*.qml` contains no regex
# literal today, and a regex belongs in `logic.js` by convention anyway (see
# `lore/knowledge/languages/javascript/tooling-dialect.md`), so this is accepted rather than
# fixed. See `lore/knowledge/learnings/qml-text-autotext-renders-markup.md`.
root=$(cd "$(dirname "$0")/.." && pwd)
root=${1:-$root}
python3 - "$root" <<'PY'
import glob, os, re, sys

root = sys.argv[1]

# \b before the optional qualifier/the bare name alike, so "MyText {" (a real but differently
# named type) is not mistaken for "Text {", while "QQ.Text {" and "delegate: Text {" both match.
OPEN_RE = re.compile(r'\b(?:\w+\.)?(?:Text|Label)\s*\{')
REQUIRED_RE = re.compile(r'\btextFormat\s*:\s*Text\.PlainText\b')
# Any textFormat write whose value is not exactly the token Text.PlainText — numeric
# (`= 2`), parenthesised (`= (Label.RichText)`), or anything else. "Text.PlainTextX" does not
# satisfy the lookahead's trailing \b, so it is correctly treated as a bad value, not as a
# near-miss of the real one.
BAD_ASSIGN_RE = re.compile(r'\btextFormat\s*[:=]\s*(?!Text\.PlainText\b)(\S+)')
# Any qualifier, not only Text/TextEdit — `Label.RichText` inside a parenthesised expression is
# exactly as capable of being read back as a rich-text value as `Text.RichText` is.
BANNED_TOKEN_RE = re.compile(r'\b\w+\.(?:AutoText|StyledText|RichText|MarkdownText)\b')
CREATE_QML_OBJECT_RE = re.compile(r'\bcreateQmlObject\b')
# Checked on the RAW source, never the stripped one: stripping replaces a string literal's body
# with spaces, which would hide exactly the thing being looked for here — `textFormat` reached
# as a quoted property name (`t["textFormat"] = 2`, or a `Binding { property: "textFormat"; … }`)
# rather than as the bare identifier every other check above keys on.
RAW_QUOTED_TEXTFORMAT_RE = re.compile(r'''(["'])textFormat\1''')
RAW_BINDING_PROPERTY_RE = re.compile(r'''\bproperty\s*:\s*["']textFormat["']''')


class ScanError(Exception):
    pass


def strip_comments_and_strings(text, relpath):
    # Replaces // line comments, /* */ block comments and "…"/'…'/`…` string bodies with
    # spaces, preserving every newline and the overall length — so line numbers stay correct
    # and brace/keyword scanning never sees what is inside a comment or a string literal.
    out = []
    i, n = 0, len(text)
    line = 1
    NORMAL, LINE_COMMENT, BLOCK_COMMENT, STR = range(4)
    state = NORMAL
    quote = ''
    block_start_line = 0
    str_start_line = 0
    while i < n:
        c = text[i]
        if c == '\n':
            if state == LINE_COMMENT:
                state = NORMAL
            out.append('\n')
            i += 1
            line += 1
            continue
        if state == NORMAL:
            if c == '/' and i + 1 < n and text[i + 1] == '/':
                state = LINE_COMMENT
                out.append('  ')
                i += 2
                continue
            if c == '/' and i + 1 < n and text[i + 1] == '*':
                state = BLOCK_COMMENT
                block_start_line = line
                out.append('  ')
                i += 2
                continue
            if c in ('"', "'", '`'):
                state = STR
                quote = c
                str_start_line = line
                out.append(' ')
                i += 1
                continue
            out.append(c)
            i += 1
            continue
        if state == LINE_COMMENT:
            out.append(' ')
            i += 1
            continue
        if state == BLOCK_COMMENT:
            if c == '*' and i + 1 < n and text[i + 1] == '/':
                state = NORMAL
                out.append('  ')
                i += 2
                continue
            out.append(' ')
            i += 1
            continue
        if state == STR:
            if c == '\\' and i + 1 < n and text[i + 1] != '\n':
                out.append('  ')
                i += 2
                continue
            if c == quote:
                state = NORMAL
                out.append(' ')
                i += 1
                continue
            out.append(' ')
            i += 1
            continue
    if state == BLOCK_COMMENT:
        raise ScanError("%s: unterminated /* comment opened at line %d" % (relpath, block_start_line))
    if state == STR:
        raise ScanError("%s: unterminated string literal opened at line %d" % (relpath, str_start_line))
    return ''.join(out)


def depth_before_array(stripped):
    # depths[i] is the brace nesting depth BEFORE character i is processed.
    depths = [0] * (len(stripped) + 1)
    d = 0
    for idx, ch in enumerate(stripped):
        depths[idx] = d
        if ch == '{':
            d += 1
        elif ch == '}':
            d -= 1
    depths[len(stripped)] = d
    return depths


def match_braces(stripped, relpath):
    # open_offset -> close_offset for every matched brace pair; fails closed (a clear
    # ScanError, not a traceback) on anything unbalanced.
    stack = []
    pairs = {}
    for idx, ch in enumerate(stripped):
        if ch == '{':
            stack.append(idx)
        elif ch == '}':
            if not stack:
                ln = stripped.count('\n', 0, idx) + 1
                raise ScanError("%s:%d: unmatched '}' (more closing than opening braces)" % (relpath, ln))
            pairs[stack.pop()] = idx
    if stack:
        ln = stripped.count('\n', 0, stack[-1]) + 1
        raise ScanError("%s:%d: unmatched '{' (brace never closes)" % (relpath, ln))
    return pairs


def line_of(stripped, offset):
    return stripped.count('\n', 0, offset) + 1


def check_file(path, root):
    with open(path) as f:
        raw = f.read()
    rel = os.path.relpath(path, root)
    stripped = strip_comments_and_strings(raw, rel)
    pairs = match_braces(stripped, rel)
    depths = depth_before_array(stripped)

    offenders = []  # (line, message)

    plain_hits = [m.start() for m in REQUIRED_RE.finditer(stripped)]
    for m in OPEN_RE.finditer(stripped):
        brace_off = m.end() - 1
        if brace_off not in pairs:
            continue  # match_braces already raised if anything here were unbalanced
        close_off = pairs[brace_off]
        own_depth = depths[brace_off] + 1
        found = any(brace_off < p < close_off and depths[p] == own_depth for p in plain_hits)
        if not found:
            offenders.append((line_of(stripped, m.start()), "missing its own textFormat: Text.PlainText"))

    for m in BAD_ASSIGN_RE.finditer(stripped):
        offenders.append((line_of(stripped, m.start()), "textFormat set to %s, not Text.PlainText" % m.group(1)))

    for m in BANNED_TOKEN_RE.finditer(stripped):
        offenders.append((line_of(stripped, m.start()), "uses the banned rich-text value %s" % stripped[m.start():m.end()]))

    for m in CREATE_QML_OBJECT_RE.finditer(stripped):
        offenders.append((line_of(stripped, m.start()), "calls createQmlObject, which this scanner cannot see inside"))

    # Raw source, deliberately not the stripped one — see the header comment.
    for m in RAW_QUOTED_TEXTFORMAT_RE.finditer(raw):
        offenders.append((line_of(raw, m.start()), 'reaches "textFormat" as a quoted property name'))

    for m in RAW_BINDING_PROPERTY_RE.finditer(raw):
        offenders.append((line_of(raw, m.start()), 'binds property: "textFormat" directly'))

    seen = set()
    out = []
    for ln, msg in sorted(offenders):
        key = (ln, msg)
        if key in seen:
            continue
        seen.add(key)
        out.append("%s:%d: %s" % (rel, ln, msg))
    return out


offenders = []
try:
    for path in sorted(glob.glob(os.path.join(root, "*.qml"))):
        offenders.extend(check_file(path, root))
except ScanError as e:
    print("plaintext.sh: FAIL")
    print("  " + str(e))
    sys.exit(1)

if offenders:
    print("plaintext.sh: FAIL")
    for o in offenders:
        print("  " + o)
    sys.exit(1)
print("plaintext.sh: ok")
PY
