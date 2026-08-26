# tower

File-based orchestration for multi-agent development. One orchestrator role plans and
curates; parallel implementor sessions execute one task each (1 task ≈ 1 PR); the human
owner approves plans, reviews design diffs, and merges PRs. All durable state is markdown
in a git-versioned `.tower/` directory — no daemon, no queue, no database. Git is the
transport and the audit trail.

The name is from air traffic control: handoff is the ATC term for passing an aircraft
between controllers, and the tower — the human — always has final authority.

## Why files

- **Sessions rot; files don't.** Any session becomes the orchestrator by reading five
  files in order. Kill it anytime; nothing is lost.
- **Ownership through diffs.** The owner reviews `git diff` on `.tower/design.md` and task
  cards, at their own pace — no livestream-watching, no lost awareness.
- **Vendor-neutral.** Implementors are launched from prompt files, so any CLI agent
  (Claude Code, codex, ...) can take a task. The expensive model plans and curates; cheaper
  models implement decision-complete cards.
- **Learnings compound without rotting.** Every handoff proposes entries; the orchestrator
  curates; each implementor is given only the entries its card's paths select. The file can
  grow without every prompt paying for all of it, and entries leave by retirement or by
  promotion into the skill — so run N+1 is cheaper than run N without becoming louder.

The full contract is in [PROTOCOL.md](PROTOCOL.md). The design follows published evidence:
decision-complete task specs are what make parallel implementors safe (Cognition's
"actions carry implicit decisions"), plans-as-cards survive execution while plans-as-prose
rot, and durable state in files with disposable sessions is the consensus across Anthropic,
Cognition, and practitioner writeups.

## Install

```
git clone git@github.com:omri-am/tower.git && cd tower && ./install.sh
```

Links the two skills into `~/.claude/skills/` and prints the PATH line for `bin/`.

## Quickstart

```
cd ~/code/my-project
tower-init                        # scaffolds .tower/ and commits it
```

For a repo that must stay clean of tower files (company projects), use
`tower-init --sidecar`: `.tower/` becomes its own nested git repo, hidden from the parent
via the local-only `.git/info/exclude`. Same protocol, second repo — see PROTOCOL.md.

`tower-init` anchors the project where you run it, not at the repo root — in a monorepo,
run it from the project's subdirectory. All tools and both roles find their project through
`tower-locate` — nearest `.tower/` above you, else the same path inside the main checkout
(resolved from `git worktree list`, never from folder names), else a bounded search of it —
so one repo can hold several independent tower projects and a session started in any
worktree still finds the shared state. When even that fails, an orchestrator or implementor
session asks you where the project is rather than guessing or scaffolding a new `.tower/`.
See [PROTOCOL.md](PROTOCOL.md) for the full chain and its exit codes.

1. Start the orchestrator: `tower-orchestrate` (from anywhere in the project) opens a
   Claude session named `tower-<project>-<digest>-orch`, which assumes the role, registers that
   name in `.tower/orchestrator` for implementor escalations, and starts its standing loop — or do the same manually by
   invoking `tower-orchestrator` in a session. Design together; it writes draft cards into
   `.tower/tasks/`. To retire an orchestrator (or any tower session), invoke `tower-flush`
   in it first — it writes everything it knows into `.tower/` so the next session loses
   nothing.
2. Approve drafts (edit `status: draft` -> `ready`, or tell the orchestrator to).
3. The orchestrator finalizes `prompts/T###-prompt.md`, then: `tower-dispatch T001`.
   A new terminal opens with the implementor session named
   `tower-<project>-<digest>-<task-id>`, `TOWER_TASK` set, card `in-flight`.
4. Implementor works under the `tower-implementor` contract, opens the PR, writes a draft
   handoff (the Stop hook in [hooks/](hooks/README.md) enforces it), then holds on
   `tower-pr-wait` rather than ending.
