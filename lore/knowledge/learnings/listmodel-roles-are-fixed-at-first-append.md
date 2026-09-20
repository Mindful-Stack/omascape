---
title: "ListModel roles are fixed at the first append"
description: "A ListModel's role set is frozen by the first append, so a later set() of a role that first row did not carry is silently ignored; every model here appends every role it will ever set, and the peek mini-map model is the case that found it."
tags: [frameworks, quickshell, qml]
confidence: verified
source: developer-input
date: 2026-09-20
---

# `ListModel` roles are fixed at the first `append`

A `ListModel` decides its role set from the first object it is given. A `set()` that names a
role the first row did not carry does not add the role; it is ignored, without a warning, and
the delegate binding on that role stays `undefined`.

This bit the peek's mini-map model, and every plan since 2026-09-18 has carried it in its
"Gotchas (each has bitten this repo before)" preamble — which is the signal
[[general/feature-workflow]] names for moving a gotcha into the knowledge base.

## The rule

**Append every role the model will ever `set`**, with a placeholder value if the real one is not
known yet. When adding a role to an existing model, add it to the `append` site first and the
`set` site second, or the new binding will appear to work in the one case where the first row
happened to carry it.

## See also

- [[learnings/a-behavior-cannot-share-x-with-drag-target]] — `ListModel.set` with equal values still emits.
- [[frameworks/quickshell/component-patterns]] — where the models live and who owns them.
