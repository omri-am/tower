# Changelog

Consumers see only a version number in the update notice, so every entry here has to say
what the version gives them.

## Unreleased

## v0.9.0 — 2026-11-15

- `tower-pr-wait --interval` accepts only a whole number of seconds from 1 up, the same values as
  `--max-wait`. A fraction such as `1.5` is now rejected. Before, a fraction worked, but with
  `--max-wait` the watch did not shorten its last sleep, so it could stop up to one interval
  after the limit. Any invalid or missing value prints the usage line and exits 1 before the
  first `gh` call.

- `tower-locate` warns on stderr when its start directory or one of its ancestors, after
  symlinks are resolved, has a `.git` entry but `git rev-parse --show-toplevel` fails there, for
  example in a Codex sandbox that cannot read `git` or a git config file. The warning names the
  directory and the first line of git's error, and says that the worktree mapping was skipped.
  `--quiet` silences it. The resolution, stdout and exit statuses do not change.

- Native wake for a Codex role now retries `codex queue` once with `--remote unix://` when the
  first call exits 1 because a local app-server daemon is running and the caller passes a
  configuration override, as the Superset wrapper does. A successful retry delivers the message
  with no duplicate mark. A failed retry counts as one failed attempt and writes one
  `delivery.log` line with both errors. Every other result of the first call takes the same path
  as before.

- `tower-new` rejects a title argument that starts with `-`, such as `--help`, `-h` or `-x`. It
  prints its usage line to stderr and exits 1 before it looks for the project, so it writes no
  card and claims no id. Before, `tower new --help` created a card titled `--help` and used up
  the next id. A real title that starts with `-` is not supported; reword it.

- `tower territories` no longer counts a card glob as within a territory path when the territory
  path's literal prefix is the glob's literal prefix followed by `/`, such as `web*` for `web/`
  or `web/**`. Such a glob also matches paths outside the territory path, such as `web-api/`.
  Before, the glob counted as within. A card that owns such a glob now goes to `main`, unless
  another territory path contains the glob. A glob whose literal prefix starts with the territory
  path's literal prefix, such as `docs/**/*.md` or `docs/a*` for `docs/`, and a plain path such
  as `docs` keep their results.

- The orchestrator skill adds a fix check. Before a PR merges, a fresh reviewer reads every
  commit after the implementor's last review round, and the orchestrator records the result in
  `.tower/reviews/<task-id>/fix-<N>.md`. A PR is ready to merge only when its head is a
  reviewed commit. With no fix check, that is the commit that the implementor's last review
  round read. Otherwise, it is the commit that the newest fix check read, and that check's
  verdict must be `clean`. The orchestrator runs `tower-notify` and stops fix checks when the
  third fix check for a PR returns `changes`, or when a fix check returns `changes` on a finding
  that the implementor already rejected. `PROTOCOL.md` gives the record format, the range and
  the cap of three fix checks for each PR.
- The implementor skill tells the implementor to record in the handoff the commit that each
  review round read, as `- Round <N> reviewed <40-hex commit>`. It also tells the implementor
  to answer each fix-check record with a `- fix-<N> answer:` line in the handoff. For each
  critical or important finding, the line gives the commit that fixed it or the reason for the
  rejection.

- The boxed view of `tower-card` joins hard-wrapped lines before it wraps them, so a paragraph
  or list item fills its rows. Outside code fences, a line joins the line before it when neither
  line is empty or holds only spaces, and the line does not start a block. A line starts a
  block when, after its leading spaces, it starts with `- `, `* `, `#` followed by `#` or a
  space, `>`, `|`, three backticks, or one or more digits followed by `. `. The joined line
  loses its leading spaces, the text before it loses its trailing spaces, and one space
  separates them. The joined text keeps the prefix that its first line selects. Before, each
  source line started a new row.
- When the first line of a plain-text block starts with spaces, the block's wrapped rows keep
  those spaces after the row prefix, so a nested item stays indented. This also applies to a
  block of one line. Before, every wrapped row started at the row prefix. The kept indent
  narrows the text column, so a word longer than that column now breaks inside the word, and
  the block's first row is never empty. Before, an indented line rendered an empty first row
  when its first word did not fit after the indent, and a word broke only when it was longer
  than the row. An indent that leaves fewer than 8 columns of text in a row is not kept. That
  block renders with the prefixes it had before, so its first row can still be empty.
