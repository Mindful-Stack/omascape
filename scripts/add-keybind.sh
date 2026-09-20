#!/bin/bash
# Add a toggle keybind for Omascape to your Hyprland config.
#
#   scripts/add-keybind.sh [KEY]
#
# KEY defaults to "SUPER + TAB". The script appends two lines to
# ~/.config/hypr/bindings.lua (or bindings.conf on a classic setup), backs the
# file up first, refuses to add a second copy, and touches nothing else.
# Read it before you run it; it is short on purpose.
set -euo pipefail

KEY="${1:-SUPER + TAB}"
PLUGIN_ID="se.mindfulstack.omascape"
ACTION="omarchy-shell shell toggle $PLUGIN_ID"
HYPR="${XDG_CONFIG_HOME:-$HOME/.config}/hypr"

fail() { echo "add-keybind: $*" >&2; exit 1; }

if [[ -f $HYPR/bindings.lua ]]; then
  target="$HYPR/bindings.lua"
  comment="--"
  # Unbind first. The default key is SUPER + TAB, which Omarchy already binds to "Next
  # workspace" -- appending a second bind for a key that is already taken is not what you
  # want. Unbinding a key that was NEVER bound is a no-op (verified against Hyprland 0.56:
  # `hl.unbind` on an unbound key reloads clean and leaves the bind count unchanged), so this
  # is safe for any key, taken or free.
  line="hl.unbind(\"$KEY\")
o.bind(\"$KEY\", \"Workspace overview\", \"$ACTION\")"
elif [[ -f $HYPR/bindings.conf ]]; then
  target="$HYPR/bindings.conf"
  comment="#"
  # "SUPER + SHIFT + P" -> "SUPER SHIFT, P" for the classic syntax: everything
  # before the LAST plus is modifiers, whitespace-separated.
  mods=$(printf '%s' "${KEY%+*}" | tr '+' ' ' | tr -s ' ' | sed 's/ *$//')
  key=$(printf '%s' "${KEY##*+}" | tr -d ' ')
  [[ -n $mods && -n $key ]] || fail "could not parse key '$KEY'; expected something like 'SUPER + TAB'"
  line="unbind = $mods, $key
bind = $mods, $key, exec, $ACTION"
else
  fail "found neither $HYPR/bindings.lua nor $HYPR/bindings.conf"
fi

if grep -qF "$PLUGIN_ID" "$target"; then
  echo "add-keybind: $target already binds $PLUGIN_ID; nothing to do."
  echo "Edit it by hand if you want a different key."
  exit 0
fi

backup="$target.bak.$(date +%s)"
cp -- "$target" "$backup"
printf '\n%s Omascape: workspace overview overlay\n%s\n' "$comment" "$line" >>"$target"

echo "Added to $target:"
echo "    $line"
echo "Backup: $backup"
echo
echo "Now reload Hyprland:  hyprctl reload"
echo "Then press $KEY to open Omascape."
