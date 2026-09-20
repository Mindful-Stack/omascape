---
title: Bash test harnesses — the two idioms, and the SKIP contract
description: Two shell harnesses with different jobs: tests/dev-link.sh counts assertions against stubbed binaries and must not use `set -e`, while tests/integration/ sources lib.sh and polls the real compositor; a skip is `echo SKIP; exit 0`, and only lua-check.sh turns a skip into a CI failure.
tags: [languages, bash, testing, ci]
---

# Bash test harnesses — the two idioms, and the SKIP contract

All four Tier 1 runners are launched from bash, and two of them — `tests/lua-check.sh` and
`tests/dev-link.sh` — are bash test suites in their own right. All of Tier 2 is. They do not share a harness, and
copying the wrong one into a new test is the usual mistake. [[languages/bash/script-conventions]]
covers how any script here is written; this node is which harness to copy and what a skip means.
Measured 2026-09-20 against `origin/main` (`7200771`).

## Pick the idiom from what the test needs

| Need | Copy | Shape |
|---|---|---|
| Drive a script with fake binaries | `tests/dev-link.sh` | counted assertions, stub `PATH`, sandboxed `HOME` |
| Drive a real compositor | `tests/integration/drag.sh` | `lib.sh` + `require_bins` + polls |

### Counted assertions (`tests/dev-link.sh`)

538 lines and a fixed assertion vocabulary defined at the top. A clean run on `7200771` reports
`112 passed, 0 failed` across 113 call sites:

```bash
ok()  { printf '  ok   %s\n' "$1"; passed=$((passed + 1)); }
bad() { printf '  FAIL %s\n       %s\n' "$1" "${2-}"; failed=$((failed + 1)); }
same()     { if [[ $2 == "$3" ]];   then ok "$1"; else bad "$1" "expected [$3], got [$2]"; fi; }
has()      { if [[ $2 == *"$3"* ]]; then ok "$1"; else bad "$1" "output lacks [$3]: $2"; fi; }
lacks()    { …; is_link() { …; is_dir() { …; absent() { …
```

Four properties make this work, and a new harness of this kind needs all four:

- **Every assertion takes a sentence as its first argument.** `has "no-bus: says the restart was
  skipped" "$out" "restart  skipped"` — the label is what a failing CI log shows, so it names the
  case and the behaviour, not the function under test.
- **Assertions count, they do not abort.** Hence `set -uo pipefail` without `-e`: the cases
  deliberately run the script into failure, and one failing expectation must not hide the other
  111. The exit status is decided once, at the end: `(( failed == 0 )) || exit 1`.
- **Each case gets its own sandbox.** `setup <case-name>` builds a box with its own `HOME`,
  runtime dir and `bin/` of stubs, so cases cannot leak into each other or touch the real plugin
  directory.
- **Stubs answer from a state file, not from a hardcoded branch.** The `hyprctl` stub reads
  `$STUB_STATE/answering`, the `systemctl` stub reads `$STUB_STATE/systemctl`, and the
  `omarchy-shell` stub reads `$STUB_STATE/ping` — which accepts `ok`, `dead` or `after:N`, so a
  case can model a replacement shell that exists before its QML and IPC are up. Vary the file,
  not the stub.

### Nested compositor (`tests/integration/*.sh`)

Source `lib.sh` *after* setting shell options, then call `require_bins` before anything else —
`drag.sh`, `fullscreen.sh`, `peek-probe.sh` and `probe-fullscreen.sh` all open this way:

```bash
set -euo pipefail
source "$(dirname "$0")/lib.sh"
require_bins
start_nested
```

`lib.sh` provides the rig (`start_nested`, `start_quickshell`, `spawn_window`), the IPC shims
(`hc`, `ipc`), the `jq` projections (`box`, `boxof`, `geometry`, `fsmode`, `wsof`, `dump`) and
the waits. **Add a new projection to `lib.sh` rather than inlining a second `jq` filter for the
same field** — that is why `wsof` and `fsmode` exist as one-liners.

