## What this changes

<!-- What it does and, more usefully, why. The what is in the diff. -->

## How it was tested

<!--
Plenty of this overlay is visual, so a green suite is not the whole story.
Say what you actually exercised by hand, and on what hardware.
-->

- [ ] `mise run test` passes.
- [ ] `omarchy plugin validate .` passes.
- [ ] SUPER+TAB opens and closes the overlay; `Esc` and click-outside close it.
- [ ] Number keys `1`–`0` jump to the right workspace; Tab + `Enter` work; arrows step windows; click works.
- [ ] The window mini-map roughly matches my real window layout.
- [ ] It re-themes correctly after `omarchy theme next` (or any theme switch).
- [ ] Second monitor: the two-row layout and per-monitor mini-map coordinates are correct.

<!--
No second monitor? Say so rather than leaving the box blank and unexplained —
that path is still being validated and knowing it is untested is useful.
-->

## Screenshots / recording

<!-- For anything that changes what the overlay looks like, this is worth a lot. -->

## Docs

- [ ] Behaviour change is reflected in `DESIGN.md` / `ROADMAP.md`.
- [ ] A spec under `docs/specs/` exists, if the change was big enough to need a design.
- [ ] `manifest.json`'s `version` is **not** bumped here — version bumps belong to the release train (see [CONTRIBUTING.md](../blob/main/CONTRIBUTING.md)).
