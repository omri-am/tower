# Changelog

Consumers see only a version number in the update notice, so every entry here has to say
what the version gives them.

## Unreleased

- `tower-dispatch`, `tower-card`, `tower-learnings` and `tower-pr-wait` now refuse to guess
  when a task ID matches more than one card, naming every matching file instead of silently
  taking the first one `find` happens to return. `tower-doctor` also flags duplicate IDs
  across cards and a card whose filename disagrees with its `id:` field.

- PROTOCOL.md and the `tower-implementor`/`tower-orchestrator` skills now specify how task
  ids are allocated: flat `T###` numbers are the orchestrator's alone, and a follow-up card
  an implementor drafts directly takes its parent's id plus the next letter (`T327a`,
  `T327b`, …) instead of a new flat number, so the two allocators can never collide.

- Added `tower <command>` for every public CLI command, including `tower ui` and
  `tower bootstrap`. The existing hyphenated commands remain compatible; once the
  unified entry point is linked, new subcommands need no additional PATH links.

## v0.4.0 — 2026-09-09

- The browser workspace now includes a Kanban view with collapsible workflow columns,
  card detail dialogs, and comment counts. In flight uses purple and In review uses teal;
  column headings and card badges share these colors in both views.

- Browser cards now have persistent comment threads with retained drafts, retry-safe saves,
  and scoped Git commits. The orchestrator reads owner feedback from `.tower/comments/`.
  Colored group headings and badges distinguish approval, dispatchable, waiting, active,
  merged, and invalid states; dependency-blocked ready cards are explicitly labeled Waiting.

- `tower-ui` adds an optional local browser workspace for daily card review: a searchable
  queue with full titles, approval/dispatch/waiting groups, complete card details, keyboard
  navigation, and separate approval and dispatch actions. It preserves selection during
  refresh and explains incomplete prerequisites. Actions reject changed cards or prompts;
  approvals commit only the reviewed card, and dispatch reuses the CLI checks and lock.
  Requires Python 3.9+ for the local server, with no third-party packages or build step.

- `tower-doctor` diagnoses local recovery issues in cards, dispatch locks, worktrees and
  handoffs, with actionable next steps and an exit status for automation. It is read-only
  and offline, including through the bootstrap shim; it never guesses session liveness
  or declares a lock stale without evidence.

## v0.3.0 — 2026-09-07

- Dispatch validates repository identity, canonical shared state and task markers before
  adopting a worktree. In-place dispatch checks out its recorded branch, and default
  worktree and branch names include the project path to avoid monorepo task-ID collisions.
- Ownership overlap checks now run under a dispatch lock and reserve paths through review
  and blocking. Learning selection uses the same path parser, including extensionless files.
- `tower-dispatch --resume` recovers an interrupted in-flight task in its original worktree,
  preserving uncommitted work. Launch arguments support quoted paths without shell evaluation.
- Initialization and dispatch commits preserve unrelated staged changes. The watcher only
  reports merges; agents finalize handoffs before marking cards merged.
- Protocol 2 adds content-based ingestion receipts and `tower-handoffs`, so unrelated commits
  cannot hide unprocessed handoffs and corrected handoffs become pending again. Existing
  projects need the protocol upgrade described in `PROTOCOL.md`; no automatic migration runs.
- The quickstart now initializes sidecar state for worktree dispatch. Regression tests cover
  isolation, concurrent claims, interrupted launches, commit safety, merge handling and recovery.

- Pull requests now run CI: `tests/run.sh` and a new `scripts/tower-changelog-check`, which
  fails a PR that touches `bin/`, `lib/`, `hooks/`, `scripts/`, `skills/`, `templates/`,
  `commands/`, `.claude-plugin/` or `PROTOCOL_VERSION` without also touching `CHANGELOG.md`.
  The omission this catches used to surface only at release time, where fixing it cost an
  extra commit; now it surfaces on the PR that caused it.

## v0.2.1 — 2026-08-27

- Releasing works on a repository whose `main` requires a pull request. `tower-release <x.y.z>`
  now prepares the bump on a `release-v<x.y.z>` branch without tagging, and
  `tower-release --tag <x.y.z>` tags `main` after the merge. Because the tag lands on whatever
  `main` became, the merge method no longer matters — squash, rebase and merge commit all
  produce a truthful tag.
- `tower-bootstrap` no longer records a plugin-cache path in `tower-root`, so a bootstrap can
  never pin the version that happened to be installed at the time. A stale file from an earlier
  clone-route bootstrap is removed, and the run says so.
- The README names the bootstrap command correctly as `/tower:tower-bootstrap`, with a shell
  fallback that cannot silently run the wrong cached version.

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
