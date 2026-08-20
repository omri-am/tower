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
  learnings.md         curated lessons, path-scoped, selected per card at dispatch
  learnings-archive.md retired lessons, out of every prompt, kept for provenance
  card-sizing.md       card-size limits for this project, confirmed once by the owner
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
orchestrator. Dispatch also writes the task id to a `.tower-task` marker beside the
symlink; the Stop hook reads it when `TOWER_TASK` is not in the environment, so agents
started by external worktree platforms (after `tower-dispatch --prep`) are equally bound
to the handoff requirement. This requires sidecar mode (a committed `.tower/` would materialize as a
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

Card size: one card is one reviewable PR. Concretely, it crosses one boundary, lists five or
fewer paths under `## File ownership`, and carries seven or fewer acceptance criteria. A card
that wants more than that wants splitting. This is where the protocol's two opposing forces
resolve: file ownership rewards large cards (fewer overlaps to sequence) while
decision-completeness rewards small ones (every interface must be pre-decided), and the
reviewable-PR ceiling is what breaks the tie. Splitting is preferred over widening — a card
too large for one review is a card the owner cannot gate on. The numbers above are
defaults; the project's live limits are `.tower/card-sizing.md`, which the orchestrator
confirms with the owner once and then reads at every rehydration.

Status semantics: `draft` cards are the orchestrator planning ahead — they carry scope,
interfaces, and acceptance criteria but no prompt. The owner approves a draft to make it
`ready`. Prompts are finalized only for `ready` cards whose dependencies are all `merged`.

## Prompts — `prompts/T###-prompt.md`

Written by the orchestrator immediately before dispatch, never in advance. Contents, in
order: the tower-implementor contract reference, the full card, the learnings this card
selects (`tower-learnings --for T###`, never the whole file),
and excerpts of any handoffs that changed this task's assumptions. A prompt is a snapshot;
if it goes stale before launch, the orchestrator regenerates it (cheap by design).

## Handoffs — `handoffs/T###-handoff.md`

Written in two phases. A draft goes in when the PR opens — the Stop hook refuses to let an
implementor session end without one, so early stops and blocks always leave a record. The
real handoff is finalized after the PR merges: review-driven changes are part of what was
done, so the implementor updates the file when the owner merges while its session is still
alive; if the session is already gone, the draft plus the PR's final diff are what remains.
The orchestrator ingests a handoff only once its card's PR is `merged` — except blocked
escalations, which it reads immediately. Sections: What was done, Decisions made during work, Discoveries,
Suggested follow-up tasks, Candidate learnings, Learnings that were wrong or violated. The Stop hook blocks an implementor session
from finishing while its handoff is missing.

## Learnings — `learnings.md`

Implementors never write this file; they propose candidates in handoffs and the
orchestrator curates. The failure this format defends against is not length — it is
**contradiction**: an entry from T007 that the design superseded at T031 is read as
current and sends the implementor the wrong way. Length costs tokens; contradiction costs
correctness. Age is not decay, so nothing here is pruned by date.

**The filing rule comes first.** Most rot is a misfiled entry, so before adding one, place
it: a fact about the system goes in `design.md` (which already has supersede discipline);
a rule true for every tower project is promoted into the `tower-implementor` skill or the
card template; only a project-specific way of working or failure mode belongs here. Entries
leave this file upward (promotion) and sideways (design.md), not only downward.

**Format.** `- [category] lesson — why it matters (T###)`, where `T###` is the task whose
handoff paid for it — provenance, not a date: it points at the handoff and the PR, so a
pruner can check whether the context still exists. `##` headings are path scopes:

```markdown
## Always
- [process] verification commands run in the project dir, not the repo root — worktrees
  make them differ (T004)

## scope: bin/**
- [tooling] bash on macOS is 3.2: no mapfile, no associative arrays (T012)
```

**Selection at dispatch, not curation by hope.** `tower-learnings --for T###` intersects
the scope globs with the card's `## File ownership` and prints `## Always` plus the
sections that match; matching is by literal path prefix in either direction, with
wildcards truncated — so a token that begins with a wildcard has no literal prefix and
matches nothing. Every unscoped heading is always included, so an unmigrated flat file
still prints whole. Prompts are regenerated per dispatch, so this decouples file size from
prompt cost — the file can grow without every implementor paying for all of it. Scope only
when a lesson is clearly local; under-scoping costs tokens, over-scoping hides the lesson
from the one agent that needed it.

**Budget and retirement.** 60 entries (`tower-learnings --check`, which also flags entries
missing provenance). At the budget, adding requires retiring one — a forced tradeoff,
because a calendar review never happens. Retirement moves the entry to
`learnings-archive.md` with a reason and the retiring task id: out of every prompt, still
greppable, and recoverable without archaeology.

**When to prune — events, never a schedule.** Three triggers, all during ingest: a
`design.md` change re-checks the entries scoped to the paths it touched; a handoff
reporting an entry wrong or violated fixes or retires it that same pass; crossing the
budget forces a sweep. There is deliberately no citation counter: a preventive entry that
works produces no evidence — nothing goes wrong, so nothing is reported — and counting
mentions would prune exactly the silent guardrails while keeping whatever generates
drama. The only trustworthy signal is negative and comes from the handoff's *Learnings
that were wrong or violated* section.

The standing bar for admitting an entry is unchanged: would it have changed an agent's
behavior? If not, it is noise.

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

## Escalation routing

Escalation is file-based by default: `blocked` card + handoff + `tower-notify`. Direct
session-to-session messages are opt-in only — the owner may write a reachable orchestrator
session name into `.tower/orchestrator`, and only a session named there gets messaged.
Agents must never guess a role-holder from the machine's session list; unrelated sessions
share the machine.

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

Orchestrator rehydration ritual, in order: `design.md`, `card-sizing.md` (absent means the
card-size defaults above apply), all cards with status other than `merged`, `learnings.md`,
handoffs newer than the last `tower:` commit. After that the session is the orchestrator,
regardless of which session it is or which vendor runs it.
