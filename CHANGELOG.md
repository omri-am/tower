# Changelog

Consumers see only a version number in the update notice, so every entry here has to say
what the version gives them.

## Unreleased

## v0.2.0 — 2026-08-27

- `tower-card` renders a task card as a bordered CLI view — frontmatter, every section, and a
  done/total count on the acceptance criteria — or the whole board with no arguments, so
  reviewing a card before approving it never means opening `.tower/tasks/`. The orchestrator
  runs the same command, so what you read at the approval gate is the card on disk rather
  than a one-line summary of it. `--plain` gives ASCII output for piping and for
  orchestrators that are not Claude Code; `TOWER_CARD_WIDTH` sets the render width.

## v0.1.1 — 2026-08-27

- Tower installs as a Claude Code plugin from its own marketplace, so features arrive
  through `/plugin update tower@tower` instead of a manual `git pull`.
- `tower-bootstrap` links the shell commands through a resolver shim, so a version bump
  needs no relinking.
- Installs report a newer tower once a day: a stderr line before any tower command run
  through the `tower-bootstrap` shim, and a SessionStart note inside Claude sessions.
  Silence it with `TOWER_NO_VERSION_CHECK=1`.
- `.tower/` records the protocol version it was scaffolded for, and a mismatch warns.
