---
title: "Item already owns a final layer property"
description: "A QML Item has a built-in, final `layer` property group (layer.enabled, layer.effect), so a custom property named `layer` is a compile error; the tile's stacking role is `tileLayer` for that reason, and the model role stays `layer`."
tags: [frameworks, quickshell, qml]
confidence: verified
source: developer-input
date: 2026-09-20
---

# `Item` already owns a final `layer` property

Every `Item` carries a `layer` property group (`layer.enabled`, `layer.effect`, `layer.smooth`,
…) and it is *final*: a component cannot declare `property int layer`. The error is a compile
error, so it is caught — but only after the name has been threaded through a model role, a
delegate binding and a test, which is why it keeps being rediscovered.

## What the code does

The tile's stacking value is `tileLayer` (`WindowTile.qml`), seeded from the model's `layer`
role. The model role keeps the natural name because a `ListModel` role is not an `Item`
property; only the delegate-side property had to move. A tile's `z` is `tileLayer * 10 + hover`,
which is documented in `DESIGN.md` § Stacking.

## The rule

Before naming a property on anything that is an `Item`, check it is not already a member of
`Item`. The ones that have bitten or nearly bitten: `layer`, `state`, `children`, `data`,
`visible`, `opacity`, `scale`, `rotation`. Prefix with the component's noun (`tileLayer`,
`boxState`) rather than picking a synonym, so the model role and the property still read as the
same thing.

## See also

- [[adrs/0004-qt-compatibility-floor]] — the other class of "compiles locally, fails on CI" naming trap: reserved words.
- [[frameworks/quickshell/review-checklist]] — what to check in a component before merging.
