---
title: "Installing an Omarchy plugin: the manifest id is the namespace, and enabling is a separate step"
description: "omarchy plugin add clones to a staging dir, validates, refuses a duplicate id, installs to ~/.config/omarchy/plugins/<manifest id> and only then offers to enable; enabling writes shell.json plugins[] through an IPC call, and rescanPlugins is async enough that add polls for up to two seconds."
tags: [omarchy, dev-workflow, release, tooling]
confidence: verified
source: developer-input
date: 2026-09-20
---

# Installing an Omarchy plugin: the manifest id is the namespace

Verified 2026-09-20 by reading `omarchy-plugin-add` and `omarchy-plugin-enable` in
`~/.local/share/omarchy/bin/`. [[general/release-and-distribution]] covers what reaching users
means for this repository; this is what actually happens on their machine.

## The install path is named after the manifest, not the repo

`omarchy plugin add <url>` clones into a staging directory, runs `omarchy-plugin-validate` on it,
reads `id` out of `manifest.json`, and only then moves it to:

```
~/.config/omarchy/plugins/<manifest id>/     # se.mindfulstack.omascape/
```

**The id is a global namespace.** If another installed plugin already claims it, add refuses and
names the manifest that holds it. Changing `manifest.json`'s `id` would therefore orphan every
existing install rather than upgrade it.

Validation happens **before** anything lands: a staged clone that fails validation is deleted and
nothing is installed. That is a different failure from the one in
[[general/release-and-distribution]], where a *later* validation failure on update strands an
existing install on its old commit.

## Enabling is separate, and "default disabled" is only half true

The ROADMAP's shorthand is that new plugins default disabled. What the script does:

- `--enable` → enabled without asking.
- Interactive, no flag → **prompts** "Enable '<id>' now?".
- `--yes`, or non-interactive (a script, a CI step, an agent tool call) → **not** enabled, and it
  prints `Enable it later with: omarchy plugin enable <id>`.

So the disabled default is what an automated install gets. A human at a terminal is asked.

Enabling does not edit a file directly — `omarchy-plugin-enable` calls
`omarchy-shell shell enablePlugin <id> <placement>` over IPC, and the result lands in
`~/.config/omarchy/shell.json` as an entry in `plugins[]`:

```json
{ "plugins": [ { "id": "se.mindfulstack.omascape" } ] }
```

## `rescanPlugins` is async, and add knows it

After installing, add runs `omarchy-shell shell rescanPlugins` and then **polls
`omarchy-plugin-list --json` up to 40 times at 50 ms** waiting for the id to appear before it
will enable it. Treat a rescan as a request, not a completed action: enabling immediately after
one can fail with `plugin '<id>' is not known`.

## Two smaller facts worth having

- A URL is checked by `omarchy-git-url-check` before cloning, so a URL naming a git option or a
  transport helper cannot run a command ahead of validation.
- A plugin whose `kinds` include `bar` cannot be given a placement — it replaces the bar rather
  than taking a slot in one. Omascape is `overlay`, so this never applies, but it is why
  `omarchy-plugin-enable` has a `kinds` check at the top.

## See also

- [[general/release-and-distribution]] — `main` is the release channel, and update is `--ff-only`.
- [[adrs/0001-dev-install-path]] — why development uses a symlink into this arrangement.
- [[learnings/plugin-hot-reload-serves-cached-source]] — why a restart is still mandatory after
  an edit.
