# tower protocol

The contract between the orchestrator role, implementor sessions, and the human owner.
Everything durable lives in files under `.tower/` at the **project root**, committed to
main. Sessions are disposable; any session assuming a role rehydrates from these files.

The project root is where `tower-init` was run: the repo root for a single-project repo, or
a subdirectory (e.g. `monorepo/connectors/`) when one repo holds several projects. Every
tower tool and role discovers its project by walking up from the current directory to the
nearest ancestor containing `.tower/`, so a monorepo can hold many independent tower
projects side by side. Branches are namespaced per project (`tower/<project-dir>/T###-slug`)
because the branch namespace is repo-wide.

## State directory

```
.tower/
  design.md            living design doc, edited only by the orchestrator
  learnings.md         curated lessons, read-first for every implementor
  tasks/               one card per task: T###-slug.md
  handoffs/            one handoff per finished task: T###-handoff.md
  prompts/             finalized dispatch prompts: T###-prompt.md
  templates/           card and handoff templates (copied here by tower-init)
```

The orchestrator commits state changes directly on main with the prefix `tower:`.
`git log --oneline -- .tower/` is the audit trail; `git diff` on `.tower/design.md` is how
the owner reviews design changes.

**Sidecar mode** (`tower-init --sidecar`): for projects whose repo must stay clean of tower
files (e.g. company repos), `.tower/` is its own nested git repo, hidden from the parent via
`.git/info/exclude` — local-only, so not even the exclusion is committed. The protocol is
unchanged; every git command above just runs inside `.tower/` instead of the parent. Sidecar
detection is `.tower/.git` existing. Think before adding a remote to a sidecar: its content
describes the parent codebase, so it usually belongs local-only or on the same-tier host.

**Worktrees**: implementors work in per-task git worktrees, which `tower-dispatch` creates
(at `<repo>-tower-worktrees/T###`, on the card's branch) — `--in-place` opts out. `.tower/`
stays canonical in the main checkout; dispatch symlinks it into the worktree's project dir,
so every session — orchestrator in the main checkout, implementors in worktrees — reads and
writes the same state, and a handoff written from a worktree is immediately visible to the
orchestrator. This requires sidecar mode (a committed `.tower/` would materialize as a
stale per-branch copy in each worktree); dispatch enforces that. After ingesting a task's
handoff, the orchestrator removes its worktree (`git worktree remove`).

## Task cards — `tasks/T###-slug.md`

```yaml
---
id: T001
title: Short imperative title
status: draft        # draft | ready | in-flight | in-review | merged | blocked
depends_on: []       # list of task ids, e.g. [T001, T002]
vendor: any          # claude | codex | any
branch: ""           # filled at dispatch
pr: ""               # filled when the PR is opened
---
```

Body sections, all required:

- `## Goal` — what exists when this task is done, one paragraph.
- `## Interfaces & decisions` — every API shape, naming, and boundary choice, made HERE by
  the orchestrator. A card is decision-complete when the implementor never has to choose an
  interface. If a decision is missing, the implementor escalates instead of deciding.
- `## File ownership` — the files/directories this task may touch. Two in-flight cards must
  never overlap here; overlapping cards are sequenced with `depends_on`.
- `## Out of scope` — explicit non-goals.
- `## Acceptance criteria` — checklist, all unchecked at creation. The card is done when
  every box is checked and verified.
- `## Verification` — exact commands that prove the acceptance criteria.

Status semantics: `draft` cards are the orchestrator planning ahead — they carry scope,
interfaces, and acceptance criteria but no prompt. The owner approves a draft to make it
`ready`. Prompts are finalized only for `ready` cards whose dependencies are all `merged`.

## Prompts — `prompts/T###-prompt.md`

Written by the orchestrator immediately before dispatch, never in advance. Contents, in
order: the tower-implementor contract reference, the full card, the current `learnings.md`,
and excerpts of any handoffs that changed this task's assumptions. A prompt is a snapshot;
if it goes stale before launch, the orchestrator regenerates it (cheap by design).

## Handoffs — `handoffs/T###-handoff.md`

Written by the implementor when its work ends — right after opening the PR, or when
stopping early or blocked — always before the session ends. Sections: What was done, Decisions made during work, Discoveries,
Suggested follow-up tasks, Candidate learnings. The Stop hook blocks an implementor session
from finishing while its handoff is missing.

## Learnings — `learnings.md`

Format: `- [category] lesson — why it matters`, grouped under `##` category headings.
Implementors read it before touching anything. Implementors never write it directly; they
propose candidates in handoffs, and the orchestrator curates: specific and preventive
entries merge, vague ones are rejected. A lesson that would not have changed an agent's
behavior is noise and does not belong here.

## Lifecycle

```
 owner            orchestrator                 implementor
   |                   |                            |
   |   approve draft   |                            |
   |------------------>| card: draft -> ready       |
   |                   | finalize prompt            |
   |                   | tower-dispatch             |
   |                   |--------------------------->| card: in-flight
   |                   |                            | read learnings + card
   |                   |   (SendMessage correction) | implement, open PR
   |   review PR       |<---------------------------| card: in-review
   |------------------>|         merge              |
   |                   |<---------------------------| write handoff
   |                   | ingest handoff             |
   |                   | update design/tasks/       |
   |                   |   learnings, card: merged  |
   |   notified of     | finalize next prompts      |
   |<------------------| design diff + ready tasks  |
```

## HITL gates — the owner decides, always

1. Draft cards become `ready` only on owner approval.
2. Design-doc changes triggered by handoffs are surfaced as a git diff for the owner.
3. PRs are merged by the owner (or the owner's review flow), never by tower.

The orchestrator calls `tower-notify` at each gate and otherwise does not interrupt.

## Orchestrators without Claude Code plumbing

Any CLI agent (Codex, others) can hold the orchestrator role — the role is these files, not
a vendor feature. Three substitutions apply: instead of SendMessage, mid-flight corrections
are written into the in-flight card under a `## Corrections` heading (implementors re-read
it) and the owner is notified via `tower-notify`; instead of a background loop or file
watcher, the orchestrator processes handoffs when the owner says a PR merged (or the owner
runs `tower-watch`, which polls the in-review cards' PRs and notifies on merge and on
blocked cards), and always runs the rehydration ritual at session start; escalations from implementors arrive as
`blocked` cards and handoff files rather than live messages, so check for `status: blocked`
during every ingest pass. `tower-init` copies this file into `.tower/PROTOCOL.md` so the
project is self-contained.

## Roles are disposable

Orchestrator rehydration ritual, in order: `design.md`, all cards with status other than
`merged`, `learnings.md`, handoffs newer than the last `tower:` commit. After that the
session is the orchestrator, regardless of which session it is or which vendor runs it.