- A line that starts with three backticks after one or more spaces opens an indented code
  fence, and the next such line in the same section closes it. The two fence lines and each
  line between them render one source line each, as before, and the line after the closing
  fence starts a new block. Column-0 code fences, `--plain` output, the acceptance-criteria
  count and the board do not change.

- In the orchestrator skill's fix check and in the Range paragraph of `PROTOCOL.md`, a fix check
  reads the PR's full diff from its merge base in three cases: there is no last reviewed commit
  (no record and no round line), the range holds a merge commit, or the last reviewed commit is
  not an ancestor of the head (`git merge-base --is-ancestor <last> <head>` exits nonzero), as
  after a rebase. Before, the first case was "the handoff names no reviewed commit", and the
  third case did not exist. Two kinds of PR get a different range. A PR with a fix-check record
  but no round line, whose head changed after its newest record, now gets the range from that
  record's `reviewed_commit` to the head when no full-diff case applies. Before, each of its fix
  checks read the full diff. A PR whose handoff has a round line, whose last reviewed commit is
  not an ancestor of the head, and whose range holds no merge commit, now gets the full diff.
  Before, its range started at the last reviewed commit, so after a rebase it also held changes
  that `main` gained.
- When the handoff has the answer line for a `changes` record and the head did not change, the
  next fix check reads that record's range, from its `from_commit` to its `reviewed_commit`.
  Before, this held only when the answer rejected every finding. An answer that says at least
  one finding is `fixed in` a commit, with an unchanged head, now gets that record's range.
  Before, it got an empty range, or the PR's full diff when the handoff had no round line.
- The orchestrator runs no fix check for a card whose handoff draft does not exist yet. The
  first tick after the draft appears applies point 1 of the fix check as written. Before, a tick
  between `in-review` and the draft ran a fix check over the PR's full diff without the round
  lines, and that check counted toward the cap of three.
- The context pack of a PR's first fix check also holds every finding that the implementor
  rejected in its own review rounds, with the reason, from the handoff. The reviewer judges each
  of those reasons as an argument. The orchestrator still runs `tower-notify` and stops fix
  checks when a fix check returns `changes` on a finding that the implementor already rejected.
- The fix-check reviewer reads only the context pack and the repository's files. It does not
  read the handoff or any `.tower/` file other than the card. Before, no rule stopped it.
- When the orchestrator writes a `changes` record and the route in "Correct in-flight work"
  reaches no live session (a Codex or `--headless` implementor, or a session that has ended),
  it also runs `tower-notify` at once. The owner decides the next step. The orchestrator still
  runs no fix check until the head changes or the handoff has the answer line for that record.
  Before, the owner got no notice of that wait.

- `tower-dispatch` in the default mode, with no `--headless`, `--here`, `--prep` or
  `--print-only`, now checks for `osascript` after the duplicate-id check and before it takes
  the dispatch lock. When `osascript` is not on `PATH`, as on Linux, it prints that the default
  mode needs `osascript`, names `--headless`, `--here` and `--prep`, and exits 1. It changes no
  lock, worktree, branch, card or commit. This refusal now replaces the result of every later
  check and step, such as a held lock, the card status, an unknown `--vendor`, a missing prompt,
  a bad `--worktree` or a dirty `--in-place` checkout. Before, a dispatch that passed every check
  ran the rest of the dispatch, such as the new worktree or the `--in-place` checkout and, for a
  new dispatch, the card commit, and then failed at `osascript` with exit 127. A new dispatch
  then left its card `in-flight` with no session.
- When `osascript` exits nonzero in the default mode, for example when macOS denies Terminal
  automation, `tower-dispatch` now prints
  `could not open a Terminal window (osascript exit <N>)` and says to use `--resume` after
  confirming that no session started. It still exits with the `osascript` status. Before, it
  printed nothing of its own.

Boxed `tower-card` now uses `C.UTF-8` when the active character map is not UTF-8. If that locale is unavailable, it reports the requirement and exits instead of hanging on cards with non-ASCII text. An existing UTF-8 locale and `--plain` keep their behavior.

