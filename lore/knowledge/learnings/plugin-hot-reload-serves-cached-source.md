---
title: "The shell's plugin hot reload rebuilds components from cached source"
description: "Omarchy's plugin reload destroys and re-creates the component but never clears the QML type cache, because its guard tests for Qt.clearComponentCache which is undefined in QML — so saving a plugin file looks like a reload while serving the old code."
tags: [omarchy, quickshell, qml, dev-workflow]
confidence: verified
source: developer-input
date: 2026-09-20
---

# The shell's plugin hot reload rebuilds components from cached source

Measured 2026-09-19 against Omarchy `4.0.0.alpha`.

The reload machinery is real and it does fire. `localPluginWatcher`
(`PluginRegistry.qml:636`) runs `inotifywait -m -r` over the plugins directory and emits
`localPluginChanged(id)`; `shell.qml:763` handles it and kicks `localPluginReloadTimer` →
`reloadPlugins`. The component really is destroyed and re-created — `Component.onCompleted`
fires again.

It is rebuilt from the engine's cached compilation unit, so the new source never takes effect.

## The measurement

A throwaway overlay plugin installed as a real directory (not a symlink), logging a version
string from its QML and from an imported `probe.js`, driven with no restart at all — one shell
process throughout:

| Change on disk | Reload fired | Component re-created | Version logged |
| --- | --- | --- | --- |
| plugin first added | yes | yes | `qml=v1 js=v1` — a **new** file compiles fresh |
| `probe.js` → v2 | yes | yes | `qml=v1 js=v1` — **stale** |
| `Probe.qml` → v2 | yes | yes | `qml=v1 js=v1` — **stale** |

Only files the engine has never compiled load fresh.

## The cause

`finishPluginReload` (`shell.qml:757`) guards its cache clear with
`if (typeof Qt.clearComponentCache === "function")`, and **`Qt.clearComponentCache` is undefined
in QML** — it exists only as the C++ `QQmlEngine::clearComponentCache()`. Verified directly
(`typeof … = undefined` under `qmltestrunner`) and corroborated by the stale-source result. The
intent is in the code; the call has never run.

## What follows

Saving a file under `~/.config/omarchy/plugins/` *looks* like it reloaded while serving old code,
which is worse than no reload at all. A full shell restart is mandatory after every edit. The
shell README's claim that saving a file reloads plugin code automatically is misleading as
written.

Separately: `inotifywait -r` does not descend symlinks, so a linked worktree fires no reload
events whatsoever.

## See also

- [[adrs/0001-dev-install-path]] — this measurement is what rejected a copy-based deploy.
- Recorded as a suggested upstream fix under "Deliberately out of scope" in
  `docs/specs/2026-09-19-dev-link-design.md`. Not filed.
