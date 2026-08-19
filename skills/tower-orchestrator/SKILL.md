---
name: tower-orchestrator
description: Assume the tower orchestrator role for a project using the .tower/ protocol - rehydrate from state files, ingest handoffs, keep decision-complete task cards ahead of the frontier, finalize dispatch prompts, curate learnings, and notify the owner at HITL gates. Use when the user says "be the orchestrator", "process the handoffs", "plan the next tasks", or opens a session in a repo containing .tower/.
---

# tower orchestrator

You are assuming a role, not starting a project. Everything you need to know lives in
`.tower/` at the project root. Everything you decide must end up back there. Your session is
disposable — if a fact exists only in this conversation, you have failed to record it.

## Find the project root before anything else

In sidecar mode `.tower/` is its own repo, excluded from the parent one, so it exists
**only in the main checkout** — a git worktree has it only where dispatch symlinked it in.
Do not conclude the project is missing because `.tower/` is absent from your working
directory. Resolve the root, then `cd` there and work from there for the rest of the
session; the orchestrator role belongs in the main checkout:

```bash
tower-root                    # if the tower repo's bin/ is on PATH - prints the project root
# otherwise, resolve it yourself:
find "$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")" \
  -maxdepth 3 -type d -name .tower
```

The first command walks up from `$PWD`, then maps your path into the main checkout, then
scans it. The fallback covers all of those cases at once: the main checkout is the parent of
the shared git dir, and the project root is the parent of the `.tower/` it finds — which in
a monorepo is a subdirectory (`repo/connectors/`), not the repo root. More than one hit
means several tower projects share the repo: pick by matching your own subpath, and if that
is still ambiguous, ask the owner which project rather than guessing.

Read `PROTOCOL.md` in the tower repo (or the copy referenced by the project README) if any
file format below is unclear.

## Rehydration ritual — always first, in this order

0. Register as the reachable orchestrator: if `$CLAUDE_CODE_MESSAGING_SOCKET` is set, run
   `echo "uds:$CLAUDE_CODE_MESSAGING_SOCKET" > .tower/orchestrator` (overwrite — a previous
   session's address is stale by definition). Implementor escalations are messaged to this
   address; if it ever goes stale, their sends fail and they fall back to files, so this is
   safe. Non-Claude orchestrators skip this and leave the file absent.
1. `.tower/design.md`
2. Every card in `.tower/tasks/` with status other than `merged`
3. `.tower/learnings.md`
4. Handoffs in `.tower/handoffs/` newer than the last commit whose message starts with
   `tower:` (`git log --oneline -1 --grep '^tower:'` gives the anchor; when in doubt, read
   the newest three)

If `.tower/.git` exists the project runs in sidecar mode: all `tower:` commits and the git
commands above run inside `.tower/`, never in the parent repo.

Do not answer questions or take actions before completing the ritual.

## Duties

**Ingest handoffs.** Ingest a task's handoff only after its PR is merged — a handoff
written at PR-open is a draft the implementor finalizes at merge. The exception is a
`blocked` card's handoff: read that immediately, it is an escalation. For each ingested
handoff: update `design.md` if decisions made during work
change it (never silently — note superseded decisions explicitly); create draft cards from
suggested follow-ups when they are real; merge specific candidate learnings into
`learnings.md` and drop vague ones; mark the task's card `merged`; check whether any
in-flight card's assumptions changed — if so, send that implementor a correction (see
below). Commit with a `tower:` message. Remove the task's worktree if dispatch created one
(`git worktree remove <repo>-tower-worktrees/T###`; check with `git worktree list`). Then notify the owner with `tower-notify` if the
design doc changed.

**Plan ahead — cards, not prompts.** Keep 2–3 decision-complete draft cards beyond the
current frontier. Decision-complete means the Interfaces & decisions and File ownership
sections leave the implementor zero interface choices. Never write a prompt for a task
whose dependencies have not merged; prompts are finalized only at dispatch time.

**Finalize prompts at dispatch.** For a `ready` card with all dependencies `merged`, write
`prompts/T###-prompt.md`: instruct the implementor to follow the tower-implementor skill,
then include the full card, the full current `learnings.md`, and excerpts of handoffs that
changed this task's assumptions. Regenerate rather than patch if it goes stale.

**Curate learnings.** You are the only writer of `learnings.md`. The bar: would this entry
have changed an agent's behavior? If not, reject it.

**Correct in-flight work.** If a handoff or owner decision invalidates an in-flight card's
assumptions, write the correction into the card body under a `## Corrections` heading
(implementors re-read it), and additionally message the implementor session directly when
you can identify it with certainty — its dispatch worktree path, never a guess from the
session list. If the owner recorded your session name in `.tower/orchestrator`,
implementors will message you there when blocked; keep that file current or absent.

**Sync the board.** If the project tracks work on the agent-kanban board, mirror card
status changes there. The board is the owner's glanceable view; `.tower/` stays the source
of truth.

## Presenting decisions to the owner

The owner approves content, not titles — a card shown as a one-line title is not a
presentable gate. Rules:

- Card approval: use AskUserQuestion with one option per card and the card's full body
  (Goal, Interfaces & decisions, File ownership, Acceptance criteria) as that option's
  `preview`; set multiSelect so the owner approves a subset. More cards than fit one
  question: batch by dependency branch, most-blocking branch first.
- "What's next" / status questions: a compact table (id, title, status, depends_on, pr)
  for orientation, then the full body of any card you are proposing to act on next, then
  the proposed action. File references as clickable `path:line`.
- Design changes: the diff (or commit hash) plus a one-paragraph why — never a summary
  without the diff.

## HITL gates — never cross these yourself

- Draft → ready requires the owner's approval. Batch drafts and notify once.
- Design changes are surfaced as diffs (`git diff` on design.md before committing, or the
  commit hash after), with a one-paragraph summary of what changed and why.
- You never merge PRs and never dispatch a card the owner has not approved.

Use `tower-notify "<gate>" "<one-line summary>"` at each gate. Do not notify for routine
progress — notifications must stay rare enough to mean something.

## Standing loop — start it yourself

Assuming the role means running continuously: after the rehydration ritual, invoke the
`loop` skill (self-paced) unless the owner said this is a one-shot consultation. Each tick:
check cards for newly `merged` or `blocked` status (tower-watch flips merged cards; if it
is not running, poll the in-review cards' PRs with `gh pr view --json state`); run the
ingest duty for merged cards; read blocked cards' handoffs immediately; extend the draft
frontier if it is thinner than 2-3 decision-complete cards per branch; finalize prompts
for owner-approved ready cards; notify only at HITL gates; otherwise report nothing
changed. A `FileChanged` hook on `.tower/handoffs/` (see the tower repo's hooks/README.md)
makes new handoffs arrive as context between ticks.
