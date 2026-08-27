# tower

![license](https://img.shields.io/badge/license-MIT-blue)
![protocol](https://img.shields.io/badge/protocol-v1-informational)
![platform](https://img.shields.io/badge/platform-macOS-lightgrey)

tower lets you run several coding agents in parallel on one repository while you keep
final say. One orchestrator session plans the work as task cards. Implementor sessions
each take one card and open one PR. You approve plans, review design diffs, and merge —
and you are interrupted only at those three points.

Everything the system knows is markdown files in a git-committed `.tower/` directory.
There is no daemon, no queue, no database: kill any session at any time and the next one
continues from the files.

The name is from air traffic control: *handoff* is the ATC term for passing an aircraft
between controllers, and the tower — the human — always has final authority.

## Table of contents

- [Is this for you?](#is-this-for-you)
- [How it works](#how-it-works)
- [Install](#install)
- [Quickstart](#quickstart)
- [Learn more](#learn-more)
- [Development](#development)

## Is this for you?

Use tower when a project is big enough for several agents at once, you still want to
approve the plan and read every PR, and you want to close your laptop without losing
state. Skip it for single-session work or when a ticket system already drives your agents.

## How it works

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
and committed — the orchestrator reads handoffs, implementors read prompts, you read
diffs. An implementor does not end at its PR: it holds on `tower-pr-wait`, wakes on the
merge, and finalizes its own handoff. You never tell anyone that a PR landed.

Task cards are decision-complete (an implementor never invents a decision), learnings are
path-scoped (prompts stay small as the corpus grows), and there are exactly three points
where you are asked for anything. These ideas are unpacked in
[docs/REFERENCE.md](docs/REFERENCE.md#core-ideas).

## Install

As a Claude Code plugin (recommended):

```
/plugin marketplace add omri-am/tower
/plugin install tower@tower
/tower:tower-bootstrap
```

`/tower:tower-bootstrap` links the `tower-*` shell commands into `~/.local/bin` through a
resolver shim, so plugin updates need no relinking. If that command does not resolve, run
the script directly from the plugin cache — list the cached versions, then invoke the one
you have:

```
ls -d ~/.claude/plugins/cache/tower/tower/*/
bash ~/.claude/plugins/cache/tower/tower/<version>/bin/tower-bootstrap
```

Add `~/.local/bin` to your PATH if the bootstrap says so. Plugin-installed skills are
namespaced (`tower:tower-orchestrator`, `tower:tower-implementor`, `tower:tower-flush`);
the `install.sh` route below keeps the bare names.

Leave auto-update **off** for this marketplace — a live orchestrator must not have its
templates change underneath it; take updates when the once-a-day notice tells you one
exists.

From a clone (the route for non-Claude agents): `git clone git@github.com:omri-am/tower.git
&& cd tower && ./install.sh`.

Requires macOS (osascript, BSD sed), git, jq, and Claude Code for the orchestrator. The
codex CLI is optional, for implementors.

## Quickstart

```
cd ~/code/my-project
tower-init                        # scaffolds .tower/ and commits it
tower-orchestrate                 # opens the orchestrator session
```

1. **Design** with the orchestrator; it writes draft cards into `.tower/tasks/`.
2. **Approve drafts** — read them with `tower-card`, flip `status: draft` -> `ready`
   (gate 1).
3. **Dispatch** — `tower-dispatch T001` opens an implementor in its own worktree.
4. **Implementor works**, opens the PR, writes a draft handoff, then holds on
   `tower-pr-wait`.
5. **Review and merge** — the merge wakes the implementor; it finalizes its handoff and
   the orchestrator ingests it: design, tasks and learnings updated, next prompts
   finalized.

To retire any tower session, invoke `tower-flush` in it first: it writes everything it
knows into `.tower/` so the next session loses nothing.

For repos that must stay clean, `tower-init --sidecar` makes `.tower/` its own nested git
repo, hidden via `.git/info/exclude`. Sidecar mode is required for per-task worktrees.

## Learn more

- [docs/REFERENCE.md](docs/REFERENCE.md) — core ideas in depth, every command and flag,
  configuration variables, project discovery, the case for files over sessions.
- [PROTOCOL.md](PROTOCOL.md) — the full contract between the roles.
- [CHANGELOG.md](CHANGELOG.md) — what each version added.

Deliberate non-goals: no automatic merges, no auto-approval, no daemon, no cross-machine
anything.

## Development

`tests/run.sh` runs all shell tests. Layout: `bin/` the `tower-*` commands, `lib/` shared
shell, `skills/` the three role skills, `hooks/` the Stop hook and version notice,
`templates/` card and handoff templates. [PROTOCOL.md](PROTOCOL.md) is the contract;
change it and bump `PROTOCOL_VERSION`.

## License

[MIT](LICENSE).
