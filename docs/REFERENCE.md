# Reference

Command-level detail that does not belong in the README. The protocol contract itself is
in [PROTOCOL.md](../PROTOCOL.md).

## `tower <command>`

Every `tower-<command>` executable also supports `tower <command>` with the same
arguments and exit status: `tower ui`, `tower bootstrap`, `tower dispatch T001`,
and `tower version-check`. Run `tower --help` to list commands in the resolved install.
Existing hyphenated names remain supported. Bootstrap once after upgrading to link
`tower` into your PATH; subsequent new subcommands need no individual links.

## Command reference

| Command | Run by | What it does |
| --- | --- | --- |
| `tower-init [--sidecar] [dir]` | you, once | Scaffolds `.tower/` and commits it |
| `tower new "<title>"` | orchestrator | Atomically claims the next flat ID and creates a draft card without committing |
| `tower-orchestrate` | you | Opens the named orchestrator session and assumes the role |
| `tower-dispatch <id>` | orchestrator | Creates the worktree, marks the card in-flight, launches the implementor |
| `tower-card [id...] [--plain]` | you, orchestrator | Renders a card in full, or the board with no arguments |
| `tower-learnings --for\|--check\|--scopes` | orchestrator | Selects, audits, or lists scoped learnings |
| `tower-pr-wait [id] [--interval <seconds>] [--max-wait <seconds>]` | implementor | Blocks until the PR leaves OPEN; prints `MERGED <pr>` or `CLOSED <pr>`; at the `--max-wait` limit, prints `OPEN <pr>` and exits 3 |
| `tower-watch` | you, optionally | Reports PR merges without finalizing cards |
| `tower-handoffs` | orchestrator | Lists finalized handoffs whose content has not been ingested |
| `tower-territories` | orchestrator | Checks the territory charters and prints each card's territory |
| `tower-doctor [--from <dir>] [--codex-sandbox <profile>]` | you, orchestrator | Diagnoses local recovery issues and prints next steps without changing state |
| `tower-locate [--from\|--task]` | tooling | Resolves the project directory |
| `tower-session-name --orch\|--task <id>` | tooling | Prints the session name a role answers to |
| `tower-whoami` | tooling | Prints this session's own addressable name |
| `tower-version-check [--notice]` | you | Checks for a newer tagged version now |
| `tower-notify <title> <message>` | tooling | macOS notification |
| `tower-send <role> [--reply-to <id>] <text\|->` | you, any role | Stores a role message, then tries delivery |
| `tower-inbox [--role <role>] [list\|read <id>\|ack <id>] [--wait [SECONDS]]` | any role | Lists, reads, waits for, or acknowledges role messages |
| `tower-register <role> --vendor <v> [--vendor-version <ver>] [--thread <id>]` | you | Holds a role registration while running |
| `tower-agents` | any role | Lists registered roles and mailbox counts |

## `tower new`

`tower new "Fix the thing"` (also `tower-new`) copies the project's task-card template to
`tasks/T012-fix-the-thing.md` when the highest flat ID is T011. The title must be one
nonempty argument. With a title that starts with `-`, such as `--help`, the command prints
the usage line to stderr and exits 1. It writes no card and claims no ID.
Allocation considers card filenames, frontmatter IDs, and persistent
`.claims/` directories; letter-suffixed IDs are ignored. Atomic claims prevent concurrent
callers from receiving the same ID. The command prints the created path and does not commit.

## Messaging commands

