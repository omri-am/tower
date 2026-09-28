# T020 hook wake: Codex nothing; Claude cannot determine

Measured on macOS, 2026-09-28. Neither hook establishes `wake: native`. Claude's
session limit prevented measuring model context, as allowed by T020's correction.

## Method and setup

In a fresh `mktemp -d` directory run `python3 /absolute/path/to/idle_hook.py codex
--seconds 900` (or `claude`). [The throwaway script](hook-probes/idle_hook.py) reuses T014's PTY harness.
Config is isolated under scratch `config/`; `events.jsonl` records monotonic `at`
and Unix `utc` timestamps, callbacks, terminal output and operator input.
Codex copies auth to a mode-0600 scratch file; Claude uses a privately supplied
`CLAUDE_CODE_OAUTH_TOKEN`. Never commit config.
`T020_CLAUDE_BINARY` optionally pins an executable; the actual version is logged.

After inspecting the initial managed-settings dialog, create the empty scratch
file `approve-managed-settings` to accept it once. C6 accepted only the displayed
organization telemetry endpoint setting (`OTEL_EXPORTER_OTLP_LOGS_ENDPOINT`).
Scratch workspace trust was also accepted; no tool/permission/choice was approved.
The owner's `~/.claude/settings.json` and `~/.claude.json` hashes were unchanged
across setup; hooks exist only in scratch. [Config isolation reference](https://code.claude.com/docs/en/env-vars).

After native READY completion, wait at least 120 seconds without input. In a
separate process at the same scratch cwd run `python3 /absolute/path/to/idle_hook.py --write`.
Observe another 120 seconds. Inspect `events.jsonl` and native session records;
never infer turn starts from terminal redraws. Append one `{label,text}` action to
`actions.jsonl` only after inspecting the composer; use separate bracketed paste
and CR actions for a recall prompt that does not reveal the hook marker. Quit with
`{"label":"quit"}`. Never replay actions unattended. Only owned process groups are killed. Logs: `/tmp/tower-T020.U6Orab`.

## Claude Code 2.1.283 / Haiku 4.5 — FileChanged

Named probe C6 (`claude-6`) could not obtain one successful turn after setup:

```text
2026-09-28T16:32:45.857Z managed_settings_approval: scratch claude-6/config
2026-09-28T16:32:50.061Z UserPromptSubmit: Reply READY. Do not use any tools.
2026-09-28T16:32:50.988Z StopFailure: rate_limit
last_assistant_message: You've hit your session limit · resets 7:50pm (Asia/Jerusalem)
16:34:57.857 external_write; 16:34:58.857 FileChanged add; 16:34:58.880 terminal marker
```

C6 wrote the file 126.869 seconds after StopFailure. The callback fired 1.000
seconds later and its marker appeared in the terminal. No new prompt hook fired
within 149.541 seconds after the write (quota-blocked). Verdict: **cannot determine** idle wake or next-turn model context;
quota-blocked behavior cannot certify successful-turn idle behavior.

The [FileChanged reference](https://code.claude.com/docs/en/hooks#filechanged)
describes external filesystem detection and terminal notification output, not
model input. The matcher `watched/message.txt|message.txt` seeds a literal path and matches
its basename. The callback emits `systemMessage: T020_HOOK_SECRET_71492`.
Documented recommendation: **terminal-only**,
not `wake: native`; this mechanism is useless for agent-to-agent messaging because
its output goes to the human terminal, not the recipient model. Model-context
exclusion remains documented, not measured here. No wake latency is established.

## Codex CLI 0.158.0 / GPT-6-Luna — notify: nothing

Named probe X2 (`codex-2`) recorded these events (UTC):

```text
16:26:49.243 native task_complete: READY
16:26:49.532 notify: agent-turn-complete, target thread 01a0e8d7-1729-79b3-ad1a-7e9c17fb30cd
16:29:10.475 external_write: watched/message.txt, writer pid 70838
16:31:34.093 idle_observation_end: 143.618 seconds after write
16:32:40.185 native task_started: operator's recall prompt
16:32:42.356 native task_complete: NONE
```

The file appeared 141 seconds after target completion. No target turn or notify
occurred in the 143.618-second post-write window. An earlier title-generation
callback had a different thread id and was excluded. The subsequent operator
turn returned NONE and produced its own notify; the file event was not delivered
at the next turn. X2 exited with `reaped: true`. Outcome: **nothing** for the external
file event; recommendation: notify does not yield `wake: native`.

The [notify reference](https://learn.chatgpt.com/docs/config-file/config-advanced#notifications)
specifies “currently only `agent-turn-complete`”. The [hook lifecycle table](https://learn.chatgpt.com/docs/hooks)
lists turn, interruption, session and subagent events, with no external-file event.
There is no externally triggered inbound hook in that documented contract.
This says nothing against T015's separate `codex queue` native input channel.
