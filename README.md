# tower

**File-based orchestration for multi-agent development.** One orchestrator plans and
curates. Parallel implementor sessions each execute one task (1 task ≈ 1 PR). The human
owner approves plans, reviews design diffs, and merges. All durable state is markdown in a
git-versioned `.tower/` directory — no daemon, no queue, no database. Git is the transport
and the audit trail.

![license](https://img.shields.io/badge/license-MIT-blue)
![protocol](https://img.shields.io/badge/protocol-v1-informational)
![platform](https://img.shields.io/badge/platform-macOS-lightgrey)

The name is from air traffic control: *handoff* is the ATC term for passing an aircraft
between controllers, and the tower — the human — always has final authority.

- [The loop](#the-loop) · [What state looks like](#what-state-looks-like) ·
  [Is this for you](#is-this-for-you)
- [Install](#install) · [Quickstart](#quickstart) · [Staying current](#staying-current)
- [Core ideas](#core-ideas): [task cards](#task-cards-are-decision-complete) ·
  [scoped learnings](#learnings-are-path-scoped) · [HITL gates](#three-gates-and-only-three)
- [Command reference](#command-reference) · [Configuration](#configuration) ·
  [Non-goals](#what-it-deliberately-does-not-do) · [Development](#development)

## The loop

```
        ┌──────────────────────────────────────────────┐
  OWNER │  approve drafts · review design diff · merge │
        └────▲───────────────▲───────────────────▲─────┘
             │ gate 1        │ gate 2            │ gate 3
        ┌────┴───────────────┴───────────────────┴─────┐
 ORCH   │  design.md  ->  task cards  ->  prompts      │
        │       ▲                            │         │
        └───────┼────────────────────────────┼─────────┘
        handoff │                            │ dispatch
        ┌───────┴────────────────────────────▼─────────┐
 IMPL   │  worktree -> code -> PR -> wait -> handoff   │
        └──────────────────────────────────────────────┘
```

Nothing in that diagram is a live connection. Every arrow is a file written to `.tower/`
and committed. The orchestrator reads handoffs; implementors read prompts; you read
diffs. Kill any session at any point and the next one picks up from the files.

An implementor does not end when it opens its PR — it backgrounds `tower-pr-wait` and
holds. The merge itself wakes it, so it folds review feedback into its handoff and flips
its own card to `merged`. You never tell an implementor that its PR landed.

## What state looks like

```
.tower/
  design.md            living design doc, edited only by the orchestrator
  learnings.md         curated lessons, path-scoped, selected per card at dispatch
  learnings-archive.md retired lessons, out of every prompt, kept for provenance
  card-sizing.md       card-size limits for this project, confirmed once by the owner
  tasks/               one card per task: T###-slug.md
  handoffs/            one handoff per finished task: T###-handoff.md
  prompts/             finalized dispatch prompts: T###-prompt.md
  templates/           card and handoff templates (copied here by tower-init)
```

The orchestrator commits state changes on main with a `tower:` prefix, so
`git log --oneline -- .tower/` is the audit trail and `git diff` on `.tower/design.md` is
how you review a design change — at your own pace, with no session to watch live.

### Why files

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

The full contract is in [PROTOCOL.md](PROTOCOL.md). The design follows published evidence:
decision-complete task specs are what make parallel implementors safe (Cognition's
"actions carry implicit decisions"), plans-as-cards survive execution while plans-as-prose
rot, and durable state in files with disposable sessions is the consensus across Anthropic,
Cognition, and practitioner writeups.

## Is this for you

Use tower when a project is large enough that you want several agents working at once, you
still want to approve the plan and read every PR, and you want to close your laptop without
losing the plan. It suits a solo owner or a small team driving a big refactor, a migration,
or a greenfield service.

Skip tower for single-session work, for anything you would rather just do yourself, and for
teams that already have a ticket system driving agents — the protocol assumes markdown in
git is the ledger.

## Install

Recommended, as a Claude Code plugin:

```
/plugin marketplace add omri-am/tower
/plugin install tower@tower
/tower-bootstrap
```

The first two lines install the skills, the version-notice hook and the templates, and
Claude Code keeps them updated. `/tower-bootstrap` links the `tower-*` shell commands into
`~/.local/bin` through a resolver shim that finds the live install at call time — so
`/plugin update tower@tower` needs no relinking afterwards. Add `~/.local/bin` to your PATH
if the bootstrap says so. Plugin-installed skills are namespaced
(`tower:tower-orchestrator`, `tower:tower-implementor`, `tower:tower-flush`); the
`install.sh` route below keeps the bare names.

> **Leave auto-update off for this marketplace.** Skills changing mid-session is harmless
> for a skills library; it is not harmless here, where a live orchestrator rehydrates from
> `.tower/` files whose templates could change underneath it. Take updates when the notice
> tells you one exists.

From a clone, which is the route for non-Claude agents:

```
git clone git@github.com:omri-am/tower.git && cd tower && ./install.sh
```

Links the three skills into `~/.claude/skills/` and prints the PATH line for `bin/`. Update
with `git pull`.

### Requirements

macOS (osascript for notifications and terminal launch; BSD `sed -i ''`), git, jq, and
Claude Code for the orchestrator and the Stop hook. The codex CLI is optional, for
implementors.

## Quickstart

```
cd ~/code/my-project
tower-init                        # scaffolds .tower/ and commits it
tower-orchestrate                 # opens the orchestrator session
```

Then:

1. **Design.** The orchestrator session assumes its role, registers its own session name in
   `.tower/orchestrator` so implementors can escalate to it, and starts its standing loop.
   Design together; it writes draft cards into `.tower/tasks/`.
2. **Approve drafts.** Read them with `tower-card` for the board and `tower-card T001` for
   one card in full, then edit `status: draft` -> `ready` yourself, or tell the orchestrator
   to. This is gate 1.
3. **Dispatch.** The orchestrator finalizes `prompts/T###-prompt.md`, then you (or it) run
   `tower-dispatch T001`. A new terminal opens with an implementor session, `TOWER_TASK`
   set, and the card flipped to `in-flight`.
4. **Implementor works** under the `tower-implementor` contract, opens the PR, writes a
   draft handoff (the Stop hook in [hooks/](hooks/README.md) enforces that it exists), then
   holds on `tower-pr-wait` instead of ending.
5. **Review and merge.** The holding implementor wakes on the merge, finalizes its handoff
   with whatever review changed, and flips its card to `merged`. The orchestrator ingests
   that handoff: design, tasks and learnings updated, next prompts finalized.

You are notified only at the three gates — draft approval, design change, PR ready.

To retire the orchestrator, or any tower session, invoke `tower-flush` in it first: it
writes everything it knows into `.tower/` so the next session loses nothing.

### Repos that must stay clean

For company projects that cannot carry tower files, use `tower-init --sidecar`: `.tower/`
becomes its own nested git repo, hidden from the parent via the local-only
`.git/info/exclude` — so not even the exclusion is committed. Same protocol, second repo.
Sidecar mode is **required** for per-task worktrees, because a committed `.tower/` would
materialize as a stale per-branch copy in every worktree.

### Where the project lives

`tower-init` anchors the project where you run it, not at the repo root — in a monorepo, run
it from the project's subdirectory. All tools and both roles find their project through
`tower-locate`: nearest `.tower/` above you, else the same path inside the main checkout
(resolved from `git worktree list`, never from folder names), else a bounded search of it.
So one repo can hold several independent tower projects, and a session started in any
worktree still finds the shared state. When even that fails, a session asks you where the
project is rather than guessing or scaffolding a new `.tower/`. Full chain and exit codes
are in [PROTOCOL.md](PROTOCOL.md#project-discovery).

## Core ideas

### Task cards are decision-complete

A card is not a ticket. It is the complete specification an implementor needs so that it
never has to invent a decision — because an invented decision is what makes parallel agents
diverge.

```markdown
---
id: T004
title: Version-check notice on the bootstrap shim
status: ready
depends_on: [T002]
vendor: any
branch: feat/version-check
pr: ""
---

## Goal
## Interfaces & decisions
## File ownership
## Out of scope
## Acceptance criteria
## Verification
```

`## File ownership` is load-bearing twice over: it keeps two in-flight implementors off the
same files, and it is what selects the learnings the card is given.

### Learnings are path-scoped

`learnings.md` has an `## Always` section plus `## scope: <glob>` sections. A card receives
`## Always` plus every scope whose glob intersects its `## File ownership` — not the whole
file. That is what lets the corpus grow while each prompt stays small.

```
tower-learnings --for T004      # exactly what this card's prompt gets
tower-learnings --check         # entry count vs budget, flags missing (T###) provenance
tower-learnings --scopes        # sections with entry counts, for the prune pass
```

Retired entries move to `learnings-archive.md`: out of every prompt, still in the repo.

### Three gates, and only three

The owner decides at draft approval, at a design change, and at PR review. Everything else
runs without you. Notifications fire at those three points and nowhere else — that is the
whole attention budget the protocol asks for.

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

### `tower-dispatch` flags

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

### `tower-card`

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
it. [CHANGELOG.md](CHANGELOG.md) says what each version added.

## What it deliberately does not do

No automatic merges, no auto-approval, no daemon, no cross-machine anything. Reviewer
dispatch stays in your existing review flow. beads integration as the task ledger is a
possible phase 2, once the protocol proves itself.

## Development

```
tests/run.sh          # all shell tests
```

Layout: `bin/` the `tower-*` commands, `lib/` shared shell (`tower-semver.sh`,
`tower-meta.sh`), `skills/` the three role skills, `hooks/` the Stop hook and version
notice, `templates/` card, handoff and learnings templates, `scripts/tower-release` the
release cut. [PROTOCOL.md](PROTOCOL.md) is the contract; change it and bump
`PROTOCOL_VERSION`.

## License

[MIT](LICENSE).