- `tower-notify` no longer needs `osascript`. It uses the first channel that applies. When
  `TOWER_NOTIFY_COMMAND` is set and not empty, it runs that command as one executable path, not
  through a shell, with two arguments: `tower: <title>` and `<message>`. It exits with the
  command's status and uses no other channel. Otherwise, when `osascript` is on `PATH`, it shows
  the macOS notification as before. Otherwise, when `notify-send` is on `PATH` and `DISPLAY` or
  `WAYLAND_DISPLAY` is not empty, it runs `notify-send` with the same two arguments and exits
  with its status. Otherwise it writes the line `tower: <title>: <message>` to stderr, with a
  terminal bell before the line end, and exits 0. Before, with two or more arguments, it always
  ran `osascript`, whatever the value of `TOWER_NOTIFY_COMMAND`. Where `osascript` was not on
  `PATH`, as on Linux, each such call exited 127 and showed no notice, and `tower-watch` ignored
  that failure. On a Mac with `TOWER_NOTIFY_COMMAND` set and not empty, the command now runs in
  place of the macOS notification. With fewer than two arguments, it prints the same usage line
  and exits 1, as before.

- `tower-ui` now fills hard-wrapped card text. Outside a code fence, a line that is not blank and
  does not start a block continues the paragraph or list item on the line directly before it.
  It loses its leading spaces and joins with one space. A block start is a code fence, a
  heading (one to six `#` at the start of the line, then whitespace and at least one more
  character), a `-`, `*` or `+` list item, a numbered item (digits followed by `. `), or a `>`
  or `|` line. Each of these except a heading may have leading spaces. Before, each source line
  of a paragraph ended a row on screen. Such a line after a `-`, `*` or `+` list item ended the
  list and started a new paragraph.
- Consecutive numbered items now render as one numbered list that starts at the first item's
  number. Before, numbered lines rendered as plain paragraph text.
- A `>` or `|` line is never joined to another line. Consecutive `>` or `|` lines render as
  before, as one paragraph with a line break between lines. A line directly before or after them
  that does not start a block is now in a separate block. Before, it was in their paragraph.
- Inline code still pairs backticks from left to right within one paragraph or list item. Where
  such a block now holds other source lines than before, some of its text can change between
  code and plain text. A code span across joined lines shows one space for each line break.
- Code fences, headings, the exact-source view and the comments section do not change.

Stop `tower-locate` from exiting with SIGPIPE when Git lists many worktrees.

- With a free dispatch lock and no `osascript` on the queue's `PATH`,
  `tower-ui` now blocks every ready card. It says that dispatch needs a
  macOS Terminal window. It names `tower-dispatch <id> --headless`, `--here`
  and `--prep` as shell options. This reason replaces any other dispatch
  blocker, including an unmet dependency, a missing prompt, an existing task
  branch, or tracked state that needs `--in-place`. Before, a ready card with
  no other blocker showed an enabled Dispatch card button. Its click failed
  without changing state. Before, a ready card with another blocker showed
  that blocker. When the dispatch lock is held, the lock reason still takes
  precedence. The queue refreshes the blocker if `osascript` disappears while
  the UI is open.

- Implementors now acknowledge every role message after they act on it. The skill also says
  that `tower send orchestrator` stores a message unread until the orchestrator checks its
  inbox. Before, the implementor skill did not ask for an acknowledgement or say that a send
  to the orchestrator was stored unread.
- Orchestrators now read and acknowledge their inbox during rehydration and each standing-loop
  tick. They leave cards `ready` for `tower-dispatch` and check its exit status. Before, the
  orchestrator skill did not read its inbox or say that dispatch needs a `ready` card.

`tower-register --detach` now starts a role holder that stays live after the command exits.
`tower-register --release <role>` stops a live holder and removes a stale registration.

## Codex implementor role lifecycle

- A Codex implementor registers its role with `CODEX_THREAD_ID` at start. Before, the
  implementor skill did not register a role, so `tower send` could not wake the session.
- An implementor that registered its role releases it before every stop, including a
  `--headless` stop after the draft handoff. Before, the implementor skill did not release a
  role.
- The orchestrator releases each implementor role during handoff ingest. Before, it removed
  the worktree without releasing the role.
- The role inbox instructions describe automatic Codex registration and count unacknowledged
  messages in `tower agents` only for registered roles. Before, they said every implementor
  role lacked an owner without manual registration and did not limit that count to registered
  roles.
- The correction instructions say a send wakes a registered Codex implementor. Before,
  they said a send had no live role unless registration was started by hand.

## v0.8.0 — 2026-10-26

