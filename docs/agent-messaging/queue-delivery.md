# Codex queue delivery and the managed app-server daemon

Measured on macOS on 2026-10-28 with the installed `~/.codex/packages/standalone/current/bin/codex`, which resolved to **codex-cli 0.165.0**, and the model `gpt-6-luna`. The run logged `"version": "codex-cli 0.165.0"` at start and `installed_after` as `0.165.0-aarch64-apple-darwin` at the end. `current` moved from 0.164.0 to 0.165.0 at 07:12Z that day, before the first run ([hand check at 07:00Z](queue-probes/logs/hand-checks/2026-10-28-no-daemon-state.txt) still saw 0.164.0). The managed daemon package is **0.164.0** (`packages/app-server-daemon/current`). The daemon did not run during any probe run: the machine rebooted at 08:36 local time, and no launchd agent starts the daemon again. These are results for codex-cli 0.165.0, with older binaries where a case names them, not a general claim about Codex.

The [probe](queue-probes/p1_queue_matrix.py) reuses T038's harness from [`lifetime-probes/common.py`](lifetime-probes/common.py) without edits. It starts one throwaway interactive Codex TUI in a fresh fixture under `~/.cache/tower-t038-probes/`, and then sends it one `codex queue` call per case. A case changes one thing: the caller's environment against a clean `env -i` environment with only `HOME` and `PATH`, a flag, the Superset wrapper, or the binary version. Receipt comes from the session's own rollout and from a `notify` hook that only the probe's TUI runs. The terminal screen is not evidence. [`queue-probes/README.md`](queue-probes/README.md) gives the launcher and the case list.

In this document, **pass** means that the probe observed the behaviour that the question asks about. **fail** means that the probe observed its absence. **cannot determine** means that no run reached the observation.

