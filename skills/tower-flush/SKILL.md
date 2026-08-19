---
name: tower-flush
description: Retire the current session from a tower role by writing everything it knows into .tower/ files - use before closing an orchestrator or implementor session, when handing a role to another session or vendor, or when the user says "flush", "hand off your state", or "I'm closing this session".
---

# tower flush

You are being retired. After this session closes, the only you that exists is what is
written in `.tower/` — the test of a complete flush is that a fresh session reading only
those files loses nothing by replacing you.

If `.tower/` is not in your working directory or its ancestors, you are in a worktree and
the state lives in the main checkout: run `tower-root` (or
`find "$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")" -maxdepth 3 -type d -name .tower`)
and flush there. Never scaffold a second `.tower/`.

Go through these, writing only what is NOT already in the files:

1. **Design knowledge.** Decisions made or discussed this session, with rationale, into
   `design.md` — including decisions that were considered and rejected, and open questions
   you were holding in your head. Strike through superseded decisions, never delete them.
2. **Task state.** Cards for follow-up work you know about but never wrote down, even as
   rough drafts. Corrections you meant to send to in-flight cards go under their
   `## Corrections` headings. Card statuses you know to be stale get fixed.
3. **Learnings.** Anything you learned that would change the next agent's behavior, in
   `- [category] lesson — why` form. The bar is behavioral: if it would not have changed
   what an agent did, it is noise — leave it out.
4. **Ingest debt.** Handoffs you read but never fully processed: finish ingesting them now
   or note explicitly in `design.md`'s open questions which handoffs remain unprocessed.
5. **Role registration.** If `.tower/orchestrator` contains this session's address, delete
   the file — your address dies with you.

Commit everything inside `.tower/` (sidecar mode) or the project repo with a `tower:`
message. Then state in your final message, in one paragraph, what you flushed and what —
if anything — could not be captured in files.