- Every link to the same `.tower` now shares one mailbox, keyed by the real `.tower` directory
  after symlinks. Before, a worktree with two `.tower` links had two mailboxes, so messages sent
  from one directory never reached a reader in the other. Messages stored under an old key are
  not moved.
- The envelope's ack hint names the recipient role (`tower inbox --role <role> ack <id>`), so it
  works in a session without `TOWER_ROLE`. `tower inbox` without a role now reports
  `no role: pass --role <role> or set TOWER_ROLE`.

- `tower-dispatch` passes `--add-dir <git common dir>/tower` to Codex as the last argument before
  the prompt, and creates that directory before a launch. With a permission profile that allows
  tower's reads, a sandboxed Codex implementor can then run `tower-register` and `tower send`.
  Claude launch commands do not change. `--prep` passes nothing, so a platform that starts Codex
  after `--prep` must pass `--add-dir` itself.
- `tower-doctor --codex-sandbox <profile>` checks that a Codex permission profile allows the reads
  that tower needs. It runs three `codex sandbox` commands from a linked worktree and reports each
  failure as a finding. Findings are expected until the profile has the entries from the 7-step
  rule in `docs/agent-messaging/sandbox-access.md`. Doctor never edits the profile, and without
  the flag it runs no `codex` command and its output does not change.
- The orchestrator skill and `docs/REFERENCE.md` now say that dispatch sets
  `TOWER_ROLE=implementor-<task-id>` on a session it launches. `docs/REFERENCE.md` lists
  `TOWER_ROLE` under Configuration.

- `tower-pr-wait` takes `--max-wait <seconds>`. At the limit, it prints `OPEN <pr>` and exits 3.
  Without the option, the watch has no limit. In Claude Code, the implementor skill uses
  `--max-wait 6600` and starts a new watch on `OPEN <pr>`, so the merge watch no longer dies at
  the 2-hour background-command limit.
- Skill step 11 tells the implementor to add and commit the handoff in the repository that
  holds the canonical state, for both a sidecar and a committed `.tower/`.

- `tower territories` checks the optional territory charters in `.tower/territories/<name>.md`.
  It reports overlapping paths and invalid charters on stderr, and prints each card's territory
  or `main`. It writes no file. No command starts a sub-orchestrator yet. `PROTOCOL.md` and
  `docs/REFERENCE.md` document the charter format.

## v0.7.0 — 2026-10-20

- Added a durable mailbox shared across worktrees: `tower send` stores messages and
  `tower inbox` lists, reads, acknowledges, or waits for them without a vendor CLI.

- Added `tower register` (`tower-register`), which claims a role for the running session and
  prints its session id, refusing while another live session owns the role. Added
  `tower agents` (`tower-agents`), which lists each registered role with vendor, liveness, wake
  capability and unacknowledged message count. Both use a shared registry with exclusive role
  ownership and stale-owner detection.

- Codex roles registered with `tower-register --thread <session uuid or name>` report
  `wake: native`; `tower send` delivers through `codex queue` into submitted, not acknowledged;
  Codex is the only entry in the per-vendor adapter table.
  Only `tower inbox ack` acknowledges, and it now accepts submitted messages;
  `inbox list`/`--wait` include submitted, and `tower agents` counts claimed and submitted
  messages as unacknowledged. Messages are stored first: exit 0 means delivered; exit 1 means
  stored but not delivered (when attempted, requeued with redelivery incremented and the error
  appended to `mailbox/<role>/delivery.log`); exit 3 means stored with no live owner; exit 4
  means stored but the role cannot be woken automatically. Queue calls time out after 30
  seconds (logged as exit 124). Before storing, usage errors exit 2 and other errors exit 1.

- `tower send` native delivery enforces its 30-second deadline inside the delivery child and
  kills the adapter's whole process group at the deadline. Killing the sender no longer leaves
  an adapter running past the deadline, where it could submit a duplicate later. Timeout logging
  and exit codes are unchanged.

- A message left in `claimed/` by a `tower send` that died mid-delivery is requeued by the
  next `tower send` to that role. Recovery is immediate when its claimant is no longer the
  role's live session or the role has no live owner; otherwise it waits until the claim is
  10 minutes old. A `tower send` that is still delivering is never recovered, because
  recovery takes the same per-role delivery lock. An adapter command left running by a killed
  `tower send` can still finish after recovery, until its 30-second deadline, which is why the
  recovered copy says `possibly a duplicate`. Recovery counts as a failed attempt: `redelivery`
  increases and the same 3-attempt limit applies. It is logged in `mailbox/<role>/delivery.log`
  as `exit=75 abandoned claim recovered`. There is no daemon, so a role nobody sends to keeps
  its abandoned claims.

