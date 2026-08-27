# Reference

Command-level detail that does not belong in the README. The protocol contract itself is
in [PROTOCOL.md](../PROTOCOL.md).

## Command reference

| Command | Run by | What it does |
| --- | --- | --- |
| `tower-init [--sidecar] [dir]` | you, once | Scaffolds `.tower/` and commits it |
| `tower-orchestrate` | you | Opens the named orchestrator session and assumes the role |
| `tower-dispatch <id>` | orchestrator | Creates the worktree, marks the card in-flight, launches the implementor |
| `tower-card [id...] [--plain]` | you, orchestrator | Renders a card in full, or the board with no arguments |
| `tower-learnings --for\|--check\|--scopes` | orchestrator | Selects, audits, or lists scoped learnings |
| `tower-pr-wait [id]` | implementor | Blocks until the PR leaves OPEN; prints `MERGED <pr>` or `CLOSED <pr>` |
| `tower-watch` | you, optionally | Fallback poller that flips merged cards whose session is gone |
| `tower-locate [--from\|--task]` | tooling | Resolves the project directory |
| `tower-session-name --orch\|--task <id>` | tooling | Prints the session name a role answers to |
| `tower-whoami` | tooling | Prints this session's own addressable name |
| `tower-version-check [--notice]` | you | Checks for a newer tagged version now |
| `tower-notify <title> <message>` | tooling | macOS notification |

## `tower-dispatch` flags

| Flag | Effect |
| --- | --- |
| `--vendor claude\|codex` | Overrides the card's vendor |
| `--headless` | Runs `claude -p` / `codex exec` instead of opening a Terminal window |
| `--here` | Launches the implementor in the current terminal (tmux, Superset panes) |
| `--print-only` | Prints the launch command and changes nothing |
| `--in-place` | Skips worktree creation |
| `--worktree <path>` | Adopts an existing worktree instead of creating one |
| `--prep` | Does all the bookkeeping, launches nothing |

By default dispatch creates a per-task worktree at `<repo>-tower-worktrees/T###` on the
card's branch and symlinks the shared `.tower/` into it, so orchestrator and implementors
read and write the same state.

`--prep` is the hook for worktree-management platforms that start the agent themselves: it
validates, adopts and symlinks, marks the card in-flight, and writes a `.tower-task` marker
that arms the Stop hook without needing env vars — then you tell the agent to read its
prompt file. Running dispatch from inside a `.tower`-less worktree adopts that worktree
automatically, because `tower-locate --task T###` already resolved the project from outside
it. So `tower-dispatch T### --prep` works from anywhere in the repo or any worktree of it,
and the worktree's existing branch is recorded on the card.

`tower-watch [--interval s] [--on-merge '<cmd>']` polls in-review cards' PRs via `gh`; on a
merge it flips the card to `merged`, commits, notifies, and runs the optional command with
`TOWER_TASK` and `TOWER_PR` set — e.g. to prompt a non-Claude orchestrator via
`codex exec resume`. A Claude orchestrator on `/loop` does not need it.

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
