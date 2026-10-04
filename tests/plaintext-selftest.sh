#!/usr/bin/env bash
set -euo pipefail
# Guards tests/plaintext.sh itself: every bypass found across two rounds of adversarial review
# (round 1: not at line start, qualified `QQ.Text {`, comments/strings forging compliance, braces
# inside strings miscounting depth, a nested child satisfying its parent, a near-miss enum name,
# an explicit non-PlainText value; round 2: a numeric or parenthesised dynamic `textFormat =` write,
# a qualifier other than Text/TextEdit on a banned enum, `textFormat` reached as a quoted property
# name via bracket access or a `Binding { property: "textFormat" }`, and a bare `createQmlObject`
# call) gets its own fixture here, asserted REJECTED — plus fixtures the guard must still ACCEPT,
# so hardening the scanner never turns it into a guard that rejects everything. tests/plaintext.sh
# takes an optional root override for exactly this: each case below points it at a throwaway
# one-file directory instead of the real tree, so this is the real scanner under test, not a
# reimplementation of it.
here=$(cd "$(dirname "$0")" && pwd)
plaintext_sh="$here/plaintext.sh"
fail=0
total=0

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Runs plaintext.sh against a single fixture file's own directory and asserts the outcome.
# $1 name, $2 fixture content, $3 expect ("pass" or "fail"), $4 (if fail) substring the output
# must contain -- normally "<file>:<line>" naming the offending spot.
check() {
    local name=$1 content=$2 expect=$3 want=${4:-}
    total=$((total + 1))
    local dir="$work/$name"
    mkdir -p "$dir"
    printf '%s\n' "$content" > "$dir/Case.qml"
    local out status
    if out=$(bash "$plaintext_sh" "$dir" 2>&1); then status=0; else status=$?; fi
    if [[ $expect == pass ]]; then
        if [[ $status -ne 0 ]]; then
            echo "FAIL  $name: expected pass, got FAIL:"
            echo "$out" | sed 's/^/        /'
            fail=$((fail + 1))
        else
            echo "ok    $name"
        fi
    else
        if [[ $status -eq 0 ]]; then
            echo "FAIL  $name: expected a rejection, got: $out"
            fail=$((fail + 1))
        elif [[ -n $want ]] && ! grep -qF "$want" <<<"$out"; then
            echo "FAIL  $name: rejected, but output did not mention '$want':"
            echo "$out" | sed 's/^/        /'
            fail=$((fail + 1))
        else
            echo "ok    $name"
        fi
    fi
}

# ---- bypass 1: Text not at the start of its line -----------------------------------------------
check "not_line_start_delegate" '
Item {
    delegate: Text { text: "x" }
}' fail "Case.qml:3"

check "not_line_start_property_component" '
Item {
    property Component c: Text { text: "x" }
}' fail "Case.qml:3"

check "not_line_start_nested_opener" '
Item {
    Item { Text { text: "x" } }
}' fail "Case.qml:3"

check "two_on_one_line_one_offending" '
Row {
    Text { textFormat: Text.PlainText; text: "a" } Text { text: "b" }
}' fail "Case.qml:3"

# ---- bypass 2: a qualified element name --------------------------------------------------------
check "qualified_type_name" '
Item {
    QQ.Text {
        text: "x"
    }
}' fail "Case.qml:3"

# ---- bypass 3: a comment or a string forging the required line ----------------------------------
check "comment_forges_compliance" '
Item {
    Text {
        // textFormat: Text.PlainText
        text: "x"
    }
}' fail "Case.qml:3"

check "block_comment_forges_compliance" '
Item {
    Text {
        /* textFormat: Text.PlainText */
        text: "x"
    }
}' fail "Case.qml:3"

check "string_forges_compliance" '
Item {
    Text {
        text: "textFormat: Text.PlainText"
    }
}' fail "Case.qml:3"

# ---- bypass 4: a brace inside a string must not shift the depth count ---------------------------
# Compliant despite the stray "{" in the string: the real textFormat line is still at the
# block'"'"'s own level once strings are stripped before counting.
check "brace_in_string_still_passes" '
Item {
    Text {
        textFormat: Text.PlainText
        text: "unbalanced { brace inside a string"
    }
}' pass

# ---- bypass 5: a nested child satisfying its parent ----------------------------------------------
check "nested_child_does_not_satisfy_parent" '
Item {
    Text {
        Text { textFormat: Text.PlainText; text: "child" }
        text: "outer"
    }
}' fail "Case.qml:3"

# ---- bypass 6: a near-miss enum name with no trailing word boundary ------------------------------
check "near_miss_enum_name" '
Item {
    Text {
        textFormat: Text.PlainTextX
        text: "x"
    }
}' fail "Case.qml:4"

# ---- bypass 7: an explicit non-PlainText textFormat must never pass -----------------------------
check "rich_text_colon" '
Item {
    Text {
        textFormat: Text.RichText
        text: "x"
    }
}' fail "Text.RichText"

check "rich_text_js_assignment" '
Item {
    Text {
        text: "x"
        Component.onCompleted: textFormat = Text.RichText
    }
}' fail "textFormat set to Text.RichText"

check "bare_banned_token_elsewhere" '
Item {
    property int fmt: TextEdit.RichText
    Text { textFormat: Text.PlainText; text: "x" }
}' fail "TextEdit.RichText"

check "styled_text" '
Item {
    Text {
        textFormat: Text.StyledText
        text: "x"
    }
}' fail "Text.StyledText"

check "markdown_text" '
Item {
    Text {
        textFormat: Text.MarkdownText
        text: "x"
    }
}' fail "Text.MarkdownText"

# ---- round 2: numeric/parenthesised/dynamic writes, and routes around the bare identifier --------
check "numeric_dynamic_assignment" '
Item {
    Text {
        text: "x"
        Component.onCompleted: textFormat = 2
    }
}' fail "textFormat set to 2"

check "parenthesised_dynamic_assignment" '
Item {
    Text {
        text: "x"
        Component.onCompleted: textFormat = (Label.RichText)
    }
}' fail "Label.RichText"

check "bracket_quoted_assignment" '
Item {
    Text { textFormat: Text.PlainText; text: "x" }
    Component.onCompleted: t["textFormat"] = 2
}' fail "quoted property name"

check "binding_property_textformat" '
Item {
    Text { textFormat: Text.PlainText; text: "x" }
    Binding { target: parent; property: "textFormat"; value: 2 }
}' fail "textFormat"

check "create_qml_object" "
Item {
    Component.onCompleted: Qt.createQmlObject('import QtQuick; Text { text: x }', parent)
}" fail "createQmlObject"

# ---- compliant shapes the hardened guard must still accept ---------------------------------------
check "inline_delegate_compliant" '
Item {
    delegate: Text { textFormat: Text.PlainText; text: x }
}' pass

check "nested_child_each_with_its_own" '
Item {
    Text {
        textFormat: Text.PlainText
        Text { textFormat: Text.PlainText; text: "child" }
    }
}' pass

# ---- fail-closed on a malformed file, rather than a traceback ------------------------------------
check "unbalanced_braces_fail_closed" '
Item {
    Text {
        textFormat: Text.PlainText
' fail "unmatched"

echo
echo "$total checks, $((total - fail)) ok, $fail failed"
if [[ $fail -ne 0 ]]; then
    echo "plaintext-selftest.sh: FAIL"
    exit 1
fi
echo "plaintext-selftest.sh: ok"