- A message whose delivery fails 3 times now moves to `undeliverable/` instead of being
  retried on every `tower send`. `tower agents` gains an `undeliverable:<n>` field per role.
  `tower inbox list` and `read` deliberately ignore undeliverable messages because they
  wait for a human, not the receiver.

- `tower agents` now shows a stale role's stored wake capability instead of `wake:none`, so
  a stale Codex role registered with `--thread` reads `stale` and `wake:native` and can be
  told apart from a role that can never be woken, which still shows `wake:none`.
  `tower send` is unchanged: a stale role has no live owner, so the message
  stays queued and the command still exits 3.

- `tower send` now labels a sender with no `TOWER_ROLE` as `unknown` instead of `owner`, and the
  envelope says the sender is unidentified. The owner sets `TOWER_ROLE=owner` to label their own
  messages; the label is self-asserted and grants nothing. `tower-dispatch` sets
  `TOWER_ROLE=implementor-<task-id>` on every session it launches (`--here`, `--headless`, or
  the printed or Terminal command). A session started by hand after `--prep` gets no
  `TOWER_ROLE`.

- `tower-dispatch --vendor codex` now passes `--model` as `--model <name>` and `--effort` as
  `-c model_reasoning_effort=<level>` instead of warning and dropping them. Claude launch commands
  are unchanged, and vendor launch arguments come from one table in `lib/tower-dispatch.sh`.

- The task-card template and `PROTOCOL.md` now list the optional `model:` and `effort:` fields
  that `tower-dispatch` records and reuses. `docs/REFERENCE.md` documents `--model`/`--effort`,
  and the orchestrator skill and `PROTOCOL.md` direct card creation through `tower new`.

- `tower-bootstrap` links every `tower` and `tower-*` entry in its `bin/` directory, except
  `tower-shim`, instead of a hand-written command list. Every command in this release,
  including `tower-send`, `tower-inbox`, `tower-register` and `tower-agents`, is on PATH after
  bootstrap, and a new command in `bin/` no longer needs an edit to `tower-bootstrap`.

- `tower-new` now replaces every literal `<task-id>` in the card template with the claimed
  id, including inside HTML comments. The card's changelog fragment path is filled in at
  creation, and the orchestrator skill no longer tells the author to replace it by hand.

- The shared role mailbox is now documented in `PROTOCOL.md`, both role skills, and
  `docs/REFERENCE.md`. The reference also lists the four messaging commands and corrects
  Codex model and effort launch flags. `PROTOCOL.md` now says the orchestrator may set a
  card's `model:` and `effort:`, which dispatch uses when the matching flag is absent.

- The implementor skill and docs now describe `unknown` for an unset `TOWER_ROLE` and
  `TOWER_ROLE=implementor-<task-id>` for dispatch-launched sessions. Step 11 of the
  implementor skill now tells a session with a sidecar `.tower/` to stage its new handoff and
  commit inside `.tower/`, because `git commit --only` fails on an untracked handoff.
  `docs/agent-messaging/adapter-shape.md` now says that the delivery wrapper kills the
  adapter's process group at the 30-second deadline, even after the sender is killed.

- The card template documents `changelog.d/<task-id>.md` in a comment under
  `## File ownership`. `PROTOCOL.md` and the orchestrator and implementor skills name a card's
  own fragment as the place for its changelog entry in a project that takes fragments. Editing
  `CHANGELOG.md` directly stays accepted for a release or a hand edit that belongs to no card.

- Changes can carry their changelog entry in a `changelog.d/<task-id>.md` file instead of
  editing `CHANGELOG.md`. `scripts/tower-changelog-check` accepts an added, modified, deleted or
  renamed `changelog.d/*.md` fragment like a `CHANGELOG.md` edit. It counts only `*.md` files
  in `changelog.d/`, so a `T999.txt` or a lone `.gitkeep` does not satisfy it, and a pure
  revert of an unreleased card passes. `scripts/tower-release` folds the fragments in filename
  order after existing Unreleased entries and deletes them in the release commit.

