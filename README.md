# tower

File-based orchestration for multi-agent development. One orchestrator role plans and
curates; parallel implementor sessions execute one task each (1 task ≈ 1 PR); the human
owner approves plans, reviews design diffs, and merges PRs. All durable state is markdown
in a git-versioned `.tower/` directory — no daemon, no queue, no database. Git is the
transport and the audit trail.

The name is from air traffic control: handoff is the ATC term for passing an aircraft
between controllers, and the tower — the human — always has final authority.

## Why files

- **Sessions rot; files don't.** Any session becomes the orchestrator by reading four
  files in order. Kill it anytime; nothing is lost.
- **Ownership through diffs.** The owner reviews `git diff` on `.tower/design.md` and task
  cards, at their own pace — no livestream-watching, no lost awareness.
- **Vendor-neutral.** Implementors are launched from prompt files, so any CLI agent
  (Claude Code, codex, ...) can take a task. The expensive model plans and curates; cheaper
  models implement decision-complete cards.
- **Learnings compound.** Every implementor reads `learnings.md` first; every handoff
  proposes new entries; the orchestrator curates. Run N+1 is cheaper than run N.

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
run it from the project's subdirectory. All tools find their project by walking up to the
nearest `.tower/`, so one repo can hold several independent tower projects.

1. Open an orchestrator session in the project, invoke `tower-orchestrator`, design
   together, let it write draft cards into `.tower/tasks/`.
2. Approve drafts (edit `status: draft` -> `ready`, or tell the orchestrator to).
3. The orchestrator finalizes `prompts/T###-prompt.md`, then: `tower-dispatch T001`.
   A new terminal opens with the implementor session, `TOWER_TASK` set, card `in-flight`.
4. Implementor works under the `tower-implementor` contract, opens the PR, writes the
   handoff (the Stop hook in [hooks/](hooks/README.md) enforces it).
5. You review and merge the PR. The orchestrator ingests the handoff: design/tasks/
   learnings updated, next prompts finalized, and you get a notification only at the
   three HITL gates — draft approval, design change, PR ready.

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
dispatch from inside a worktree that has no `.tower` adopts that worktree automatically:
discovery maps back to the main checkout's `.tower`, symlinks it in, and records the
worktree's existing branch on the card — so `cd <your-worktree>/<project> &&
tower-dispatch T### --here` is the whole flow when your own tooling creates the worktrees.

`tower-watch [--interval seconds] [--on-merge '<command>']` polls the in-review cards'
PRs via gh and notifies when one merges or a card turns blocked; `--on-merge` runs a
command with `TOWER_TASK` and `TOWER_PR` set (e.g. to prompt a non-Claude orchestrator via
`codex exec resume`). A Claude orchestrator on `/loop` does not need it.

## What it deliberately does not do

No automatic merges, no auto-approval, no daemon, no cross-machine anything. Reviewer
dispatch stays in your existing review flow. beads integration as the task ledger is a
possible phase 2 once the protocol proves itself.

## Requirements

macOS (osascript for notifications and terminal launch; `sed -i ''`), git, Claude Code for
the orchestrator and the Stop hook; codex CLI optional for implementors.
