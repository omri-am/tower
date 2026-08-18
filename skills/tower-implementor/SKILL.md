---
name: tower-implementor
description: Execute one tower task card as an implementor session - read learnings first, stay inside the card's file ownership and decisions, escalate missing decisions instead of making them, open the PR, and write the handoff before finishing. Use when a dispatch prompt references this skill or the session was launched by tower-dispatch (TOWER_TASK is set).
---

# tower implementor

You execute exactly one task card. The card made every interface decision already; your job
is implementation quality, not design. Your session ends with a handoff file — the Stop
hook will not let you finish without it.

## Order of operations

1. Read `.tower/learnings.md` — before the card, before any code. It exists because
   previous agents paid for these lessons.
2. Read your card in `.tower/tasks/` (your task id is in the prompt, in `$TOWER_TASK`, or
   in the `.tower-task` file at the project root).
   Re-read `## Corrections` if present — corrections supersede the original card body.
3. Implement on the card's branch, touching only paths listed under `## File ownership`.
   You are usually in your own git worktree, already on that branch; `.tower/` there is a
   symlink to the shared state, so whatever you write in it is immediately visible to the
   orchestrator and other sessions.
4. Run every command under `## Verification`; check acceptance criteria boxes in the card
   as they become true.
5. Open the PR (fill the card's `pr:` field), set card status `in-review`.
6. Write `handoffs/T###-handoff.md` from the template in `.tower/templates/handoff.md`.

## Hard rules

- **A missing decision is an escalation, not a choice.** If implementing requires an
  interface, naming, or boundary decision the card did not make, stop and escalate: message
  the orchestrator session if one is running (ListAgents / SendMessage), otherwise write
  the question into the handoff's Decisions section, set the card `blocked`, and say so in
  your final message. Cognition's rule applies: actions carry implicit decisions, and two
  agents deciding independently diverge.
- **File ownership is a fence.** Needing a file outside your list means the card was cut
  wrong — escalate, do not touch it.
- **Corrections in-flight.** If the orchestrator messages you a correction mid-task, treat
  it as part of the card. Record it under `## Corrections` in the card if it is not already
  there.
- **The handoff is deliverable, not paperwork.** Decisions you made during work (only ones
  the card left open), discoveries the next agent should not re-pay for, candidate
  learnings in `- [category] lesson — why` form. Write it even when stopping early or
  blocked — especially then.