`actions-probe.sh` and `lock-probe.sh` are the exceptions: they drive `hyprctl` against the
*live* session rather than a nested rig, so they carry their own inline `require_bins` loop and
do not source `lib.sh` at all. Copy one of those two only if your probe genuinely cannot run
nested.

## Waiting: poll a condition, bound the wait, fail loudly

The helpers in `lib.sh:146-172` are the pattern, and `sleep` appears in them only as the poll
interval:

```bash
wait_ws() {   # $1 addr, $2 workspace: wait until the client reports that workspace
    for _ in $(seq 1 40); do [[ "$(wsof "$1")" == "$2" ]] && return; sleep 0.1; done
    echo "FAIL: $1 did not reach workspace $2"; dump; exit 1
}
```

Three things to copy: a **bounded** loop (40 × 0.1s is the house budget), a **named failure** on
exhaustion, and a `dump` of the compositor state so the log is diagnosable without a rerun.
`settled_cursor` is the same idea for a value that is still moving — it returns only once two
reads agree.

**Bare `sleep` survives where nothing observable changes** — paints settling after a window's
first frame, waiting out a key-repeat delay (`peek-probe.sh:131,164`). Those carry a comment
saying what is being waited for. A bare `sleep` without one is a guess, and
`peek-probe.sh:120` records a review round that replaced exactly that. Prefer a poll whenever the
thing you are waiting for can be read back over IPC.

This is the same rule [[general/testing]] states for the QML UI suites, where the code does *not*
yet comply. The shell suite does; do not regress it.

## The SKIP contract, and the guard that makes it honest

A missing dependency prints and exits zero:

```bash
command -v "$bin" >/dev/null || { echo "SKIP: $bin not installed"; exit 0; }
```

That is `require_bins` (`lib.sh:6-10`) and the ten ad-hoc sites in the probe scripts. Prefix the
message with `SKIP:` and say which binary — a bare `exit 0` is indistinguishable from a pass.

A skip may also be **partial**: `actions-probe.sh:79,82` skips cases 1-2 for a probe window that never appeared or a missing `foot`, and
still runs cases 3-4, and `lock-probe.sh:78-79` marks one comparison `SKIP-SCOPING` rather than
abandoning the run. Say which cases you are dropping, and keep the rest.

**Only one script turns a skip into a failure, and that is the whole point of it.**
`tests/lua-check.sh:22`:

```bash
if [ -n "${CI:-}" ]; then echo "FAIL: $msg (CI must install them)" >&2; exit 1; fi
echo "SKIP: $msg"; exit 0
```

CI sets `CI: "1"` in the workflow precisely so this branch fires. Nothing else in the tree has
that guard.

**So: a new Tier 1 gate must carry the CI guard, or it is not a gate.** Without it, a runtime
missing from the CI image turns the check into a silent `exit 0` and `tests/run.sh` reports
success for a suite that ran nothing. Tier 2 scripts correctly do *not* have the guard — they are
not in CI, and skipping on a developer machine without Hyprland is their intended behaviour.
[[adrs/0003-test-tiers]] records the two-tier decision and notes that this enforcement reaches
`lua-check.sh` only.

## Registering a bash suite

`tests/run.sh` is a flat, ordered list under `set -e`: the resolved `qmltestrunner` invocation,
then `bash ui/run.sh`, `bash lua-check.sh`, `bash dev-link.sh`. A new bash suite is a line
appended there — nothing auto-discovers it — and because of `set -e`, **the first failing runner
stops the ones after it**. Put a fast, hermetic suite ahead of a slow one.

## See Also

- [[languages/bash/script-conventions]] — shebangs, strict mode, traps, `jq`.
- [[general/testing]] — which tier a test belongs in, and the QML side of the waiting rule.
- [[adrs/0003-test-tiers]] — why two tiers, and why the third was rejected.
- [[adrs/0001-dev-install-path]] — the behaviour `tests/dev-link.sh` covers.
- [[languages/lua/testing]] — the other half of `lua-check.sh`.
