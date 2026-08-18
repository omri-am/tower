# tower hooks

Both hooks are copy-paste snippets (`settings-snippets.json`), installed into the **target
project's** `.claude/settings.json` — never auto-installed. Neither is load-bearing: the
protocol works without them, they just remove manual steps.

## implementor-stop-check.sh (Stop hook, implementor sessions)

Blocks a Claude Code implementor session from finishing while its handoff file is missing.

Mechanism: `tower-dispatch` launches implementors with `TOWER_TASK=<task-id>` in the
environment. On Stop, the script checks that `.tower/handoffs/<task-id>-handoff.md` exists
and is non-empty; if not, it emits `{"decision": "block", "reason": ...}` telling the agent
to write it. Sessions without `TOWER_TASK`, and repeat fires (`stop_hook_active`), pass
through untouched, so the hook is safe to keep in a project's settings permanently.

Limitation: Claude Code only. A codex implementor gets the handoff requirement from its
prompt and the tower-implementor contract, with no hook enforcement.

## implementor-sendmessage-guard.sh (PreToolUse hook, SendMessage)

Hard-enforces the escalation-routing rule: a tower implementor session (identified by
`TOWER_TASK` or the `.tower-task` marker) may SendMessage only to the session named in
`.tower/orchestrator`; every other target is denied with a reason pointing back to the
file channel (blocked card + handoff + tower-notify). Sessions outside a tower implementor
context pass through untouched, so the hook is safe to install globally. This exists
because skill text alone is advice — an agent that learned a session address
conversationally will happily message it.

## FileChanged watcher (orchestrator session)

Watches `.tower/handoffs/*.md` and injects a note when a new handoff lands, so an idle
orchestrator picks it up on its next turn instead of polling on a loop tick.

The `FileChanged` event and matcher shape are taken from the Claude Code hooks
documentation (v2.1.233); verify the snippet fires in your setup once before relying on
it — if it does not, the orchestrator's `/loop` tick covers the same ground, just slower.
