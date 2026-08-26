---
name: tower-implementor
description: Execute one tower task card as an implementor session - read learnings first, stay inside the card's file ownership and decisions, escalate missing decisions instead of making them, open the PR, then hold on the PR watch and finalize the handoff when it merges. Use when a dispatch prompt references this skill or the session was launched by tower-dispatch (TOWER_TASK is set).
---

# tower implementor

You execute exactly one task card. The card made every interface decision already; your job
is implementation quality, not design. Your session ends with a handoff file — the Stop
hook will not let you finish without it.

## Order of operations

1. Locate the project. Run `tower-locate`: its first line is the directory holding
   `.tower/`, its second how it resolved — `TOWER_PROJECT_DIR`, the nearest ancestor with
   `.tower/`, the same path mapped into the main checkout when you are in a worktree that
   has none (via `git worktree list --porcelain`, whose first entry is the main worktree, so
   nothing depends on folder names), or a bounded search of the main checkout. When the
   resolved directory is not an ancestor of yours, make the resolution stick before doing
   anything else, so the Stop hook and every later process see the same state: in sidecar
   mode (`.tower/.git` exists) symlink it in with `ln -s <dir>/.tower .tower`, exactly as
   `tower-dispatch` does for a dispatched worktree; otherwise `cd` to the resolved
   directory, because a committed `.tower/` cannot be shadowed by a symlink. Exit 4 means
   ambiguous and exit 3 means nothing found — in both cases ask the owner which directory
   is the project, and **never run `tower-init`**: a fresh empty `.tower/` looks like a
   project and buries the real one. Resolution kind `copy` on the second line means the only
   `.tower/` available is a per-branch copy inside a linked worktree: stop there, tell the
   owner the project has no canonical state reachable from here, and do not implement — a
   handoff written into a copy is a handoff the orchestrator never reads.
2. Read the learnings selected for your card — before the card, before any code. They are
   already in your dispatch prompt; regenerate them with `tower-learnings --for $TOWER_TASK`
   if you were started without one. The selection is scoped to the paths you own, so it is
   short on purpose; read `.tower/learnings.md` whole only when you need context the
   selection lacks. Previous agents paid for these lessons.
3. Read your card in `.tower/tasks/` (your task id is in the prompt, in `$TOWER_TASK`, or
   in the `.tower-task` file at the project root).
   Re-read `## Corrections` if present — corrections supersede the original card body.
4. Implement on the card's branch, touching only paths listed under `## File ownership`.
   You are usually in your own git worktree, already on that branch; `.tower/` there is a
   symlink to the shared state, so whatever you write in it is immediately visible to the
   orchestrator and other sessions.
5. Run every command under `## Verification`; check acceptance criteria boxes in the card
   as they become true.
6. Open the PR (fill the card's `pr:` field), set card status `in-review`.
7. Write `handoffs/T###-handoff.md` from the template in `.tower/templates/handoff.md` —
   a draft at this point. The merged state, not the opened PR, is what the orchestrator
   ingests, so the draft is a record, not yet the deliverable.
8. Arm the merge watch, then hold. Run `tower-pr-wait` as a background command (in Claude
   Code, the Bash tool's `run_in_background`): it polls your card's PR and exits the moment
   the PR leaves OPEN, which re-invokes your session with `MERGED <pr>` or `CLOSED <pr>`.
   End the turn saying the session is holding for the merge and its window must stay open.
   Never poll in the foreground, and never ask the owner to tell you when the PR lands —
   that is the job this watch exists to remove. A session dispatched `--headless` exits when
   its turn ends, so nothing is left to wake: there, skip the hold and finish on the draft.
9. Finish when the watch fires. On `MERGED`: fetch the merged base, read what review changed
   since you opened the PR (the PR's diff and its review threads), and finalize the handoff
   with it. Only then flip the card `in-review` -> `merged` and commit `.tower` — `merged` is
   the orchestrator's ingest gate, so flipping it before finalizing offers a draft up as the
   deliverable. On `CLOSED`: record in the handoff that the PR was closed unmerged and what
   remains, leave the card `in-review`, and run `tower-notify`.

## Hard rules

- **A missing decision is an escalation, not a choice.** If implementing requires an
  interface, naming, or boundary decision the card did not make, stop and escalate: set the
  card `blocked`, write the question into the handoff's Decisions section, run
  `tower-notify "task blocked" "<id>: <one-line question>"`, and say so in your final
  message. Message a session directly only if `.tower/orchestrator` exists and names one —
  never guess the orchestrator from the session list; sessions unrelated to the project
  share the machine. Cognition's rule applies: actions carry implicit decisions, and two
  agents deciding independently diverge.
- **The session outlives the PR.** Opening the PR is not the end of the task; the merge is.
  Hold on the merge watch instead of handing the owner the job of telling you the PR landed.
  If the window is closed before the watch fires, the draft handoff plus the PR's final diff
  are what remain — degraded, not broken.
- **File ownership is a fence.** Needing a file outside your list means the card was cut
  wrong — escalate, do not touch it.
- **Corrections in-flight.** If the orchestrator messages you a correction mid-task, treat
  it as part of the card. Record it under `## Corrections` in the card if it is not already
  there.
- **The handoff is deliverable, not paperwork.** Decisions you made during work (only ones
  the card left open), discoveries the next agent should not re-pay for, candidate
  learnings in `- [category] lesson — why` form with the paths they apply to. A candidate
  that describes the system rather than how to work belongs in Discoveries — the
  orchestrator files those into `design.md`. Quote any selected learning that was stale,
  wrong, or that you had to work against under *Learnings that were wrong or violated*:
  that section is the only staleness signal the protocol gets, because an entry that
  quietly prevents a mistake leaves no trace. Write the handoff even when stopping early or
  blocked — especially then.
