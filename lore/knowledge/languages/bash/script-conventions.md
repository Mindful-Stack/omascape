---
title: Bash script conventions
description: Bash is the entry point for every gate in this repo — CI and all four mise tasks are `bash …` — and the conventions are uniform: shebang by tree, `set -euo pipefail` with two documented exceptions, never trust a bare tool name, mktemp plus an EXIT trap, and jq as the only IPC parser.
tags: [languages, bash, testing, tooling, ci]
---

# Bash script conventions

Shell is not glue here, it is the harness. **Every gate in the repository is a bash entry
point**: the CI workflow's only job runs `bash tests/run.sh`, and all four `mise.toml` tasks
(`test`, `test-integration`, `link`, `unlink`) are a single `bash …` line. Nothing else starts a
test run.

Measured 2026-09-20 against `origin/main` (`7200771`) plus `tests/split-lore.sh` added on this
branch: **15 scripts, 2111 lines**, split `tests/` 13 and `scripts/` 2. [[languages/bash/test-harnesses]] covers how the test scripts
assert; this node is how any script here is written.

> **Scope.** The household scaffold adds six more scripts under `scripts/` — `setup.sh`,
> `pull-all.sh`, `rename.sh`, `split-lore.sh`, `status-all.sh`, `update-kb.sh`. Those are
> template-supplied workspace tooling, not Omascape's, and they are maintained upstream. They
> happen to follow the same shebang and strict-mode rules, so nothing below conflicts, but do
> not treat them as the reference when the template and this node disagree.
>
> **`split-lore.sh` has deliberately diverged from upstream** and is covered by
> `tests/split-lore.sh`. The template's version assumes the template's `.gitignore` — a catch-all
> `/*` plus a `!/lore/` allowlist — which this repository does not have and deliberately did not
> adopt. Without it the upstream script commits its own backup, records the split as a *rename*
> rather than a removal, and leaves an untracked nested repo. If you ever re-sync this file from
> the template, run the suite before you keep the result.

## The header is not negotiable

Shebang follows the tree, and the split is total:

| Tree | Shebang | Compliance |
|---|---|---|
| `scripts/` | `#!/bin/bash` | 2 of 2 (and 6 of 6 scaffold scripts) |
| `tests/` | `#!/usr/bin/env bash` | 13 of 13 |

Then `set -euo pipefail`, on its own line, before anything else runs — 12 of 15. **All three
exceptions are deliberate and every one says so in the file:**

- `tests/dev-link.sh` uses `set -uo pipefail` with the trailing comment
  *"deliberately not -e: cases run failures"*. A test harness whose cases assert on non-zero exits
  cannot abort on the first one.
- `tests/integration/lib.sh` sets nothing, because it is sourced. Its header says *"Source it
  after `set -euo pipefail`"* — the caller owns the shell options.
- `tests/split-lore.sh` carries the same trailing comment as `tests/dev-link.sh`, for the same
  reason: its cases assert on non-zero exits.

If you write a third exception, put the reason on the `set` line the way these two do.

## Never trust a bare tool name

`tests/run.sh:5-13` is the pattern, and the comment states the failure it prevents: on some
distros PATH's `qmltestrunner` is Qt5, which *silently exits 1* on Qt6 imports. So the runner is
resolved, never invoked by bare name:

```bash
if command -v qmltestrunner6 >/dev/null 2>&1; then
  RUNNER=qmltestrunner6                          # Debian/Ubuntu (qt6-declarative-dev-tools)
elif [ -x /usr/lib/qt6/bin/qmltestrunner ]; then
  RUNNER=/usr/lib/qt6/bin/qmltestrunner          # Arch (qt6-declarative), upstream layout
else
  echo "No Qt6 qmltestrunner found (tried: …)." >&2
  exit 127
fi
```

Two rules fall out of it. **Name both distro layouts in a comment** — the reader has one of them
and needs to know the other exists. **Fail with an install hint, not a stack trace**: the `else`
branch names the Arch and Debian package. `tests/ui/run.sh:18-19` resolves the same binary in two
lines without the `else`, which is tolerable only because `set -e` turns the missing path into a
non-zero exit anyway — it just loses the hint.

## Temporary state is trapped, always

`mktemp -d` paired with a `trap` on `EXIT`, set at the point the directory is created:

```bash
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
```

`tests/integration/lib.sh` does the same at source time and grows the trap into a full `cleanup`
that kills the nested compositor and the Quickshell process. Every teardown step is written
`[[ -z "$pid" ]] || kill "$pid" 2>/dev/null || true` — guarded on both ends, so a rig that died
half-started still reaches the `rm -rf "$tmp"` on the last line.

## jq is the only parser

All compositor IPC is read as JSON and projected with `jq` — **88 occurrences across the seven
integration scripts**, and the `hyprctl … -j | jq` shape is the house form:

```bash
box() { hc clients -j | jq -r --arg a "$1" '.[]|select(.address==$a)|"\(.at[0]) \(.at[1]) …"'; }
```

Pass values in with `--arg` rather than interpolating them into the filter — every projection in
`lib.sh` does. The one script that interpolates, `lock-probe.sh`, validates the value as numeric
first with a `case "$WS" in ''|*[!0-9]*)` guard that exits 1; if you interpolate, do that too.

Never parse `hyprctl`'s human output with `grep`/`awk` when a `-j` form exists.

## Quoting, and the one thing that is not settled

Expansions are quoted, and `${VAR:-}` is the form for anything that may be unset — mandatory
under `set -u`, and the reason `"${CI:-}"` and `"${HYPRLAND_INSTANCE_SIGNATURE:-}"` are written
that way.

**Conditionals are not consistent, and this node does not pretend otherwise.** `[[ ]]` is the
majority form by a wide margin — 123 occurrences across eight scripts — but four files use `[ ]`
exclusively: `tests/integration/actions-probe.sh` (11), `tests/lua-check.sh` (4),
`tests/integration/lock-probe.sh` (3) and `tests/run.sh` (1). Nothing in the tree explains the
split, and no file mixes the two.

Write `[[ ]]` in new code: it is the majority, it needs no quoting around `$1` in a pattern test,
and every helper in `lib.sh` and `tests/dev-link.sh` already uses it. Leave the four `[ ]` files
alone unless you are rewriting them.

## There is no lint gate

`shellcheck` is not run by CI, by `mise`, or by any script. The only trace of it in shell is one
suppression — `tests/integration/peek-probe.sh:7`, `# shellcheck disable=SC2119`, with the reason
in the same line — which means someone ran it by hand once. **Review is the only check on shell**,
which is why the conventions above are worth holding to by hand. Writing the directive when you
do run it locally is welcome; it costs nothing and records the judgement.

## See Also

- [[languages/bash/test-harnesses]] — the two assertion idioms, and the SKIP contract.
- [[general/testing]] — which tier a test belongs in and what has to be edited for it to run.
- [[adrs/0001-dev-install-path]] — `scripts/dev-link.sh`, the largest non-test script.
- [[adrs/0003-test-tiers]] — why there are two tiers.
