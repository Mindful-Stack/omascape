# Contributing to Omascape

Contributions are welcome — bug reports, fixes, and the roadmap items in
[ROADMAP.md](ROADMAP.md). This file is the process; [README.md](README.md) holds the technical
detail and links are given below rather than duplicated.

By participating you agree to the [Code of Conduct](CODE_OF_CONDUCT.md).

## Before you start

- **Reporting a bug?** Open a [bug report](https://github.com/Mindful-Stack/omascape/issues/new?template=bug_report.yml).
  Omascape is a compositor overlay, so your Omarchy, Hyprland and Quickshell versions and your
  monitor layout are usually the difference between a reproducible report and a guess.
- **Proposing a feature?** Open a [feature request](https://github.com/Mindful-Stack/omascape/issues/new?template=feature_request.yml)
  before writing code, especially for anything that changes the overlay's behaviour. Most
  features here have a design doc in [docs/specs/](docs/specs/) written before the
  implementation; that order is deliberate.
- **Found a security problem?** Do not open an issue — see [SECURITY.md](SECURITY.md).

## Getting set up

The README covers this properly; the short version:

- [Project layout](README.md#project-layout) — what each QML file and directory is.
- [Local development loop](README.md#local-development-loop) — `mise run dev:link` points your
  live Omarchy plugin directory at your checkout, `mise run dev:unlink` puts it back.
- [Testing](README.md#testing) — `mise run test` is Tier 1 and is what CI runs;
  `mise run test-integration` adds a nested Hyprland run.

You do not need to know Quickshell or QML deeply to contribute. The QML files are commented and
the shell APIs they use are documented inline in [DESIGN.md](DESIGN.md).

### The knowledge base

`lore/` is a [Lorekeeper](https://github.com/Mindful-Stack/witan) knowledge base tracked inline
in this repository — architecture decisions in `lore/knowledge/adrs/`, standards and measured
gotchas under `lore/knowledge/`. It is plain Markdown, so **you can read all of it without
installing anything**, and it is worth a look before a non-trivial change: ADR-0006, for
instance, is why `main` sometimes freezes.

To get the `/lore:*` commands inside Claude Code, install the plugin once per developer:

```
/plugin marketplace add Mindful-Stack/witan
/plugin install lore@witan          # choose USER level when prompted
```

`make validate` runs the knowledge-base validators and `make doctor` the full diagnostic. Note
that `make test` runs the *knowledge-base tooling's* own tests — it says nothing about whether
Omascape works. For that, `mise run test`.

## Making the change

1. Branch off `main`: `git checkout -b your-change`.
2. Keep commits focused, and write the message to explain the **why**. The what is in the diff.
3. If you change behaviour, update [DESIGN.md](DESIGN.md) and [ROADMAP.md](ROADMAP.md) to match.
   If the change is large enough to have needed a design, add the spec under `docs/specs/`.
4. Run the [pre-PR checklist](README.md#testing). Plenty of this overlay is visual, so that
   means reloading the shell and checking behaviour by hand — not just a green suite.
5. Open a PR against `Mindful-Stack/omascape`. The template asks what you tested; a screenshot
   or a short screen recording is worth a lot for anything that changes what the overlay looks
   like.

### CI conventions that are not stylistic

Two rules in `.github/workflows/ci.yml` are load-bearing and a PR that relaxes either will be
asked to change:

- Every GitHub Action is pinned to a **full 40-character commit SHA**, with the version in a
  trailing comment. Not a tag — tags move.
- The workflow declares least-privilege `permissions:` (`contents: read` today).

Both came out of a marketplace supply-chain review. Reverting either re-opens a resolved review
point and blocks the next listing update.

## Releases, and why `main` sometimes freezes

Omascape ships through two channels with different units of release. `omarchy plugin add` clones
whatever `main` points at, so **every merge to `main` reaches users directly**. The Omarchy
plugin marketplace separately lists one commit that a maintainer has verified.

Because a marketplace review has to be answerable against the commit that is still `main`'s HEAD
when the reviewer looks, releases run as a batch and `main` stops moving while a review is open.
If a maintainer asks you to hold a merge, that is why — it is not a comment on the PR. See
`lore/knowledge/adrs/0006-marketplace-publication.md`.

Version bumps and tags belong to that release train, not to individual feature PRs. Please don't
bump `manifest.json`'s `version` in a feature PR.

## Review

Maintainers: **[@DanielThyselius](https://github.com/DanielThyselius)**,
**[@dotnetemmanuel](https://github.com/dotnetemmanuel)**.

Expect review to focus on behaviour under real compositor conditions — multi-monitor, theme
switches, and what happens when Hyprland state changes underneath the overlay. If you can't test
a path (no second monitor, say), say so in the PR rather than leaving it implied; that is
normal and it is what the checklist's last item is for.
