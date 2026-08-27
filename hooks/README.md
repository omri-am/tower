# tower hooks

One hook is auto-installed: the version notice in `hooks.json`, which ships with the plugin
and needs no setup. Every other hook here is a copy-paste snippet (`settings-snippets.json`)
installed into the **target project's** `.claude/settings.json` — never auto-installed.
None is load-bearing: the protocol works without them, they just remove manual steps.

## tower-version-notice.sh (SessionStart hook, auto-installed with the plugin)

Runs `bin/tower-version-check --notice` and, when a newer tower exists, emits the same
one-line notice as `hookSpecificOutput.additionalContext` so the session can tell its owner.
Silent when the install is current, so a current install costs no tokens. Reads only the
cache, never the network, so it cannot delay session start. Silenced by
`TOWER_NO_VERSION_CHECK=1`. Users on the `install.sh` route get this only if they add the
snippet by hand; the plugin route gets it automatically.

## implementor-stop-check.sh (Stop hook, implementor sessions)

Blocks a Claude Code implementor session from finishing while its handoff file is missing.

Mechanism: `tower-dispatch` launches implementors with `TOWER_TASK=<task-id>` in the
environment. On Stop, the script resolves the project with `tower-locate` (the full
discovery chain, so it works from a worktree that has no `.tower/` of its own) and checks
that `handoffs/<task-id>-handoff.md` exists there and is non-empty; if not, it emits
`{"decision": "block", "reason": ...}` telling the agent to write it. A session that has a
task id but no locatable project is blocked too, with instructions to resolve the project
and ask the owner if it cannot — otherwise an implementor in an ad-hoc worktree would slip
out of the handoff requirement entirely. Sessions without `TOWER_TASK`, and repeat fires
(`stop_hook_active`), pass through untouched, so the hook is safe to keep in a project's
settings permanently.

Limitation: Claude Code only. A codex implementor gets the handoff requirement from its
prompt and the tower-implementor contract, with no hook enforcement.

## implementor-sendmessage-guard.sh (PreToolUse hook, SendMessage)

Hard-enforces the escalation-routing rule: a tower implementor session (identified by
`TOWER_TASK` or the `.tower-task` marker) may SendMessage only to the session named in
`.tower/orchestrator`; every other target is denied with a reason pointing back to the
file channel (blocked card + handoff + tower-notify). The comparison ignores a trailing
` [ref]` on either side, because cross-session first contact is only accepted with the ref
appended — matching on the bare name would deny exactly the send the file authorizes. It
strips only a bracket group that actually ends the string, so a session name containing a
bracket earlier keeps it and cannot collapse onto a different name. It resolves the project
with
`tower-locate` as well, and denies when the project cannot be located at all — an
unreadable allowlist is not an open one. Sessions outside a tower implementor
context pass through untouched, so the hook is safe to install globally. This exists
because skill text alone is advice — an agent that learned a session address
conversationally will happily message it.

## FileChanged watcher (orchestrator session)

Watches `.tower/handoffs/*.md` and injects a note when a new handoff lands, so an idle
orchestrator picks it up on its next turn instead of polling on a loop tick.

The `FileChanged` event and matcher shape are taken from the Claude Code hooks
documentation (v2.1.233); verify the snippet fires in your setup once before relying on
it — if it does not, the orchestrator's `/loop` tick covers the same ground, just slower.
