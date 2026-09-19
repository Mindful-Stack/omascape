#!/usr/bin/env bash
# Stub-driven tests for scripts/dev-link.sh. No compositor and no Omarchy are
# needed: every binary the script talks to is replaced by a stub, and each case
# scripts those stubs through files under $STUB_STATE.
#
# What this suite CANNOT prove, because stubs cannot: that the real
# `quickshell list --json` and the real `systemctl --user show-environment`
# output are parsed correctly. Those are verified by hand on a live Omarchy
# machine — see docs/plans/2026-09-19-dev-link.md, Task 6.
set -uo pipefail                      # deliberately not -e: cases run failures

src=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
passed=0
failed=0
out=""
status=0
extra_env=()
script_path=""      # set by a case to run a COPY of the script from elsewhere

ok()  { printf '  ok   %s\n' "$1"; passed=$((passed + 1)); }
bad() { printf '  FAIL %s\n       %s\n' "$1" "${2-}"; failed=$((failed + 1)); }
same()     { if [[ $2 == "$3" ]];   then ok "$1"; else bad "$1" "expected [$3], got [$2]"; fi; }
has()      { if [[ $2 == *"$3"* ]]; then ok "$1"; else bad "$1" "output lacks [$3]: $2"; fi; }
lacks()    { if [[ $2 != *"$3"* ]]; then ok "$1"; else bad "$1" "output should not contain [$3]: $2"; fi; }
is_link()  { if [[ -L $2 ]];        then ok "$1"; else bad "$1" "$2 is not a symlink"; fi; }
is_dir()   { if [[ -d $2 && ! -L $2 ]]; then ok "$1"; else bad "$1" "$2 is not a real directory"; fi; }
absent()   { if [[ ! -e $2 && ! -L $2 ]]; then ok "$1"; else bad "$1" "$2 exists"; fi; }

# setup <case-name>: a sandbox with its own HOME, runtime dir and stub bin.
setup() {
  local box="$work/$1"
  mkdir -p "$box/home/.config/omarchy/plugins" "$box/run/hypr" "$box/bin" "$box/state"

  # hyprctl: answers only for signatures listed in state/answering.
  cat > "$box/bin/hyprctl" <<'STUB'
#!/bin/bash
grep -qxF "${HYPRLAND_INSTANCE_SIGNATURE:-}" "$STUB_STATE/answering" 2>/dev/null || exit 1
exit 0
STUB

  # systemctl: prints whatever state/session-env holds, like show-environment.
  # state/systemctl = `fail` models no user bus: non-zero, no output.
  cat > "$box/bin/systemctl" <<'STUB'
#!/bin/bash
[[ $(cat "$STUB_STATE/systemctl") == ok ]] || exit 1
cat "$STUB_STATE/session-env" 2>/dev/null
exit 0
STUB

  # omarchy: `plugin validate` honours state/validate; `restart shell` records
  # the signature it was handed and applies state/restart-outcome. It never
  # touches the instance list — that is quickshell's stub, kept separate so a
  # refusal and a slow start cannot be confused for one another.
  cat > "$box/bin/omarchy" <<'STUB'
#!/bin/bash
if [[ ${1:-} == plugin ]]; then
  [[ $(cat "$STUB_STATE/validate") == ok ]] || { echo "manifest.json: not valid" >&2; exit 1; }
  exit 0
fi
[[ ${1:-} == restart ]] || exit 0
printf '%s\n' "${HYPRLAND_INSTANCE_SIGNATURE:-unset}" > "$STUB_STATE/restart-signature"
case $(cat "$STUB_STATE/restart-outcome") in
refuse)
  echo "Refusing to restart Omarchy shell while the session is locked." >&2
  exit 1
  ;;
relock)
  echo "Omarchy shell restarted, but the session lock was not re-secured." >&2
  exit 1
  ;;
esac
exit 0
STUB

  # quickshell: counts its own calls. Reports the old instance until
  # `replace-after` calls have gone by, then the new one. `never` keeps the old
  # one forever; `none` reports an empty array.
  #
  # The mode is read ONCE into a variable. Re-reading it inside (( )) is how an
  # earlier draft produced `((: n >  : arithmetic syntax error` and a pid that
  # never changed, which silently turned every success case into a failure.
  cat > "$box/bin/quickshell" <<'STUB'