5. You review and merge the PR. The holding implementor wakes on the merge itself, finalizes
   its handoff with whatever review changed, and flips its card to `merged` — you never tell
   it the PR landed. The orchestrator ingests that handoff: design/tasks/learnings updated,
   next prompts finalized, and you get a notification only at the three HITL gates — draft
   approval, design change, PR ready.

`tower-dispatch` flags: `--vendor claude|codex` overrides the card, `--headless` runs
`claude -p` / `codex exec` instead of opening a Terminal window, `--here` launches the
implementor interactively in the current terminal (for tmux/Superset panes), `--print-only`
prints the launch command without changing anything, `--in-place` skips worktree creation,
`--worktree <path>` adopts an existing worktree instead of creating one, `--prep` does all
the bookkeeping (validate, adopt + symlink, mark in-flight, write a `.tower-task` marker
that arms the Stop hook without env vars) but launches nothing — for worktree-management
platforms that start the agent themselves; then tell the agent to read its prompt file. By default
dispatch creates a per-task git worktree at `<repo>-tower-worktrees/T###` on the card's
branch and symlinks the shared `.tower/` into it (sidecar mode required for this). Running
dispatch from inside a worktree that has no `.tower` adopts that worktree automatically,
because `tower-locate --task T###` resolved the project from outside it — so
`tower-dispatch T### --prep` works
from anywhere inside the repo or any worktree of it when your own tooling creates the
worktrees; the worktree's existing branch is recorded on the card.

`tower-learnings --for T###` prints the learnings a card selects — `## Always` plus every
`## scope: <glob>` section whose paths intersect the card's `## File ownership` — which is
what the orchestrator pastes into a dispatch prompt instead of the whole file.
`--check` reports the entry count against the budget (60, `TOWER_LEARNINGS_BUDGET`) and
flags entries missing their `(T###)` provenance; `--scopes` lists sections with entry
counts, for the prune pass. Retired entries move to `.tower/learnings-archive.md`, out of
every prompt but still in the repo.

`tower-session-name --orch | --task <id> [--from <dir>]` prints the session name a tower role
answers to — `tower-<project>-<digest>-orch` or `tower-<project>-<digest>-<task-id>`, where the
digest is a short hash of the project's path. Both launchers name their sessions from it, and
anything that needs to address a tower session derives it here rather than by hand, so the two
sides cannot disagree. The digest is what keeps the name unique when two projects share a
directory basename.

`tower-whoami` prints this session's own name — the address other sessions message it by,
read from the Claude Code session registry keyed on `$CLAUDE_PID`. The orchestrator writes it
into `.tower/orchestrator` during rehydration; exit 2 means the session is not addressable at
all, in which case escalations arrive as `blocked` cards instead of messages.

`tower-pr-wait [<task-id>] [--interval seconds]` blocks until that card's PR leaves OPEN,
prints `MERGED <pr>` or `CLOSED <pr>`, and exits. It changes no state: it is the sensor an
implementor backgrounds so that the process exit wakes its own session at the merge, which
is why nobody has to tell an implementor its PR landed. Defaults to `$TOWER_TASK`.

`tower-watch [--interval seconds] [--on-merge '<command>']` polls the in-review cards'
PRs via gh; when one merges it flips the card to `merged` (committed), notifies, and runs
the optional `--on-merge` command with `TOWER_TASK` and `TOWER_PR` set (e.g. to prompt a
non-Claude orchestrator via `codex exec resume`). It also notifies when a card turns
blocked. A Claude orchestrator on `/loop` does not need it. Because a live implementor flips
its own card, `tower-watch` is the fallback for cards whose session is gone — headless
dispatches, and windows closed before the merge.

## What it deliberately does not do

No automatic merges, no auto-approval, no daemon, no cross-machine anything. Reviewer
dispatch stays in your existing review flow. beads integration as the task ledger is a
possible phase 2 once the protocol proves itself.

## Requirements

macOS (osascript for notifications and terminal launch; `sed -i ''`), git, jq, Claude Code
for the orchestrator and the Stop hook; codex CLI optional for implementors.
