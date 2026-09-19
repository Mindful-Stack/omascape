#!/bin/bash
# Point the live Omarchy plugin dir at this worktree, and restart the shell.
#
#   scripts/dev-link.sh            # link this worktree, then restart
#   scripts/dev-link.sh --unlink   # restore the stashed clone install, then restart
#   scripts/dev-link.sh --status   # report what is live; changes nothing
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
--status) MODE=status ;;
-h | --help) sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'; exit 0 ;;
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

# One line per live instance of this shell config: "<pid> <launch_time>".
# --all, then filter by config path ourselves: `list -p` reports only instances of
# the CALLER's Wayland display, so from a TTY or over ssh it finds none while the
# desktop shell is running. RS="}" splits one record per instance, so this holds
# for pretty or compact JSON and for a config path containing a space.
instances() {
  "$QUICKSHELL" list --all --json 2>/dev/null |
    awk -v want="\"$config_dir/shell.qml\"" 'BEGIN { RS = "}" }
      index($0, want) && match($0, /"pid"[[:space:]]*:[[:space:]]*[0-9]+/) {
        pid = substr($0, RSTART, RLENGTH)
        gsub(/[^0-9]/, "", pid)
        lt = ""
        if (match($0, /"launch_time"[[:space:]]*:[[:space:]]*"[^"]+"/)) {
          lt = substr($0, RSTART, RLENGTH)
          sub(/^.*: *"/, "", lt)
          sub(/"$/, "", lt)
        }
        print pid " " lt
      }'
}

pids_now() { instances | awk '{ print $1 }' | sort; }

ping_ok() {
  env OMARCHY_PATH="$omarchy_path" OMARCHY_SHELL_IPC_TIMEOUT=0.5s \
    "$OMARCHY_SHELL_BIN" shell ping >/dev/null 2>&1
}

omarchy_path=$(session_var OMARCHY_PATH)
[[ $omarchy_path == /* && -d $omarchy_path ]] || omarchy_path="/usr/share/omarchy"
config_dir="$omarchy_path/shell"

# --- status: report and exit, touching nothing -------------------------------
if [[ $MODE == status ]]; then
  if [[ -L $INSTALL ]]; then
    target=$(readlink -- "$INSTALL")
    echo "linked   $PLUGIN_ID -> $target"
    if [[ -d $target/.git || -f $target/.git ]]; then
      branch=$(git -C "$target" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?")
      sha=$(git -C "$target" rev-parse --short HEAD 2>/dev/null || echo "?")
      dirty=""
      [[ -z $(git -C "$target" status --porcelain 2>/dev/null) ]] || dirty=" (dirty)"
      echo "branch   $branch @ $sha$dirty"
    fi
  elif [[ -d $INSTALL ]]; then
    echo "install  $PLUGIN_ID is an ordinary directory (not linked to a worktree)"
  else
    echo "install  $PLUGIN_ID is not installed"
  fi
  [[ -d $STASH ]] && echo "stashed  ${STASH##*/} holds a displaced install"

  # Is the RUNNING shell actually that build? The QML engine caches compiled
  # source per URL, and the URL is the path through the symlink, so re-pointing
  # the link does not reach a shell that is already running (measured — see the
  # spec, finding 11). A shell older than the link is therefore serving the
  # previous worktree, whatever the link says now.
  if instance=$(instances | head -n 1) && [[ -n $instance ]]; then
    pid=${instance%% *}
    started=${instance#* }
    echo "shell    pid $pid, started $started"
    if [[ -L $INSTALL ]]; then
      link_epoch=$(stat -c %Y -- "$INSTALL" 2>/dev/null || echo 0)   # the link, not its target
      start_epoch=$(date -d "$started" +%s 2>/dev/null || echo 0)
      if (( start_epoch > 0 && link_epoch > 0 && start_epoch < link_epoch )); then
        echo "verdict  STALE — the running shell predates this link, so it is still serving the previous checkout; run: mise run dev:link"
      else
        echo "verdict  live — the running shell started after this link was written"
      fi
    fi
  else
    echo "shell    not running"
  fi
  exit 0
fi

session_sig=$(session_var HYPRLAND_INSTANCE_SIGNATURE)
# show-environment quotes values needing escapes as $'…'; neither of these two
# ever does, so anything unexpected is treated as no answer rather than parsed.
[[ $session_sig =~ ^[A-Za-z0-9_]+$ ]] || session_sig=""

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
  # Refuse a broken manifest before anything is touched; the shell silently
  # ignores a plugin whose manifest does not validate. Only when LINKING: on
  # --unlink the checkout's manifest is irrelevant, and letting it block the
  # restore would make a broken checkout unrecoverable.
  "$OMARCHY" plugin validate "$REPO" >/dev/null ||
    fail "omarchy plugin validate failed for $REPO; nothing was changed"

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

  # Any uncommitted change counts, untracked files included: the shell loads the
  # working tree exactly as it is on disk.
  branch=$(git -C "$REPO" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?")
  sha=$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo "?")
  dirty=""
  [[ -z $(git -C "$REPO" status --porcelain 2>/dev/null) ]] || dirty=" (dirty)"
  echo "branch   $branch @ $sha$dirty"
else
  if [[ -L $INSTALL ]]; then
    previous=$(readlink -- "$INSTALL")
    rm -- "$INSTALL"
  elif [[ -e $INSTALL ]]; then
    fail "$INSTALL is not a symlink; refusing to move a real install"
  fi
  if [[ -d $STASH ]]; then
    mv -- "$STASH" "$INSTALL"
    echo "restored $PLUGIN_ID <- ${STASH##*/}"
    # A warning, never fatal: the restore IS the recovery path, so refusing to
    # finish it because the restored copy is imperfect would leave no install at all.
    "$OMARCHY" plugin validate "$INSTALL" >/dev/null 2>&1 ||
      echo "warning  the restored install does not pass omarchy plugin validate; the shell will ignore it" >&2
  else
    echo "unlinked $PLUGIN_ID (no stashed install to restore)"
  fi
  [[ -z $previous ]] || echo "was      $previous"
fi

# --- restart, and verify a REPLACEMENT ---------------------------------------
# `quickshell list` without --show-dead reports only live instances, so a pid
# that was not in the outgoing set is a new shell. Status, ping and replacement
# are three separate facts: omarchy-restart-shell exits non-zero both when it
# refuses outright (session locked; old shell still answers ping) and when it
# restarted fine but could not re-secure the lock.

if (( restart_ready )); then
  echo "session  $session_sig  (systemctl --user show-environment; answers hyprctl)"

  # An empty instance list is legitimate (nothing running yet) and makes the
  # pipeline's grep exit non-zero, which pipefail would turn into a silent abort.
  before=$(pids_now || true)

  restart_status=0
  restart_out=$(env HYPRLAND_INSTANCE_SIGNATURE="$session_sig" \
    "$OMARCHY" restart shell 2>&1) || restart_status=$?

  # A replacement can exist while its QML and IPC are still coming up, so the
  # deadline bounds BOTH facts: keep polling until a new pid answers ping, not
  # until a new pid merely appears.
  new_pid=""
  ready=0
  deadline=$((SECONDS + POLL_SECONDS))
  while :; do
    [[ -n $new_pid ]] ||
      new_pid=$(comm -13 <(printf '%s\n' "$before") <(pids_now || true) | head -n 1)
    if [[ -n $new_pid ]] && ping_ok; then
      ready=1
      break
    fi
    (( SECONDS < deadline )) || break
    sleep 0.2
  done

  if (( ready )); then
    echo "restart  ok — new instance pid $new_pid"
    if (( restart_status != 0 )); then
      echo "warning  omarchy restart shell exited $restart_status:" >&2
      [[ -z $restart_out ]] || echo "$restart_out" >&2
    fi
  elif [[ -n $new_pid ]]; then
    fail "a new shell (pid $new_pid) started but never answered ping within ${POLL_SECONDS}s; check: journalctl --user -t omarchy-shell -n 60"
  elif ping_ok; then
    [[ -z $restart_out ]] || echo "$restart_out" >&2
    fail "no new shell instance appeared: the shell was not restarted and the previously loaded build is still running (the link IS in place)"
  else
    [[ -z $restart_out ]] || echo "$restart_out" >&2
    fail "the shell is not running and no replacement appeared; check: journalctl --user -t omarchy-shell -n 60"
  fi
else
  echo "restart  skipped — $skip_reason"
fi
