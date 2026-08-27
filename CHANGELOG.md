# Changelog

Consumers see only a version number in the update notice, so every entry here has to say
what the version gives them.

## Unreleased

- Tower installs as a Claude Code plugin from its own marketplace, so features arrive
  through `/plugin update tower@tower` instead of a manual `git pull`.
- `tower-bootstrap` links the shell commands through a resolver shim, so a version bump
  needs no relinking.
- Installs report a newer tower once a day: a stderr line before any tower command, and a
  SessionStart note inside Claude sessions. Silence it with `TOWER_NO_VERSION_CHECK=1`.
- `.tower/` records the protocol version it was scaffolded for, and a mismatch warns.
