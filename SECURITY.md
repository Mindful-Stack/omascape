# Security Policy

## Reporting a vulnerability

**Please do not open a public issue for a security problem.**

Use GitHub's private vulnerability reporting:
[**Report a vulnerability**](https://github.com/Mindful-Stack/omascape/security/advisories/new).
It is visible only to repository administrators, and it lets us work on a fix and credit you in
the advisory.

If that form is unavailable to you, contact
[@DanielThyselius](https://github.com/DanielThyselius) and ask for a private channel before
sending details.

This is a two-maintainer project, not a staffed security team. We will acknowledge a report as
soon as we see it and keep you updated on what we find; we can't promise a fixed response time.
Please give us a reasonable chance to ship a fix before disclosing publicly.

## Supported versions

| Version | Supported |
| --- | --- |
| Current `main` | ✅ |
| Latest tag | ✅ |
| Anything older | ❌ |

There is no backporting. `omarchy plugin add` and `omarchy plugin update` both track `main`, so
in practice everyone runs the tip — a fix ships by landing on `main`.

## What Omascape can do on your system

Worth understanding before you assess a report, because most of it is by design and documented
in the README under "What it touches on your system":

- **Plugins are not sandboxed.** An Omarchy shell plugin is QML loaded into your long-lived
  `omarchy-shell` process and runs with your user's full privileges. This is true of every
  Omarchy plugin, Omascape included.
- Omascape **downloads nothing at runtime** and installs no packages. It needs only a stock
  Omarchy Quattro install.
- It **never edits your Hyprland or Omarchy configuration.** The toggle keybind is something you
  add yourself.
- The optional workspace-lock feature writes `~/.config/omarchy/omascape-locks.json` and
  `$XDG_RUNTIME_DIR/omascape/share-state`, and installs runtime-only `no_screen_share` window
  rules through Hyprland's IPC socket. Those rules live in the running compositor and are
  cleared by `hyprctl reload` — nothing is written to a config file.

A report that Omascape can read window titles, capture window contents, or drive the compositor
is not a vulnerability on its own: those are the overlay's function and require the user to have
installed and enabled it. A report that it does any of that **when it should not** — outside the
overlay's lifetime, without the user summoning it, or leaking that data anywhere off the machine
— very much is.

## Supply chain

- Every GitHub Action in `.github/workflows/` is pinned to a full 40-character commit SHA, never
  a mutable tag.
- Workflows declare least-privilege `permissions:`.
- The repository carries no install scripts that fetch and execute remote code.

If you find a path that breaks one of those three, report it — we treat those as security
findings even without a concrete exploit.

## A note on the marketplace listing

Omascape is listed on the [Omarchy plugin marketplace](https://plugins.omarchy.org/). That
listing pins a commit that passed the marketplace's automated baseline and a maintainer review.
**It is a listing check, not a security audit**, and the marketplace says so itself. Separately,
`omarchy plugin add` and `omarchy plugin update` install `main`'s current HEAD rather than the
verified commit, so what you install may be newer than what was reviewed. Inspect the code you
are about to enable — that advice applies to every plugin, not just this one.
