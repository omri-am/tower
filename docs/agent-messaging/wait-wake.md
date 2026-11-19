# An inbox wait woke Claude after two hours; an async hook repeated an unacknowledged message

Claude Code 2.1.318, measured on macOS on 2026-11-19 with `claude-haiku-5-5`.

## Method and setup

The [probe driver](wait-probes/session.py) used tmux for each interactive session. It created each project with `mktemp -d`, `git init`, and this worktree's `bin/tower-init --sidecar`. Each session used this worktree's absolute `bin/tower-inbox` path. A second shell used this worktree's `bin/tower-send`; exit 3 means the message was queued for an unregistered role. Scratch `--settings` installed `Stop` and `UserPromptSubmit` hooks. Every log event has UTC and monotonic time. Terminal events came from `tmux pipe-pane`; the operator inspected the pane before each input. The sessions used manual permission mode. P1, P2a, P2b, and P3 also allowed Bash so Claude could start the waiter.

At each launch, `command -v claude` resolved to `/Users/omriam/.local/state/fnm_multishells/96602_1795075468767/bin/claude`. Its real binary was `/Users/omriam/.local/share/fnm/node-versions/v24.19.0/installation/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe`. The dispatch notes expected the `~/.paradev/bin/claude` wrapper, but this shell selected the fnm symlink. The sessions used `/Users/omriam/.claude` as their config directory. The SHA-256 of `~/.claude/settings.json` was `b61ad84dcb52887a257c99b755f16712f507477d3c0a3e95793aecea813e48ce` before the probes. After the last probe, the hash was `66f3f3f3a2a0ff3483d61559d71743145c0c2ae094baacad54b2bc8ad44efec4`. The file mtime was 08:38:01 UTC, while P3 waited. The probe driver used only scratch settings. The source of this change is unknown, so the unchanged-settings criterion failed.

Workspace trust was accepted only for these scratch projects: P1 `tmp.EKsMhRs6ru`, P2a `tmp.SYRgUVYix9`, P2b `tmp.vMObe9SVgV` and `tmp.JNJDVVxY3Y`, P3 `tmp.l15zqJ3qGG`, P3's kill control `tmp.G0BjtmdrQJ`, and P4 `tmp.gFrh5hjZox`. Two exploratory tmux launches also accepted trust for scratch projects `tmp.qB6MW48P7L` and `tmp.vAuVNWuiwg`. All names were under `/private/var/folders/33/yy9h3fms4zsfmn5rv69f0b7c0000gn/T/`. The corresponding `~/.claude.json` project entries have trust set to true. Early PTY trials exited during trust and have no project entry. An exploratory Bypass Permissions launch reached the [recorded security choice dialog](wait-probes/startup.log). No BAY-EVT id appeared. Its default “No, exit” choice closed the session; no approval was given. No measured probe answered a tool, permission, security, or choice dialog.

## P1: idle waiter — pass

The waiter ran with `--wait 900`. No terminal input followed its first Stop hook before the send. The send began 120.030 seconds after Stop. Its exit 3 queued the id. Claude then started an unsolicited turn and named that id 2.45 seconds after the send completed. [P1 log](wait-probes/p1.log):

```text
08:14:31.753Z mono=525163.496 Stop
08:16:33.322Z mono=525285.065 send exit=3 id=m-20261119T081633Z-899aefe552b3bf4b31dc6e422ea06d40
08:16:33.527Z mono=525285.270 UserPromptSubmit
08:16:33.575Z mono=525285.318 terminal: background command completed, exit code 0
08:16:35.772Z mono=525287.515 terminal: assistant named m-20261119T081633Z-899aefe552b3bf4b31dc6e422ea06d40
```

## P2a: busy foreground turn — cannot determine

Claude started the background waiter and replied READY. The managed PreToolUse hook blocked its foreground `Bash(sleep 120)` call before execution. There was no busy turn in which to send. [P2a log](wait-probes/p2a.log):

```text
08:15:44.455Z mono=525236.199 terminal: Error: Blocked: standalone sleep 120
```

