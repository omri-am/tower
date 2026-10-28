# Codex queue delivery and the managed app-server daemon

Measured on macOS on 2026-10-28 with the installed `~/.codex/packages/standalone/current/bin/codex`, which resolved to **codex-cli 0.165.0**, and the model `gpt-6-luna`. Every run logged `"version": "codex-cli 0.165.0"` at start and `installed_after` as `0.165.0-aarch64-apple-darwin` at the end. `current` moved from 0.164.0 to 0.165.0 at 07:12Z that day, before the first run ([hand check at 07:00Z](queue-probes/logs/hand-checks/2026-10-28-no-daemon-state.txt) still saw 0.164.0). The managed daemon is **0.164.0** (`packages/app-server-daemon/current`). These are results for codex-cli 0.165.0 against daemon 0.164.0, with older CLI binaries where a case names them. They are not a general claim about Codex.

The machine rebooted at 08:36 local time, and no launchd agent starts the daemon again. Run `tmp.lyDjzIBc` therefore measured the state with no daemon. The owner then allowed one start ([log](queue-probes/logs/hand-checks/2026-10-28-daemon-start.txt)): `codex app-server daemon start` at 08:30:16Z returned `"status":"started","pid":48111,...,"cliVersion":"0.165.0","appServerVersion":"0.164.0"`. Run `tmp.TkLL4K3I` measured the state with that daemon running. The daemon was left running.

The [probe](queue-probes/p1_queue_matrix.py) reuses T038's harness from [`lifetime-probes/common.py`](lifetime-probes/common.py) without edits. It starts one throwaway interactive Codex TUI in a fresh fixture under `~/.cache/tower-t038-probes/`, and then sends it one `codex queue` call per case. A case changes one thing: the caller's environment against a clean `env -i` environment with only `HOME` and `PATH`, a flag, the Superset wrapper, or the binary version. Receipt comes from the session's own rollout and from a `notify` hook that only the probe's TUI runs. The terminal screen is not evidence. [`queue-probes/README.md`](queue-probes/README.md) gives the launcher and the case list.

In this document, **pass** means that the probe observed the behaviour that the question asks about. **fail** means that the probe observed its absence. **cannot determine** means that no run reached the observation.

