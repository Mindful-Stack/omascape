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

# --- identify the desktop session, before touching anything -----------------
# UWSM finalizes the session's HYPRLAND_INSTANCE_SIGNATURE into the systemd user
# environment; omarchy-restart-shell already reads OMARCHY_PATH from there. The
# inherited environment is not trusted (Claude Code's, and any long-lived
# shell's, goes stale), and an answering instance is never *chosen* — probing
# only ever confirms the identity the session already asserted.
session_var() {
  # `|| true` is required, not cosmetic: with no user bus, show-environment exits
  # non-zero, pipefail propagates that, and under set -e the ASSIGNMENT below
  # aborts the script — taking the promised offline link-and-skip path with it.
  "$SYSTEMCTL" --user show-environment 2>/dev/null | sed -n "s/^$1=//p" | tail -n 1 || true
}

answers() {
  [[ -n ${1:-} ]] || return 1
  HYPRLAND_INSTANCE_SIGNATURE="$1" "$HYPRCTL" version >/dev/null 2>&1
}

# Only reached when the session did not identify itself, so walking every stale
# runtime dir (there can be hundreds, left by the integration suite) is rare.
other_answerer() {
  local dir sig
  for dir in "${XDG_RUNTIME_DIR:-/run/user/$UID}"/hypr/*/; do
    [[ -d $dir ]] || continue
    sig=${dir%/}
    sig=${sig##*/}
    if answers "$sig"; then
      echo "$sig"
      return 0
    fi
  done
  return 1
}

session_sig=$(session_var HYPRLAND_INSTANCE_SIGNATURE)
omarchy_path=$(session_var OMARCHY_PATH)
# show-environment quotes values needing escapes as $'…'; neither of these two
# ever does, so anything unexpected is treated as no answer rather than parsed.
[[ $session_sig =~ ^[A-Za-z0-9_]+$ ]] || session_sig=""
[[ $omarchy_path == /* && -d $omarchy_path ]] || omarchy_path="/usr/share/omarchy"
config_dir="$omarchy_path/shell"

restart_ready=0
skip_reason=""
if answers "$session_sig"; then
  restart_ready=1
elif other=$(other_answerer); then
  fail "the session names no Hyprland instance, but $other answers. Refusing to restart a compositor I cannot identify; nothing was changed"
else
  skip_reason="no Hyprland instance answered (session signature: ${session_sig:-unset})"
fi

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

if (( restart_ready )); then
  echo "session  $session_sig  (systemctl --user show-environment; answers hyprctl)"
else
  echo "restart  skipped — $skip_reason"
fi
