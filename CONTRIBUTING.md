# Contributing to Omascape

Contributions are welcome — bug reports, fixes, and the roadmap items in
[ROADMAP.md](https://github.com/Mindful-Stack/omascape/blob/dev/ROADMAP.md). This file is the
process; the [README on `dev`](https://github.com/Mindful-Stack/omascape/blob/dev/README.md)
holds the technical detail and links are given below rather than duplicated.

By participating you agree to the [Code of Conduct](CODE_OF_CONDUCT.md).

## Two branches, and which one you want

**`dev` is the project.** Specs, tests, tooling, the knowledge base, and the QML itself. Clone
it, work on it, open pull requests against it.

**`main` is the published plugin tree.** It holds the eleven QML files, `logic.js`, the manifest,
the preview, the licence and the community health files GitHub reads from a default branch —
and nothing else. It is built from `dev` by `scripts/publish.sh` and is never committed to by
hand.

The reason is that `main` is not a branch in the ordinary sense here: `omarchy plugin add` makes
a bare clone of the default branch and `omarchy plugin update` fast-forwards onto its tip, so
whatever `main` contains is what lands in every user's plugin directory. Shipping the specs, the
test suite and the workspace tooling to people who asked for an overlay is 7.8 MB of noise, and
the marketplace reviews the whole installed tree rather than the part the plugin loads — four
separate listing delays came out of files the overlay never touches. See
[ADR-0010](https://github.com/Mindful-Stack/omascape/blob/dev/lore/knowledge/adrs/0010-published-tree-is-the-default-branch.md).

So after cloning the repository, switch before you do anything else:

```
git switch dev
```

Do not open a pull request against `main`; it will be closed with a pointer back here.

(If you are wondering why this file avoids spelling out a clone command: it ships inside the
plugin, and the marketplace's security baseline reads every published file. `scripts/publish.sh`
refuses to build a tree that matches those patterns, which includes this one.)

## Before you start

- **Reporting a bug?** Open a [bug report](https://github.com/Mindful-Stack/omascape/issues/new?template=bug_report.yml).
  Omascape is a compositor overlay, so your Omarchy, Hyprland and Quickshell versions and your
  monitor layout are usually the difference between a reproducible report and a guess.
- **Proposing a feature?** Open a [feature request](https://github.com/Mindful-Stack/omascape/issues/new?template=feature_request.yml)
  before writing code, especially for anything that changes the overlay's behaviour. Most
  features here have a design doc in
  [docs/specs/](https://github.com/Mindful-Stack/omascape/tree/dev/docs/specs) written before the
  implementation; that order is deliberate.
- **Found a security problem?** Do not open an issue — see [SECURITY.md](SECURITY.md).

## Getting set up

The README on `dev` covers this properly; the short version:

- [Project layout](https://github.com/Mindful-Stack/omascape/blob/dev/README.md#project-layout) —
  what each QML file and directory is.
- [Local development loop](https://github.com/Mindful-Stack/omascape/blob/dev/README.md#local-development-loop)
  — `mise run dev:link` points your live Omarchy plugin directory at your checkout,
  `mise run dev:unlink` puts it back.
- [Testing](https://github.com/Mindful-Stack/omascape/blob/dev/README.md#testing) —
  `mise run test` is Tier 1 and is what CI runs; `mise run test-integration` adds a nested
  Hyprland run.

You do not need to know Quickshell or QML deeply to contribute. The QML files are commented and
the shell APIs they use are documented inline in
[DESIGN.md](https://github.com/Mindful-Stack/omascape/blob/dev/DESIGN.md).

### The knowledge base

`lore/` is a [Lorekeeper](https://github.com/Mindful-Stack/witan) knowledge base tracked inline
on `dev` — architecture decisions in `lore/knowledge/adrs/`, standards and measured gotchas
under `lore/knowledge/`. It is plain Markdown, so **you can read all of it without installing
anything**, and it is worth a look before a non-trivial change: ADR-0004 is why a property that
compiles locally can still break CI.

To get the `/lore:*` commands inside Claude Code, install the plugin once per developer:

```
/plugin marketplace add Mindful-Stack/witan
/plugin install lore@witan          # choose USER level when prompted
```

`make validate` runs the knowledge-base validators and `make doctor` the full diagnostic. Note
that `make test` runs the *knowledge-base tooling's* own tests — it says nothing about whether
Omascape works. For that, `mise run test`.

## Making the change

1. Branch off `dev`: `git checkout dev && git pull && git checkout -b your-change`.
2. Keep commits focused, and write the message to explain the **why**. The what is in the diff.
3. If you change behaviour, update
   [DESIGN.md](https://github.com/Mindful-Stack/omascape/blob/dev/DESIGN.md) and
   [ROADMAP.md](https://github.com/Mindful-Stack/omascape/blob/dev/ROADMAP.md) to match. If the
   change is large enough to have needed a design, add the spec under `docs/specs/`.
4. Run the [pre-PR checklist](https://github.com/Mindful-Stack/omascape/blob/dev/README.md#testing).
   Plenty of this overlay is visual, so that means reloading the shell and checking behaviour by
   hand — not just a green suite.
5. Open a PR **against `dev`**. The template asks what you tested; a screenshot or a short screen
   recording is worth a lot for anything that changes what the overlay looks like.

### If you add a file the overlay loads

New root `.qml` files are published automatically. Anything else — a new `.js` module, an asset
the QML reads at runtime — has to be added to the published set in `scripts/publish.sh`, or the
overlay will load on `dev` and fail on every installed copy. `scripts/publish.sh` refuses to
build a tree whose imports do not resolve, and `tests/publish.sh` covers that, so the failure
shows up as a red suite rather than as a broken release.

### CI conventions that are not stylistic

Two rules in `.github/workflows/ci.yml` are load-bearing and a PR that relaxes either will be
asked to change:

- Every GitHub Action is pinned to a **full 40-character commit SHA**, with the version in a
  trailing comment. Not a tag — tags move.
- The workflow declares least-privilege `permissions:` (`contents: read` today).

Both came out of a marketplace supply-chain review. Reverting either re-opens a resolved review
point and blocks the next listing update.

## Releases

Maintainers run the train; contributors do not need to touch it.

```
mise run release:publish          # builds the tree, records it on main
git push origin main
git tag -a v0.5.2 main && git push origin v0.5.2
```

`scripts/publish.sh` assembles the published tree with plumbing against a temporary index — no
branch is checked out and nothing is pushed — and refuses to build one whose manifest entry point
is missing, whose imports do not resolve, whose README links a screenshot that no longer exists,
or which trips the marketplace's own security-baseline patterns. On a machine with Omarchy
installed it also runs `omarchy-plugin-validate` against the built tree: that validator is step 4
of `omarchy plugin update`, and a tree it rejects does not fail loudly — the user is hard-reset
to their old commit, keeps a working plugin, and silently stops receiving updates. The release
commit records the
`dev` commit it came from in a `Source-commit:` trailer, which is what lets the next train check
that nothing already published is being rolled back.

### Branch protection

The two branches are protected differently, and the difference is load-bearing.

| | `main` | `dev` |
| --- | --- | --- |
| Required check | `logic-tests` — *never satisfiable* | `logic-tests` |
| Force pushes | blocked | blocked |
| Deletions | blocked | blocked |
| Administrators included | **no** | no |

`main` keeps `logic-tests` as a required check even though CI never runs there — workflows are
not published, and they would only ever report a skip on a branch with no tests. That is the
point: a check that can never go green means a pull request opened against `main` cannot be
merged by anybody. It is the one thing standing between an accidental merge and the whole
development tree landing in every user's plugin directory on their next update.

The release push gets through because administrators are exempt. **That exemption is part of the
release procedure, not an oversight** — switching on "Include administrators" for `main` makes
`mise run release:publish` unpushable, and the error does not mention branch protection. Blocked
force pushes matter for a different reason: `omarchy plugin update` is `merge --ff-only`, so
rewriting published history makes every existing install un-updatable.

`dev` requires `logic-tests` because it is now the integration branch. Setting it up, once:

```
gh api -X PUT repos/Mindful-Stack/omascape/branches/dev/protection --input - <<'JSON'
{
  "required_status_checks": { "strict": false, "contexts": ["logic-tests"] },
  "enforce_admins": false,
  "required_pull_request_reviews": null,
  "restrictions": null,
  "allow_force_pushes": false,
  "allow_deletions": false
}
JSON
```

Because `main` only moves when someone runs that, it sits still through a marketplace review on
its own — there is no freeze to hold and `dev` keeps merging throughout. What maintainers do hold
is the *publish*: while a listing request is open, don't run the train, because the marketplace
approves a commit only while it is still the default branch's HEAD.

Version bumps and tags belong to the train, not to individual feature PRs. Please don't bump
`manifest.json`'s `version` in a feature PR — the maintainer bumps it when the train departs,
and `publish.sh` refuses to ship a changed tree under the version that is already published.
The marketplace lists one version per commit, so two different trees published as `0.5.2` leave
the listing describing the wrong one. A release that genuinely changes no code says so with
`--allow-same-version`; an unchanged tree is a no-op and never reaches the question.

## Review

Maintainers: **[@DanielThyselius](https://github.com/DanielThyselius)**,
**[@dotnetemmanuel](https://github.com/dotnetemmanuel)**.

Expect review to focus on behaviour under real compositor conditions — multi-monitor, theme
switches, and what happens when Hyprland state changes underneath the overlay. If you can't test
a path (no second monitor, say), say so in the PR rather than leaving it implied; that is
normal and it is what the checklist's last item is for.