#!/bin/bash
n=$(( $(cat "$STUB_STATE/calls" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$STUB_STATE/calls"
mode=$(cat "$STUB_STATE/replace-after")
old='[{"id":"old","pid":2229103,"launch_time":"2026-09-19T07:00:00"}]'
new='[{"id":"new","pid":2230186,"launch_time":"2026-09-19T07:27:20"}]'
case $mode in
none)  echo '[]' ;;
never) echo "$old" ;;
*)     if (( n > mode )); then echo "$new"; else echo "$old"; fi ;;
esac
STUB

  # omarchy-shell: `shell ping` honours state/ping — `ok`, `dead`, or `after:N`
  # to answer only from its Nth call, which is how a replacement that exists
  # before its QML and IPC are up gets modelled.
  cat > "$box/bin/omarchy-shell" <<'STUB'
#!/bin/bash
n=$(( $(cat "$STUB_STATE/ping-calls" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$STUB_STATE/ping-calls"
mode=$(cat "$STUB_STATE/ping")
case $mode in
ok)      exit 0 ;;
dead)    exit 1 ;;
after:*) (( n >= ${mode#after:} )) && exit 0; exit 1 ;;
esac
exit 1
STUB

  chmod +x "$box"/bin/*
  # EVERY state file a stub reads is written here, with no stub relying on a
  # missing-file fallback: a stub that silently mis-defaults corrupts every case
  # that depends on it.
  printf 'session_sig\n' > "$box/state/answering"
  printf 'HYPRLAND_INSTANCE_SIGNATURE=session_sig\nOMARCHY_PATH=%s\n' "$box/omarchy" \
    > "$box/state/session-env"
  printf 'ok\n' > "$box/state/validate"
  printf 'ok\n' > "$box/state/restart-outcome"
  printf 'ok\n' > "$box/state/ping"
  printf '1\n' > "$box/state/replace-after"
  printf 'ok\n' > "$box/state/systemctl"
  mkdir -p "$box/omarchy/shell"
  printf '%s\n' "$box"
}

# run <box> [args…]: drive the real script. A stale inherited signature is
# ALWAYS present, so every case proves the inherited environment is ignored.
run() {
  local box=$1
  shift
  out=$(env -i \
    PATH="/usr/bin:/bin" \
    HOME="$box/home" \
    XDG_RUNTIME_DIR="$box/run" \
    STUB_STATE="$box/state" \
    HYPRCTL="$box/bin/hyprctl" \
    SYSTEMCTL="$box/bin/systemctl" \
    OMARCHY="$box/bin/omarchy" \
    QUICKSHELL="$box/bin/quickshell" \
    OMARCHY_SHELL_BIN="$box/bin/omarchy-shell" \
    DEV_LINK_POLL_SECONDS=2 \
    HYPRLAND_INSTANCE_SIGNATURE=stale_inherited_sig \
    "${extra_env[@]}" \
    bash "${script_path:-$src/scripts/dev-link.sh}" "$@" 2>&1)
  status=$?
}

plugin_dir() { printf '%s/home/.config/omarchy/plugins' "$1"; }
install_path() { printf '%s/se.mindfulstack.omascape' "$(plugin_dir "$1")"; }
stash_path() { printf '%s/.se.mindfulstack.omascape.install' "$(plugin_dir "$1")"; }

echo "dev-link:"

# --- the fixture itself: the instance stub must actually change its answer ---
# Every later case's verdict rests on this. An earlier draft's stub emitted a
# bash arithmetic error and returned the old pid forever, which would have made
# each ordinary success case fail for a reason having nothing to do with the
# script under test.
box=$(setup fixture-self-check)
first=$(STUB_STATE="$box/state" "$box/bin/quickshell" list 2>"$box/state/stub-err")
second=$(STUB_STATE="$box/state" "$box/bin/quickshell" list 2>>"$box/state/stub-err")
has  "fixture: first call reports the outgoing instance" "$first" "2229103"
has  "fixture: second call reports the replacement" "$second" "2230186"
same "fixture: the stub writes nothing to stderr" "$(cat "$box/state/stub-err")" ""

# --- a real install is stashed, not destroyed, and replaced by the link ------
box=$(setup stashes-real-install)
mkdir -p "$(install_path "$box")"
echo marker > "$(install_path "$box")/CLONE_MARKER"
run "$box"
same   "stash: exits 0" "$status" "0"
is_link "stash: install path is a symlink" "$(install_path "$box")"
same   "stash: symlink points at this worktree" "$(readlink "$(install_path "$box")")" "$src"
is_dir "stash: the real install moved aside" "$(stash_path "$box")"
same   "stash: its contents survived" "$(cat "$(stash_path "$box")/CLONE_MARKER" 2>/dev/null)" "marker"
has    "stash: receipt names the link" "$out" "linked   se.mindfulstack.omascape -> $src"

printf '\n  %d passed, %d failed\n' "$passed" "$failed"
(( failed == 0 )) || exit 1