| Question | Verdict | Log and excerpt |
| --- | --- | --- |
| 1. Does `codex queue` fail the same way while the daemon runs, from a clean `env -i` environment? | **fail**: from a clean environment it delivers. The caller's call fails because of flags that the Superset wrapper adds, not because of its environment. | [`tmp.TkLL4K3I`](queue-probes/logs/tmp.TkLL4K3I/p1_queue_matrix.jsonl): `caller_path` `"returncode": 1`, `Error: cannot queue through an embedded app server while a local app-server daemon is running; remove configuration overrides or use --remote`. `clean_local_bin` `"returncode": 0`, `receipt` `"received": true`. `clean_wrapper` (clean environment, wrapper first on `PATH`) `"returncode": 1` with the same error. |
| 2. Does it succeed when no daemon runs? | **pass**, also on the 0.164.0 and 0.162.1 binaries, with or without overrides | [`tmp.lyDjzIBc`](queue-probes/logs/tmp.lyDjzIBc/p1_queue_matrix.jsonl): `daemon_state` `"returncode": 1` `failed to connect to .../app-server-control.sock`. All 10 cases that target the live thread without `--remote` exit 0 with `Queued message <id> for thread <id>.`, and each `receipt` shows `"received": true, "notify_matched": true`. |
| 3. How can a caller find the daemon's address without writing under `~/.codex/`? | **pass**: `--remote unix://` resolves the address itself. `codex app-server daemon version` reports it. | `tmp.TkLL4K3I`: `daemon_state` `"socketPath": "/Users/omriam/.codex/app-server-control/app-server-control.sock"`. `remote_default` (`--remote unix://`) and `remote_socket_path` (that path) both exit 0 and are received. In `tmp.lyDjzIBc`, `remote_default` names the same path: ``failed to connect to remote app server at `unix:///Users/omriam/.codex/app-server-control/app-server-control.sock` ``. |
| 4. Does `codex queue --remote <address>` deliver into a live interactive session, and when? | **pass**: delivered into the live TUI. When the TUI is idle, the turn starts within about 10 seconds. When it is busy, the message waits for the next turn. | `tmp.TkLL4K3I`: `remote_default` `"returncode": 0`, `receipt` `"received": true, "notify_matched": true`, rollout holder `{"pid": "52542", "command": "codex"}` (the probe's TUI, not the daemon's pid 48111). `busy_result` for `remote_default`: `"steered": false, "same_turn": false`. |
| 5. Which exit status and stderr does each case give? | **pass**: every failure exits 1, so only stderr separates the cases | Table in [Question 5](#question-5-exit-status-and-stderr). |

## The 2026-10-26 failure came through the Superset wrapper

tower's adapter runs `codex queue --thread <id> --message <text>` with the sender's `PATH` (`lib/tower_msg.py`, `ADAPTERS`). The two failed sends to T051 are in [`delivery.log`](queue-probes/logs/field/2026-10-26-implementor-T051-delivery.log) at 14:07:15Z and 14:07:57Z. The Superset wrapper's debug log ([transcription](queue-probes/logs/field/2026-10-26-superset-wrapper-debug.txt)) shows two runs from the same terminal that exited 1 at the same seconds, and one run between them that exited 0. The orchestrator's `codex` on `PATH` was therefore `~/.superset/bin/codex`. Its last line runs the real binary with `--enable hooks` and `--dangerously-bypass-hook-trust` added to every call, `codex queue` included. Run `tmp.TkLL4K3I` reproduced that failure with the caller's environment (`caller_path`) and with the wrapper alone (`clean_wrapper`).

On 2026-10-26 every `codex` on this machine's `PATH` resolved to 0.164.0: `~/.local/bin/codex` links to `standalone/current`, which pointed at 0.164.0 from 2026-10-25 10:51 local. The card's statement that the failing call ran on 0.162.1 is therefore probably wrong. This is **inferred** from machine state: the orchestrator's own `PATH` was not recorded.

The version gap between the CLI and the daemon is not the cause. With daemon 0.164.0 running, the 0.165.0, 0.164.0 and 0.162.1 binaries all delivered when they ran without flags.

## The case matrix

"Received" means that the rollout recorded the exact message as a user record and a later `task_complete` carried its marker. Every received case also had `notify_matched: true`, and the probe's TUI was the only process that held the rollout open. The live session therefore ran each turn itself.

| Case | Binary | No daemon (`tmp.lyDjzIBc`) | Daemon 0.164.0 running (`tmp.TkLL4K3I`) |
| --- | --- | --- | --- |
| `caller_path`: the caller's environment, through the wrapper | 0.165.0 | 0, received | **1**, daemon error |
| `clean_local_bin`: `env -i`, `~/.local/bin` first, no flags | 0.165.0 | 0, received | 0, received |
| `clean_enable_hooks`: adds `--enable hooks` | 0.165.0 | 0, received | 0, received |
| `clean_bypass_hook_trust`: adds `--dangerously-bypass-hook-trust` | 0.165.0 | 0, received | **1**, daemon error |
| `clean_config_override`: adds `-c check_for_update_on_startup=false` | 0.165.0 | 0, received | **1**, daemon error |
| `clean_wrapper`: `env -i`, wrapper first on `PATH` | 0.165.0 | 0, received | **1**, daemon error |
| `v0_164_0` | 0.164.0 | 0, received | 0, received |
| `v0_164_0_enable_hooks` | 0.164.0 | 0, received | 0, received |
| `v0_162_1` | 0.162.1 | 0, received | 0, received |
| `v0_162_1_enable_hooks` | 0.162.1 | 0, received | **1**, daemon error |
| `remote_default`: `--remote unix://` | 0.165.0 | 1, connect error | 0, received |
| `remote_socket_path`: `--remote unix://<socketPath>` | 0.165.0 | 1, connect error | 0, received |
| `caller_remote_default`: the caller's wrapper path with `--remote unix://` | 0.165.0 | 1, connect error | 0, received |
| `remote_missing_socket` | 0.165.0 | 1, connect error | 1, connect error |
| `missing_thread`, `missing_thread_remote` | 0.165.0 | 1, unknown thread; 1, connect error | 1, unknown thread; 1, unknown thread |
| `caller_missing_thread` | 0.165.0 | 1, unknown thread | 1, daemon error |

So on 0.165.0 the "configuration override" is `-c` or `--dangerously-bypass-hook-trust`, and `--enable hooks` alone is not. On 0.162.1, `--enable hooks` alone is enough. The daemon check runs before the thread lookup: `caller_missing_thread` gets the daemon error, not the unknown-thread error. `--remote unix://` delivers even with the wrapper's flags (`caller_remote_default`).

## Question 4: timing

**Idle: within about 10 seconds.** With or without the daemon, every idle turn started on a 10-second grid. In `tmp.TkLL4K3I`, `task_started` came at 08:30:53.961Z, 08:31:03.973Z, 08:31:13.982Z, and so on to 08:32:04.046Z. Each queue call exited at a different point inside its interval, so the delay from exit to the rollout's user record ran from 0.22 to 6.09 seconds. An idle TUI therefore seems to pick up queued messages on a poll of about 10 seconds. That is **inferred** from the timing, because the poll itself is not logged. The daemon never held the rollout open, so it seems to hand the message to the TUI rather than run the turn itself. That is also **inferred**.

**Busy: the next turn.** For `remote_default` in `tmp.TkLL4K3I`, the busy prompt's turn started at 08:32:09.604Z. The queue call exited at 08:32:09.661Z, while that turn ran. The busy turn completed at 08:32:11.954Z, and a new turn (`01a181a3-66b2-...`) started at 08:32:11.967Z with the queued text. The plain `clean_local_bin` busy case and run `tmp.lyDjzIBc` show the same order. In the `clean_local_bin` busy case of `tmp.TkLL4K3I`, the model replied `Q_CLEAN_LOCAL_BIN` without the `_DURING_BUSY` suffix. The probe's marker check therefore logged no `queued_task_complete`. The rollout still shows the queued user record at index 133, in a new turn that started 5 ms after the busy turn completed. In `busy_queue`, `busy_completed_before_exit` is `null` because the busy turn had no `task_complete` yet when the call exited.

## Question 3: finding the address

A caller needs no lookup. `codex queue --remote unix://` resolves to `$CODEX_HOME/app-server-control/app-server-control.sock`. That path is a symlink to the daemon's listening socket under `/private/tmp/codex-daemon-501/`, and `lsof` shows the daemon listening on the target ([state log](queue-probes/logs/hand-checks/2026-10-28-daemon-running-state.txt)). The daemon runs with `--listen unix://`, its default path.

To learn whether a daemon runs, a caller can run `codex app-server daemon version`. It exits 0 with `"status":"running"` and `socketPath` while the daemon runs (`daemon_state` in `tmp.TkLL4K3I`). It exits 1 with `Error: failed to connect to ~/.codex/app-server-control/app-server-control.sock` when none runs (`daemon_state` in the other runs). Whether this command writes under `~/.codex/` was not isolated.

## Question 5: exit status and stderr

| Case | Exit | stderr (stdout for success) |
| --- | --- | --- |
| Delivered | 0 | stdout `Queued message <message id> for thread <thread id>.` |
| Daemon in the way | 1 | `Error: cannot queue through an embedded app server while a local app-server daemon is running; remove configuration overrides or use --remote` |
| `--remote` and no daemon or no socket | 1 | ``Error: failed to connect to remote app server: failed to connect to remote app server at `unix://<path>`: No such file or directory (os error 2)`` |
| Unknown thread, with or without `--remote` | 1 | `Error: failed to queue session message: thread/queue/add failed: failed to read thread: invalid thread-store request: no rollout found for thread id <id> (code -32603)` |

Each call returned in under one second. The calls through the wrapper with the caller's environment took 0.48 to 0.72 seconds, and every other call took 0.25 seconds or less. No call came near the adapter's 30-second timeout. The adapter cannot use the exit status to recognize the daemon case. It can match the stable prefix `cannot queue through an embedded app server`. That text is not a documented interface.

## Probe conduct

No probe answered a dialog. Runs [`tmp.kShL1tDS`](queue-probes/logs/tmp.kShL1tDS/p1_queue_matrix.jsonl), [`tmp.zo8Im3ZW`](queue-probes/logs/tmp.zo8Im3ZW/p1_queue_matrix.jsonl) and [`tmp.pP15AHYS`](queue-probes/logs/tmp.pP15AHYS/p1_queue_matrix.jsonl) stopped at a startup selector that is new in 0.165.0: `Hooks need review: 2 hooks are new or changed`, with `1. Review hooks`, `2. Trust all and continue`, `3. Continue without trusting`. They wrote nothing to the PTY. `--disable hooks` (run 2) and `--disable codex_hooks` (run 3) did not prevent the selector. Runs `tmp.lyDjzIBc` and `tmp.TkLL4K3I` added `--dangerously-bypass-hook-trust` to the TUI only, as the Superset wrapper does for every real session. The owner's `hooks.json` commands each begin with `[ -n "$SUPERSET_HOME_DIR" ]`, and the probe's launcher does not set that variable, so they did nothing. Plugin hooks may have run in those sessions; that was not measured. These two runs wrote only their prompts (`READY` and one busy prompt per busy phase) and `/quit` to the PTY.

The probe wrote nothing under `~/.codex/`. Apart from the one allowed start, no daemon was started, stopped or restarted, and `codex agents` never ran. Codex itself wrote these paths:

- The one allowed `codex app-server daemon start`: it created the link `app-server-control/app-server-control.sock` and `app-server-daemon/daemon-updater.stderr.log.previous`. It rewrote `daemon.pid`, `daemon-updater.pid`, the `daemon-updater.sock` link, `daemon.stderr.log`, `daemon.stderr.log.previous` and `daemon-updater.stderr.log` in `app-server-daemon/`, and it removed `app-server-daemon/loaded-threads.json`. Outside `~/.codex/`, it created the sockets under `/private/tmp/codex-daemon-501/`.
- Each complete run's session rollout: `sessions/2026/10/28/rollout-2026-10-28T09-43-41-01a18176-fe8c-7530-bbe9-7281bf4e344b.jsonl` (`tmp.lyDjzIBc`) and `sessions/2026/10/28/rollout-2026-10-28T10-30-45-01a181a2-12ff-7330-9b94-ced2dcb1929d.jsonl` (`tmp.TkLL4K3I`). Runs 1 to 3 created no rollout.
- Shared stores that changed while the probes ran: `queue_1.sqlite-wal`, `state_5.sqlite` and its WAL, `thread_history_1.sqlite` and its WAL and SHM files, `session_index.jsonl`, `history.jsonl`, `logs_2.sqlite` and its WAL, `memories_1.sqlite` WAL and SHM files, `models_cache.json`, `cloud-config-bundle-cache.json`, three files under `cache/`, and seven `plugins/cache/openai-curated-remote/*/.codex-remote-plugin-install.json` files, which every run rewrote.

Other Codex processes ran at the same time: the desktop app, three plugin app-servers, Codex workers for T052 and T054, and a connectors TUI. So the shared stores cannot be attributed to the probe alone. The same windows also show writes that are not the probe's: other sessions' rollouts and writer locks, `computer-use/`, `skills/`, plugin and marketplace caches, `.tmp/`, and `codex-resources` in older release directories.

## Recommendation for the adapter

The owner decides. The measured options:

1. **Retry with `--remote unix://` only on the daemon error. Recommended.** With no daemon, the plain call delivers, and nothing changes. With a daemon, the plain call from a Superset-hosted sender fails, and `--remote unix://` through the same wrapper delivers (`caller_remote_default`). This costs one extra call only in the failing case, and Codex's own error text names `--remote` as the fix. It also covers any other caller-side source of `-c` or `--dangerously-bypass-hook-trust`. Its risk is that it matches unversioned error text.
2. **Always pass `--remote unix://` when a daemon is found.** This delivers, but every send then needs a detection step, such as `codex app-server daemon version` (one more process per send), because `--remote` fails with exit 1 when no daemon runs.
3. **Remove the override.** Run the first `codex` on `PATH` outside `~/.superset/bin`, as the wrapper's own `find_real_binary` does. That call carries no override and delivered in both states (`clean_local_bin`). It also stops the wrapper from reporting a Superset `SessionEnd` for every send. But it couples tower to Superset's install layout, and it does not help when another wrapper or alias adds a `-c`.

Today, every send fails while a daemon runs and the sender's `codex` is the Superset wrapper. After `DELIVERY_ATTEMPTS = 3` failures, `return_failed_claim` moves the message to `undeliverable` (`lib/tower_msg.py`). Polling with `tower inbox` still worked during the field test.
