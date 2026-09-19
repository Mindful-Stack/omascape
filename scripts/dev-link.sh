#!/bin/bash
# Point the live Omarchy plugin dir at this worktree, and restart the shell.
#
#   scripts/dev-link.sh            # link this worktree, then restart
#   scripts/dev-link.sh --unlink   # restore the stashed clone install, then restart
#
# Several worktrees share one global plugin id, hence one install directory.
# This takes that directory over with a symlink to the worktree it was run from,
# moving any real install aside to a dot-prefixed sibling that Omarchy's scans
# ignore. It restarts only a compositor it can positively identify: a stale
# inherited HYPRLAND_INSTANCE_SIGNATURE is how the bar was lost on 2026-09-18.
# See docs/specs/2026-09-19-dev-link-design.md.
# Read it before you run it; it is short on purpose.
set -euo pipefail

PLUGIN_ID="se.mindfulstack.omascape"

# Omarchy hardcodes this path (shell/services/PluginRegistry.qml:11, and
# omarchy-plugin-catalog), so XDG_CONFIG_HOME is deliberately NOT honoured:
# linking anywhere else succeeds and then loads nothing.
PLUGINS_DIR="$HOME/.config/omarchy/plugins"
INSTALL="$PLUGINS_DIR/$PLUGIN_ID"
STASH="$PLUGINS_DIR/.$PLUGIN_ID.install"

# Overridable so the test suite can drive this without a compositor.
HYPRCTL="${HYPRCTL:-hyprctl}"
OMARCHY="${OMARCHY:-omarchy}"
OMARCHY_SHELL_BIN="${OMARCHY_SHELL_BIN:-omarchy-shell}"
QUICKSHELL="${QUICKSHELL:-quickshell}"
SYSTEMCTL="${SYSTEMCTL:-systemctl}"
POLL_SECONDS="${DEV_LINK_POLL_SECONDS:-10}"

REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)

fail() { echo "dev-link: $*" >&2; exit 1; }

MODE=link
case "${1:-}" in
"") ;;
--unlink) MODE=unlink ;;
-h | --help) sed -n '2,12p' "${BASH_SOURCE[0]}"; exit 0 ;;
*) fail "unknown argument: $1" ;;
esac

# --- take over the install path ---------------------------------------------
previous=""
if [[ $MODE == link ]]; then
  mkdir -p -- "$PLUGINS_DIR"

  # Running from the installed clone itself is a supported loop (README: "edit
  # the installed folder directly"). There REPO *is* INSTALL: stashing it and
  # linking to $REPO would point the install path at itself and the plugin would
  # vanish. It is already the live checkout, so only the restart is owed.
  install_real=""
  [[ -e $INSTALL && ! -L $INSTALL ]] && install_real=$(cd -- "$INSTALL" && pwd -P)

  if [[ -n $install_real && $install_real == "$REPO" ]]; then
    echo "linked   $PLUGIN_ID -> $REPO (already the installed checkout; nothing to link)"
  elif [[ $REPO == "$PLUGINS_DIR"/* ]]; then
    # Any other checkout inside the plugins dir is discovered as a plugin in its
    # own right, so linking it would present the same id twice.
    fail "this worktree is inside $PLUGINS_DIR, where Omarchy would discover it a second time under the same id; move it outside the plugins directory first"
  elif [[ -L $INSTALL ]]; then
    previous=$(readlink -- "$INSTALL")
    ln -sfn -- "$REPO" "$INSTALL"      # -n is load-bearing: without it this
                                       # links INSIDE the old target instead
  elif [[ -d $INSTALL ]]; then
    [[ -e $STASH || -L $STASH ]] &&
      fail "$STASH already exists; move or remove it first (nothing was changed)"
    mv -- "$INSTALL" "$STASH"
    ln -s -- "$REPO" "$INSTALL"
    previous="a real install, moved to ${STASH##*/}"
  elif [[ -e $INSTALL ]]; then
    fail "$INSTALL is neither a symlink nor a directory; refusing to touch it"
  else
    ln -s -- "$REPO" "$INSTALL"
  fi
  # The already-live branch printed its own line above.
  [[ -n $install_real && $install_real == "$REPO" ]] || echo "linked   $PLUGIN_ID -> $REPO"
  [[ -z $previous ]] || echo "was      $previous"
fi