## P2b: open permission dialog — cannot determine

Claude started the background waiter. The Write tool created `/tmp/t082-permission-probe.txt` without a dialog. A Write to `/System/t082-permission-probe.txt` failed with `EPERM` without a dialog. A second scratch run allowed only the waiter Bash command, but a different Bash write still ran without a dialog. No message was sent because no dialog opened. Both created `/tmp` files were removed. No dialog was answered. [First P2b log](wait-probes/p2b.log) and [second P2b log](wait-probes/p2b2.log):

```text
08:17:20.234Z mono=525331.977 terminal: Write to /System/t082-permission-probe.txt failed with EPERM; no dialog
08:28:15.053Z mono=525986.791 terminal: assistant reported no permission dialog after a command-specific Bash allow rule
```

## P3: waiter lifetime and process cleanup — pass

The `--wait 10800` waiter remained alive 7,500 seconds after the first Stop hook. The send then queued an id with exit 3. Claude started a new turn and named that id. A normal `/exit` closed the session; `pgrep -f 'tower_msg.py inbox'` returned exit 1 with no PIDs. In a second scratch run, `SIGKILL` of Claude PID 76603 left waiter PID 82985 alive after three seconds. I removed that orphan with `SIGTERM`. The T023 learning that a Claude background command dies within two hours did not hold on Claude Code 2.1.318 in this interactive session. [P3 log](wait-probes/p3.log) and [kill-control log](wait-probes/p3kill.log):

```text
10:16:44.694Z mono=532496.410 pgrep: waiter PID 78610 present after 2h5m
10:16:44.968Z mono=532496.684 send exit=3 id=m-20261119T101644Z-9a6b2405aeb16b3389bb28762b469b6d
10:16:46.279Z mono=532497.995 terminal: background command completed, exit code 0
10:16:48.688Z mono=532500.404 terminal: assistant named m-20261119T101644Z-9a6b2405aeb16b3389bb28762b469b6d
10:18:20.613Z mono=532592.328 pgrep after /exit: exit=1 pids=[]
08:19:43.281Z mono=525475.023 pgrep after SIGKILL: waiter PID 82985 still present
```

## P4: asyncRewake hook — pass

The scratch Stop hook used `asyncRewake: true`, `timeout: 600`, and this worktree's inbox waiter with `--wait 590`. The send began 120.026 seconds after Stop. Its exit 3 queued the id. The hook returned that id on stderr and woke Claude. Claude named the id in a new turn. Because the message stayed queued, the Stop hook caused 18 repeated turns. The second shell acknowledged the id to end the loop. At 626.131 seconds after the final Stop, the waiter was gone and Claude was still idle. No turn or timeout notice appeared at the 600-second hook limit. The log does not show the waiter's exact exit time. [P4 log](wait-probes/p4.log):

```text
08:20:01.536Z mono=525493.279 send exit=3 id=m-20261119T082001Z-6b16bad25a8d1ae6f07860e0eac12963
08:20:01.922Z mono=525493.664 terminal: new assistant turn: Stop hook feedback #1
08:20:02.908Z mono=525494.650 terminal: assistant named m-20261119T082001Z-6b16bad25a8d1ae6f07860e0eac12963
08:20:24.730Z mono=525516.472 terminal: new assistant turn: Stop hook feedback #18
08:30:51.724Z mono=526143.462 timeout observation: waiter absent; Claude idle; no new turn
```

## Probe verdicts

| Probe | Verdict | Evidence |
| --- | --- | --- |
| P1 idle | pass | Unsolicited turn named the queued id within 30 seconds. |
| P2a busy | cannot determine | PreToolUse blocked the foreground sleep. |
| P2b dialog | cannot determine | Neither Write attempt nor the later Bash attempt opened a dialog. |
| P3 lifetime | pass | PID 78610 survived 2h5m and woke Claude; normal quit removed it, SIGKILL left an orphan. |
| P4 asyncRewake | pass | Hook feedback named the id; no new turn or timeout notice appeared by 626 seconds. |