`tower-send <role> [--reply-to <id>] <text|->` stores the text, or reads stdin for `-`.
`--reply-to` records a message ID in the new message. The message's `from` is `TOWER_ROLE`,
or `unknown` when it is unset or empty. The command prints the new ID before it tries
delivery. See [Durable role messages](../PROTOCOL.md#durable-role-messages) for its
exit status and the authority of cards and handoffs.

`tower-inbox [--role <role>] [list|read <id>|ack <id>] [--wait [SECONDS]]` uses `TOWER_ROLE`
when `--role` is absent. `list` is the default and includes queued and submitted message
IDs. `--wait` applies only to `list`; without seconds it waits without a time limit, and
with seconds it exits 1 when none arrives in time. Put an explicit `list` before `--wait`:
`--wait list` reads `list` as the seconds and exits 2. `read` prints a message; `ack`
acknowledges a queued or submitted message.

`tower-register <role> --vendor <v> [--vendor-version <ver>] [--thread <id>]` prints a
session token and holds the role's lock until the command stops, so leave it running. It exits
1 when another live session holds the role. A `--vendor codex` registration with `--thread` is
listed by `tower-agents` as `wake:native`; every other registration as `wake:none`.

`tower-agents` takes no flags. Its tab-separated columns are role, vendor with optional
version, `live` or `stale`, `wake:<cap>`, `unacknowledged:<n>`, and `undeliverable:<n>`.

## `tower-dispatch` flags

| Flag | Effect |
| --- | --- |
| `--vendor claude\|codex` | Overrides the card's vendor |
| `--model <name>` | Overrides the card's `model:`; without the flag, uses the card value. Passes `--model <name>` to Claude or Codex and records the selected value on first dispatch |
| `--effort <level>` | Overrides the card's `effort:`; without the flag, uses the card value. Passes `--effort <level>` to Claude or `-c model_reasoning_effort=<level>` to Codex and records the selected value on first dispatch |
| `--headless` | Runs `claude -p` / `codex exec` instead of opening a Terminal window |
| `--here` | Launches the implementor in the current terminal (tmux, Superset panes) |
| `--print-only` | Prints the launch command and changes nothing |
| `--in-place` | Skips worktree creation |
| `--worktree <path>` | Adopts an existing worktree instead of creating one |
| `--prep` | Does all the bookkeeping, launches nothing |
| `--resume` | Restarts an in-flight task in its recorded branch’s existing worktree |
| `--expect-revision <hash>` | Rejects a card or prompt changed since browser review; checked under the dispatch lock |

For model and effort, a non-empty flag overrides the recorded card value. `--resume` reuses
recorded values without rewriting the card; flags passed again override only that launch.

A Codex launch also gets `--add-dir <git common dir>/tower`, and dispatch creates that
directory before the launch, so the sandboxed session can write tower's shared state.
`--prep` launches nothing and passes no such flag, so a platform that starts Codex after
`--prep` must pass `--add-dir <git common dir>/tower` itself.

By default dispatch creates a per-task worktree at `<repo>-tower-worktrees/<project>/T###`
on the card’s branch and symlinks the shared `.tower/` into it. `<project>` is `root` for
a root project and `projects/<project-relative-path>` otherwise. Ownership validation
and claiming are serialized; overlapping in-flight, in-review or blocked cards prevent
dispatch. `--in-place` requires a clean checkout and creates or checks out the task branch.

Use `--resume` only after confirming the previous session stopped. It retains uncommitted
work and does not create a new branch. For an in-place task, also pass `--in-place`; the
checkout must still be on the recorded branch. Old worktree locations remain resumable
because discovery uses the card’s branch, not the new default path.

`--prep` is the hook for worktree-management platforms that start the agent themselves: it
validates, adopts and symlinks, marks the card in-flight, and writes a `.tower-task` marker
that arms the Stop hook without needing env vars — then you tell the agent to read its
prompt file. Running dispatch from inside a `.tower`-less worktree adopts that worktree
automatically, because `tower-locate --task T###` already resolved the project from outside
it. So `tower-dispatch T### --prep` works from anywhere in the repo or any worktree of it,
and the worktree's existing branch is recorded on the card.

`tower-watch [--interval s] [--on-merge '<cmd>']` polls in-review cards' PRs via `gh`; on a
merge it notifies and runs the optional command with
`TOWER_TASK` and `TOWER_PR` set — e.g. to prompt a non-Claude orchestrator via
`codex exec resume`. A Claude orchestrator on `/loop` does not need it.

## `tower-doctor`

Inspects the project resolved by `tower-locate`, including canonical state reached through
a worktree symlink. It reports existing dispatch locks, blocked or invalid cards, missing
active-task branches and worktrees, missing or conflicting shared state links and task
markers, missing PR references and handoffs, and merged handoffs awaiting ingestion.
Merged tasks do not need a surviving worktree. Draft and ready cards do not need one either.

Each finding has a stable code in brackets, the affected task or project, and a next step.
Commands in the advice quote filesystem paths; ambiguous repairs require manual inspection
instead of recommending deletion of possibly valuable state. Exit `0` means no findings,
`1` means attention is needed, and project-discovery failures retain `tower-locate`'s exit
codes (`3` for no project, `4` for ambiguity).

Without `--codex-sandbox`, doctor reads only local files and Git metadata. With or without
the flag, it does not run agents, poll GitHub, repair files, commit, or clear locks. Its shim
invocation skips the background update check too.
The protocol has no session heartbeat or lock-owner record, so doctor cannot prove an
agent has stopped or a lock is stale. It reports a present lock with conditional recovery
advice and never infers failure from card age. A pending ingestion or blocked card can be
normal work awaiting action; findings are not all corruption.

`--codex-sandbox <profile>` checks that your Codex permission profile allows the reads that
tower needs. After the card checks, doctor runs `codex sandbox -P <profile> -C <dir>` for
three commands: `tower-register --help` from your `PATH`, `git rev-parse --show-toplevel`
through `/bin/bash`, and `tower_msg.runtime_root()` from doctor's own `lib/`. Each command
must exit 0. The `runtime_root` output must also equal its output without the sandbox. The
directory is the project directory in the first linked worktree where it exists, as in
dispatch. Doctor skips the main checkout and the checkout that holds the canonical `.tower`.
In the main checkout, the project-root write entry also covers `<main>/.git` and can hide a
missing entry for the Git common dir.

A failed command reports `sandbox-register`, `sandbox-git` or `sandbox-state-root`, with its
exit status and the first line of its stderr. Without a linked worktree, doctor reports
`sandbox-no-worktree`. Without `codex` on `PATH`, it reports `sandbox-no-codex`. In both
cases it runs no `codex` command. When all three commands pass, doctor prints one line:
`codex sandbox (<profile>): tower-register, git and the state root are reachable`. You name
the profile. Doctor does not read `~/.codex/config.toml` and never edits the profile. The
7-step rule in [sandbox-access.md](agent-messaging/sandbox-access.md) derives the entries.

The check has three limits. It does not test writes to the state root, which dispatch grants
with `--add-dir`. It does not catch the plugin-cache case, where `tower --help` exits 0 but
resolves a different root. It does not cover a tool call through `/bin/zsh -lc`, where
`path_helper` can put `/usr/bin` first.

## `tower-handoffs`

Prints one task ID per finalized, unprocessed handoff. A handoff is pending when its card
is `merged` and `git hash-object` of its contents differs from `ingested_handoff` on the
card. Missing receipts on old cards mean unprocessed; missing handoff files produce an
error. The orchestrator commits the receipt together with the resulting state updates.
The watcher never writes receipts or finalizes cards.

## `tower-card`

`tower-card T###` renders the frontmatter, every section in card order, and a done/total
count on the acceptance criteria; with no arguments it prints the board and a status tally.
It exists because the owner approves content, not titles — the orchestrator runs this same
command so the card in the transcript is the card on disk.

Two behaviours look inconsistent until you see why. The box is drawn even when stdout is not
a tty, because the orchestrator calls this through a tool that is never a tty but whose
output a human reads; colour is the opposite, added only for a real terminal. Fenced code
under `## Verification` keeps its lines intact and runs past the right border rather than
being wrapped or clipped, so the commands stay copy-pasteable.

Body content outside any `## ` section — an orchestrator checkpoint note before the first
heading, or a card that never got its headings — is rendered as an unlabelled leading block
rather than dropped. Cards record `pr:` as a full GitHub URL in practice, so the PR column
shows the pull number it finds (`#15425`), and several become `#15942 +2` on the board with
every number in the card view. Ids match case-insensitively, so a card filed `T073a` answers
to `t073a`.

`--plain` drops the box, the glyphs and the colour, for piping and for orchestrators that
are not Claude Code: its output is pure ASCII, it never truncates a title or a dependency
list, and the card body it prints is byte-identical to the file.

## `tower-ui`

```
tower-ui                              # open this project's browser workspace
tower-ui --from ~/code/project         # explicit project, including monorepo subprojects
tower-ui --no-open --port 8765          # print the session URL on a fixed local port
```

Requires Python 3.9+ only for this optional command. No Python packages, JavaScript
packages, web fonts, or build step are required. The server binds to `127.0.0.1`; the
printed URL contains a session token. Keep the command running and use Ctrl-C to stop.
Discovery uses `tower-locate`, including canonical state linked from implementor worktrees.

The default view groups drafts under Needs approval, dispatchable ready cards under Ready
to dispatch, and blocked cards or incomplete prerequisites under Waiting. All cards also
shows active and merged work. Search matches ID, title, and complete card content. `/`
focuses search, `j` and `k` select adjacent visible cards, and buttons support standard
Tab/Enter navigation. Automatic refresh preserves the selected card and reading position
when its content is unchanged. Changed cards are shown with a review notice.
The page polls every five seconds while `tower-ui` is running. Each request rescans
`.tower/tasks/*.md`, so new cards and external edits appear without restarting the server.
Refresh requests an immediate update; actions refresh on completion.

Switch between Queue and Kanban in the header. Kanban starts with all cards in separate
Needs approval, Ready to dispatch, Waiting, In flight, In review, and Merged columns.
Click a column heading to fold or expand it; folded columns retain their title and count.
The browser tab remembers folded columns and the selected view across reloads.
Click a card to open its details and comments; Escape returns to the board.
Approval and dispatch remain explicit actions. Each view retains its own filter while switching.

Group headings and status badges use consistent colors: blue for Needs approval, green
for Ready to dispatch, amber for Waiting, purple for In flight, teal for In review, gray for Merged, and red for
Needs attention. Text labels remain present; a ready card with an unmet prerequisite is
labeled Waiting in the browser.

Use the Comments button on a selected card to jump to its thread, enter feedback, and
choose Post comment. Unsent text survives refreshes and switching cards within the page.
Comments persist as individually committed Markdown files in
`.tower/comments/<task-id>/<comment-id>.md`, with a UTC timestamp and the reviewed card
revision. They do not change card content or status and do not notify or launch an agent.
The orchestrator reads them during rehydration and its regular loop. A stopped orchestrator
must be resumed before it can act on feedback. Existing projects need no migration.

The detail pane renders card sections and offers the exact source. Approve card changes a
committed draft to ready and commits only that card. Dispatch card runs `tower-dispatch`
with the card's vendor, using the normal sidecar worktree and Terminal workflow. It does
not finalize prompts: ask the orchestrator to prepare missing prompts. Tracked-state
projects can read and approve in the browser; use explicit CLI `--in-place` for dispatch.
Resume and worktree adoption remain CLI operations.

Both actions reject a changed card or prompt. A revision is `git hash-object --stdin`
over the card bytes, one NUL byte, then the prompt bytes (empty when absent). Dispatch
checks that revision and eligibility under its existing lock; approval takes the same
lock. A present lock is reported without assuming it is stale. Failed launches may leave
an in-flight card: inspect it with `tower-doctor` and confirm the session has stopped
before using `tower-dispatch --resume`.

## `tower-learnings`

```
tower-learnings --for T004      # exactly what this card's prompt gets
tower-learnings --check         # entry count vs budget, flags missing (T###) provenance
tower-learnings --scopes        # sections with entry counts, for the prune pass
```

## Where the project lives

`tower-init` anchors the project where you run it, not at the repo root — in a monorepo, run
it from the project's subdirectory. All tools and both roles find their project through
`tower-locate`: nearest `.tower/` above you, else the same path inside the main checkout
(resolved from `git worktree list`, never from folder names), else a bounded search of it.
So one repo can hold several independent tower projects, and a session started in any
worktree still finds the shared state. When even that fails, a session asks you where the
project is rather than guessing or scaffolding a new `.tower/`. Full chain and exit codes
are in [PROTOCOL.md](../PROTOCOL.md#project-discovery).

## Configuration

| Variable | Default | Effect |
| --- | --- | --- |
| `TOWER_NO_VERSION_CHECK` | unset | `1` silences the update notice |
| `TOWER_VERSION_CHECK_TTL` | `86400` | Seconds between update checks |
| `TOWER_CARD_WIDTH` | terminal width, else `80` | Render width for `tower-card` (floor 46) |
| `TOWER_LEARNINGS_BUDGET` | `60` | Entry count `tower-learnings --check` measures against |
| `TOWER_TASK` | set by dispatch | The implementor's task id |
| `TOWER_ROLE` | set by dispatch | The sender label for `tower send` and the default role for `tower inbox`; dispatch sets `implementor-<task-id>` on a session it launches |
| `TOWER_PROJECT_DIR` | unset | First link in the project-discovery chain |

## Staying current

An install checks for a newer tagged version at most once a day, in the background, and
never blocks a command on the network. When one exists you get one line:

```
tower: 0.4.0 available (you have 0.3.1) -> /plugin update tower@tower
```

on stderr before any `tower-*` command run through the bootstrap shim, and as a note at the
start of a Claude session. Clone-route `bin/tower-*` calls, run without bootstrapping, skip
it. [CHANGELOG.md](../CHANGELOG.md) says what each version added.

A change under `bin/`, `lib/`, `web/`, `hooks/`, `scripts/`, `skills/`, `templates/`,
`commands/`, `.claude-plugin/` or `PROTOCOL_VERSION` needs a changelog entry; each card
adds finished `- ` bullets in its own `changelog.d/<task-id>.md` instead of editing
`CHANGELOG.md`. `scripts/tower-release` folds those fragments into the new version section
and deletes them.

A card that adds a top-level section to `PROTOCOL.md` or `docs/REFERENCE.md` writes it as
`protocol.d/<task-id>.md` or `reference.d/<task-id>.md` and does not edit the index. Each
fragment's first nonblank line starts with a `## ` heading. `scripts/tower-release` folds
the fragments in `git ls-files` order before `## Protocol version` in `PROTOCOL.md` and before
`## Core ideas` in `docs/REFERENCE.md`. The release commit deletes them. An edit to
existing text in either index is still a direct edit.

## `tower territories`

`tower territories` (also `tower-territories`) checks the charters in `.tower/territories/`
and prints the territory of each card. It takes no arguments and writes no file. The charter
format and the assignment rule are in
[Territories](../PROTOCOL.md#territories--territoriesnamemd).

stdout has one line per card in `.tower/tasks/`, sorted by id. Each line has three
tab-separated fields: the card id, the territory name or `main`, and the card status.

```
T001	docs	in-flight
T002	main	ready
```

stderr has one line per problem, as `tower-territories: <charter file>: <problem>`. An
overlap names both charters and both paths:

```
tower-territories: .tower/territories/api.md: path docs/api/** overlaps .tower/territories/docs.md path docs/
```

The exit status is 0 when there is no problem and 1 when there is at least one problem. The
card lines print in both cases. A charter with a problem still takes part in the assignment,
so two overlapping charters can make a card `main`. Without `.tower/territories/`, or with
no charter in it, every card is `main` and the exit status is 0.

A usage error prints only the usage line and exits 1. When `tower-locate` cannot resolve the
project, the command exits with the status of `tower-locate`.

## Core ideas

**Task cards are decision-complete.** A card is not a ticket; it carries every decision
(interfaces, file ownership, out-of-scope, acceptance criteria) so an implementor never
invents one — invented decisions are what make parallel agents diverge. `## File ownership`
also keeps concurrent implementors off the same files.

**Learnings are path-scoped.** `.tower/learnings.md` has an `## Always` section plus
`## scope: <glob>` sections; a card's prompt receives only the scopes intersecting its file
ownership. The corpus grows while each prompt stays small.

**Three gates, and only three.** You decide at draft approval, design change, and PR
review. Everything else runs without you; notifications fire at those points and nowhere
else.

## Why files

- **Sessions rot; files don't.** Any session becomes the orchestrator by reading five
  files in order. Kill it anytime; nothing is lost.
- **Ownership through diffs.** You review `git diff` on `.tower/design.md` and on task
  cards — no livestream-watching, no lost awareness.
- **Vendor-neutral.** Implementors are launched from prompt files, so any CLI agent
  (Claude Code, codex, ...) can take a task. The expensive model plans and curates;
  cheaper models implement decision-complete cards.
- **Learnings compound without rotting.** Every handoff proposes entries; the orchestrator
  curates; each implementor gets only the entries its card's paths select. The file can
  grow without every prompt paying for all of it, and entries leave by retirement or by
  promotion into the skill — so run N+1 is cheaper than run N without becoming louder.

The design follows published evidence: decision-complete task specs are what make parallel
implementors safe (Cognition's "actions carry implicit decisions"), plans-as-cards survive
execution while plans-as-prose rot, and durable state in files with disposable sessions is
the consensus across Anthropic, Cognition, and practitioner writeups.