| Question | Verdict | Log and excerpt |
| --- | --- | --- |
| 1. Does `codex queue` fail the same way while the daemon runs, from a clean `env -i` environment? | **cannot determine**: no daemon ran during the runs. The field evidence below suggests that the override came from the Superset wrapper's added flags (**inferred**). | No probe log. Field: [`delivery.log`](queue-probes/logs/field/2026-10-26-implementor-T051-delivery.log) `exit=1 Error: cannot queue through an embedded app server while a local app-server daemon is running; remove configuration overrides or use --remote`, at the same seconds as two Superset wrapper runs `codex exited status=1` ([transcription](queue-probes/logs/field/2026-10-26-superset-wrapper-debug.txt)). |
| 2. Does it succeed when no daemon runs? | **pass** on codex-cli 0.165.0, and also on the 0.164.0 and 0.162.1 binaries, with or without overrides | [`tmp.lyDjzIBc`](queue-probes/logs/tmp.lyDjzIBc/p1_queue_matrix.jsonl): `daemon_state` `"returncode": 1` `failed to connect to .../app-server-control.sock`. Then all 10 cases that target the live thread without `--remote` exit 0 with `Queued message <id> for thread 01a18176-fe8c-7530-bbe9-7281bf4e344b.`, and each `receipt` shows `"received": true, "notify_matched": true`, rollout holder `{"pid": "31585", "command": "codex"}` (the probe's TUI). |
| 3. How can a caller find the daemon's address without writing under `~/.codex/`? | **pass**: `--remote unix://` resolves the address itself, and `codex app-server daemon version` reports it | Same log, `remote_default`: ``failed to connect to remote app server at `unix:///Users/omriam/.codex/app-server-control/app-server-control.sock` ``. The daemon listens with `--listen unix://`, and `daemon version` printed `"socketPath":"/Users/omriam/.codex/app-server-control/app-server-control.sock"` while it ran ([2026-10-26 transcription](queue-probes/logs/hand-checks/2026-10-26-daemon-running-state.txt)). |
| 4. Does `codex queue --remote <address>` deliver into a live interactive session, and when? | **cannot determine**: no daemon ran. Without one, every `--remote` form exits 1. | Same log, `remote_default`, `remote_socket_path`, `caller_remote_default`: `"returncode": 1`, `failed to connect to remote app server`. |
| 5. Which exit status and stderr does each case give? | **pass**: every failure exits 1, so only stderr separates the cases. The daemon case is field evidence, not a probe result. | Table in [Question 5](#question-5-exit-status-and-stderr). |

## The 2026-10-26 failure came through the Superset wrapper

tower's adapter runs `codex queue --thread <id> --message <text>` with the sender's `PATH` (`lib/tower_msg.py`, `ADAPTERS`). The two failed sends to T051 are in `delivery.log` at 14:07:15Z and 14:07:57Z. The Superset wrapper's debug log shows two runs from the same terminal that exited 1 at the same seconds, and one run between them that exited 0. The orchestrator's `codex` on `PATH` was therefore `~/.superset/bin/codex`. Its last line runs the real binary with `--enable hooks` and `--dangerously-bypass-hook-trust` added to every call, `codex queue` included. `codex queue --help` describes `--enable` as "Equivalent to `-c features.<name>=true`", which is a configuration override.

On 2026-10-26 every `codex` on this machine's `PATH` resolved to 0.164.0: `~/.local/bin/codex` links to `standalone/current`, which pointed at 0.164.0 from 2026-10-25 10:51 local. T051's own TUI ran that binary through the wrapper. The card's statement that the failing call ran on 0.162.1 is therefore probably wrong. This is **inferred** from machine state: the orchestrator's own `PATH` was not recorded.

## Question 2: delivery without a daemon

Run `tmp.lyDjzIBc` is the complete run. Each idle case waited for the previous turn to complete. "Delay" is the time from the queue command's exit to the rollout's user record.

| Case | Binary that ran | Exit | Received | Delay (s) |
| --- | --- | --- | --- | --- |
| `caller_path`: the caller's environment, through the wrapper | 0.165.0 | 0 | yes | 1.1 |
| `clean_local_bin`: `env -i`, `~/.local/bin` first | 0.165.0 | 0 | yes | 4.7 |
| `clean_enable_hooks`: adds `--enable hooks` | 0.165.0 | 0 | yes | 3.9 |
| `clean_bypass_hook_trust`: adds `--dangerously-bypass-hook-trust` | 0.165.0 | 0 | yes | 5.7 |
| `clean_config_override`: adds `-c check_for_update_on_startup=false` | 0.165.0 | 0 | yes | 5.5 |
| `clean_wrapper`: `env -i`, wrapper first on `PATH` | 0.165.0 | 0 | yes | 5.1 |
| `v0_164_0`, `v0_164_0_enable_hooks` | 0.164.0 | 0, 0 | yes, yes | 4.2, 4.4 |
| `v0_162_1`, `v0_162_1_enable_hooks` | 0.162.1 | 0, 0 | yes, yes | 3.1, 5.7 |

So without a daemon the override does not matter. Every case also had `notify_matched: true`, and the probe's TUI was the only process that held the rollout open. The live session therefore ran each turn itself.

**At once, within about 10 seconds, when idle.** Every idle turn started on a 10-second grid: `task_started` at 07:43:50.122Z, 07:44:00.137Z, 07:44:10.145Z, and so on to 07:45:20.285Z (`rollout_summary`). The queue calls exited at different points inside those intervals. An idle TUI therefore seems to pick up queued messages on a poll of about 10 seconds. That is **inferred** from the timing; the poll itself is not logged.

**At the next turn when busy.** The busy case pasted a long prompt into the TUI and ran `clean_local_bin` during that turn. The queue call exited at 07:45:27.471Z, during the busy turn, which started at 07:45:27.311Z. The busy turn completed at 07:45:30.055Z (`turn_id` `01a18178-9b06-...`). A new turn (`01a18178-a5c8-...`) started at 07:45:30.062Z and held the queued text: `busy_result` `"steered": false, "same_turn": false`. In the `busy_queue` event, `busy_completed_before_exit` is `null` because the busy turn had no `task_complete` yet at that moment.

## Question 3: finding the address

A caller needs no lookup. `codex queue --remote unix://` resolves to `$CODEX_HOME/app-server-control/app-server-control.sock`, as its error message shows. On 2026-10-26 that path was a symlink to the daemon's listening socket `/private/tmp/codex-daemon-501/6c71...`, and `lsof` showed the daemon process listening on that target. The reboot removed both the symlink and the target.

To learn whether a daemon runs, a caller can run `codex app-server daemon version`. It exits 0 with `"status":"running"` and the `socketPath` while the daemon runs (2026-10-26 transcription). It exits 1 with `Error: failed to connect to ~/.codex/app-server-control/app-server-control.sock` when none runs (`daemon_state` in every run, and the [2026-10-28 hand check](queue-probes/logs/hand-checks/2026-10-28-no-daemon-state.txt)). Whether the command writes under `~/.codex/` was not isolated.

## Question 5: exit status and stderr

| Case | Exit | stderr (stdout for success) | Source |
| --- | --- | --- | --- |
| Delivered | 0 | stdout `Queued message <message id> for thread <thread id>.` | `tmp.lyDjzIBc`, 10 idle cases and the busy case |
| Daemon in the way | 1 | `Error: cannot queue through an embedded app server while a local app-server daemon is running; remove configuration overrides or use --remote` | field `delivery.log`, 2026-10-26 |
| `--remote` and no daemon or no socket | 1 | ``Error: failed to connect to remote app server: failed to connect to remote app server at `unix://<path>`: No such file or directory (os error 2)`` | `tmp.lyDjzIBc`: `remote_default`, `remote_socket_path`, `caller_remote_default`, `remote_missing_socket`, `missing_thread_remote` |
| Unknown thread | 1 | `Error: failed to queue session message: thread/queue/add failed: failed to read thread: invalid thread-store request: no rollout found for thread id <id> (code -32603)` | `tmp.lyDjzIBc`: `missing_thread`, `caller_missing_thread` |

Each call returned in under one second. The longest, about 0.67 seconds, went through the wrapper with the caller's environment. No call came near the adapter's 30-second timeout. The adapter cannot use the exit status to recognize the daemon case. It can match the stable prefix `cannot queue through an embedded app server`. That text is not a documented interface.

## Probe conduct

No probe answered a dialog. Runs [`tmp.kShL1tDS`](queue-probes/logs/tmp.kShL1tDS/p1_queue_matrix.jsonl), [`tmp.zo8Im3ZW`](queue-probes/logs/tmp.zo8Im3ZW/p1_queue_matrix.jsonl) and [`tmp.pP15AHYS`](queue-probes/logs/tmp.pP15AHYS/p1_queue_matrix.jsonl) stopped at a startup selector that is new in 0.165.0: `Hooks need review: 2 hooks are new or changed`, with `1. Review hooks`, `2. Trust all and continue`, `3. Continue without trusting`. They wrote nothing to the PTY. `--disable hooks` (run 2) and `--disable codex_hooks` (run 3) did not prevent the selector. Run `tmp.lyDjzIBc` added `--dangerously-bypass-hook-trust` to the TUI only, as the Superset wrapper does for every real session. The owner's `hooks.json` commands each begin with `[ -n "$SUPERSET_HOME_DIR" ]`, and the probe's launcher does not set that variable, so they did nothing. Plugin hooks may have run in that session; that was not measured. The run's only PTY writes were its two prompts and `/quit`.

The probe wrote nothing under `~/.codex/` and never started, stopped or restarted a daemon. Codex itself wrote these paths between 07:31Z and 07:46Z, from `modified_codex_home_paths` and a before-and-after listing:

- The probe session's rollout `sessions/2026/10/28/rollout-2026-10-28T09-43-41-01a18176-fe8c-7530-bbe9-7281bf4e344b.jsonl` (run 4 only; runs 1 to 3 created no rollout).
- Shared stores that changed while the probe ran: `queue_1.sqlite-wal`, `state_5.sqlite` and its WAL, `thread_history_1.sqlite` and its WAL, `session_index.jsonl`, `history.jsonl`, `logs_2.sqlite` and its WAL, `memories_1.sqlite` WAL and SHM files, `models_cache.json`, `cloud-config-bundle-cache.json`, three files under `cache/`, and seven `plugins/cache/openai-curated-remote/*/.codex-remote-plugin-install.json` files, which every run rewrote.

Other Codex processes ran at the same time: the desktop app, three plugin app-servers, Codex workers for T052 and T054, and a connectors TUI. So the shared stores cannot be attributed to the probe alone. The same window also shows writes that are not the probe's: four rollouts and their writer locks from T052 and T054, `computer-use/`, plugin and marketplace caches, `.tmp/`, and `codex-resources` in older release directories.

## Recommendation for the adapter (provisional)

The owner decides. Questions 1 and 4 are still open, so this recommendation depends on a daemon run.

1. **Do not always pass `--remote`.** Without a daemon, every `--remote` form exits 1, while the plain call delivers. To always pass it, the adapter must first detect a running daemon, for example with `codex app-server daemon version`. That adds one process to every send.
2. **Retry with `--remote unix://` only on the daemon error.** This is the recommended option, if question 4 passes. It changes nothing when no daemon runs, which is the measured state. It costs one extra call only in the failing case, and Codex's own error text names `--remote` as the fix. Its risk is that it matches unversioned error text.
3. **Remove the override instead.** The adapter could run the first `codex` on `PATH` outside `~/.superset/bin`, as the wrapper's own `find_real_binary` does. Then the call carries no override. This depends on question 1: a clean call must deliver while the daemon runs. It also couples tower to Superset's install layout.

Today, every send fails while the daemon runs, and after `DELIVERY_ATTEMPTS = 3` failures `return_failed_claim` moves the message to `undeliverable` (`lib/tower_msg.py`). Polling with `tower inbox` still worked during the field test.