- Release now folds tracked `protocol.d/<task-id>.md` and `reference.d/<task-id>.md` fragments
  into `PROTOCOL.md` before `## Protocol version` and `docs/REFERENCE.md` before
  `## Core ideas`, and deletes them in the release commit. `docs/REFERENCE.md` explains both
  directories. Each fragment must start with a `## ` heading, and `scripts/tower-release`
  refuses a fragment that contains its own document's fold anchor line, naming the fragment
  instead of releasing a document with two anchors.

## v0.6.0 — 2026-09-28

- `tower-learnings --for` now includes entries before the first `##` heading in every
  selection, including flat files, preserving wrapped lines and excluding format notes.
  `--check` reports their count without changing its exit status.

- `tower-dispatch` now refuses to dispatch any card while multiple cards share a task id,
  listing the duplicate ids and their files so they can be resolved before dispatch.

- `tower-ui` identifies the project in the browser tab title and keeps its header label
  visible at narrow widths, truncating long labels with an ellipsis. Nested projects use
  the repository name and relative project path.

- `tower-doctor` now checks the project's own `.tower` path when diagnosing stale excludes,
  so a subdirectory project with a correct anchored entry is no longer reported stale.
  Recovery instructions name the matching project-relative pattern.

- Added `tower new "<title>"` to create a draft card from the project's template with an
  atomically claimed flat id, preventing concurrent callers from receiving the same id.
  The command prints the created path without committing the card.

## v0.5.0 — 2026-09-28

- `tower-dispatch` accepts `--model <name>` and `--effort <level>` and passes them to a
  claude implementor as `--model` and `--effort`, so a card can run on a chosen model
  without launching the vendor CLI by hand. The values are not checked against a list. The
  card records them as `model:` and `effort:`. A later dispatch, including `--resume`,
  reuses a recorded value unless the flag is passed again. The codex vendor accepts both
  flags, warns on stderr that it ignores them, and still dispatches. Without either flag
  or a recorded value, the launch command is unchanged.

- `tower-init --sidecar` now excludes `.tower` without a trailing slash, so the `.tower`
  symlink that `tower-dispatch` drops into each worktree is ignored too. Before, a dispatched
  implementor saw `?? .tower` and could commit a symlink to an absolute path on the
  orchestrator's machine. Projects initialized earlier keep their `.tower/` line and stay
  exposed until they change it to `.tower` in `.git/info/exclude`.

- `tower-doctor` now reports `exclude-pattern` for a sidecar project whose
  `.git/info/exclude` still ignores only `.tower/`, naming the exclude file and the one-line
  edit (replace `.tower/` with `.tower`). If `git check-ignore` itself fails, it reports
  that the check could not run instead of passing. It never edits the file. Projects that
  track `.tower` in git are not checked.

- `tower-learnings --check` no longer reports missing `(T###)` provenance for an entry
  that wraps onto a continuation line with its `(T###)` there, which is the format
  PROTOCOL.md documents. An entry with no `(T###)` anywhere is still reported, at the
  number of its first line.

- `tower-dispatch`, `tower-card`, `tower-learnings` and `tower-pr-wait` now refuse to guess
  when a task ID matches more than one card, naming every matching file instead of silently
  taking the first one `find` happens to return. `tower-doctor` also flags duplicate IDs
  across cards and a card whose filename disagrees with its `id:` field.

- PROTOCOL.md and the `tower-implementor`/`tower-orchestrator` skills specify that flat
  `T###` ids are allocated by the orchestrator, which is the only role that creates cards.
  Implementors describe follow-ups in their handoff for the orchestrator to consider.

- `tower-implementor` reads the session's user-level and repository-level agent instructions,
  under whatever names the running agent uses, before tower's own inputs. Those instructions
  govern process, the card governs task decisions, and learnings are advisory. Before opening
  the PR, the implementor runs whatever completion or review workflow the instructions define.

- `tower-dispatch` no longer refuses a card that owns a file above the project directory. A project
  living in a monorepo subdirectory can legitimately own the repo-root `AGENTS.md` or its `.agents/`
  docs, and those have no spelling without a leading `../`. Absolute paths, `//`, `/./`, a bare `..`
  and real traversal after a path segment are all still rejected.

- Dispatch no longer demands an ownership list from a card other than the one being dispatched. A
  blocked card whose File ownership still reads "to be filled in at promotion" claims nothing, so it
  no longer blocks every other card from dispatching.

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
