# A second vendor needs evidence before a wider adapter shape

`ADAPTERS` in `lib/tower_msg.py` has one `codex` entry with `qualifies`, `command`, and `name`. Registration hard-codes `thread`. Delivery uses subprocess exit status.

## A second vendor channel would need an address rather than a thread

`register()` stores `thread` in every record. `--thread` is `bin/tower-register`'s only vendor-specific flag. The Codex adapter's `qualifies` requires a nonempty `thread`.

`contract.md` lists `socket` for its PTY relay. M0's `compatibility.md` gave shared-terminal typing **no-go**. No relay command exists in `bin/`. `native-channels.md` measured Claude's stream-JSON input through its hosted `--print` process's stdin pipe. Codex app-server `turn/start` needs its host client's `--stdio` connection. Neither belongs to a later `tower send` process. Both hosting approaches change who owns the human interface. By inference, tower would need to own a host process that exposes a local endpoint. Registration would store its path, as the relay's `socket` field intended.

The smallest general change is one opaque `address` string in the registry and `register()` signature. Each adapter interprets it. Codex would pass it to `--thread`. `bin/tower-register` would add `--address` and keep `--thread` as an alias. A call that passes both flags fails. Keep `--thread` because `thread-identity.md` (T031, unmerged when this was written) recommends passing the main agent's `CODEX_THREAD_ID` to `tower-register --thread`. That value equalled the session's notify `thread-id` on codex-cli 0.159.3. Existing live `thread` records need a compatibility read or fresh registration.

## A second vendor channel would need a submission outcome and separate receipt evidence

`deliver_queued()` calls `subprocess.run(adapter['command'](...), capture_output=True, text=True, errors='replace', timeout=30)`. Exit 0 moves `claimed` to `submitted`. `TimeoutExpired` becomes 124, `KeyboardInterrupt` 130, and `OSError` or `ValueError` 127. Failure requeues or retires the claim.

By inference, a helper executable could expose socket, HTTP, JSON-RPC, or file delivery as argv. Direct socket and HTTP calls need connection and response handling. A file drop needs a successful write, such as atomic publish, before submission. A callable is needed only if transport runs inside `tower send`. It should return a submission outcome and error while shared code retains claim transitions.

Codex app-server `turn/start` and `turn/steer` are measured JSON-RPC examples in `native-channels.md`. In a client-hosted thread, `turn/start` wakes from idle and `item/started` later carries receipt on the same connection. `turn/steer` fails idle wake. Both fail reach into a live TUI because `thread/resume` reports an active writer. The request response was not used as receipt. Codex `queue` exit 0 means enqueued, not received. Mapping that exit to `submitted` matches `contract.md`, where submission means bytes written without acknowledgement. The table lacks receipt observation and transition to `acknowledged`. The native rollout contains measured receipt evidence, but its format and path stability remain unverified.

`tests/msg_test.sh` runs real `bin/tower send` with a stub `codex` on `PATH`. It checks the first four argv fields exactly, then checks the message's envelope prefix and body suffix. An in-process callable needs a fake transport or local endpoint and equivalent state assertions. It loses the executable-boundary test. `subprocess.run` kills the child on timeout, limiting one stuck command's hold on `delivery.lock` to 30 seconds. `deliver()` keeps the lock for the whole batch. An in-process callable needs bounded I/O or process isolation to avoid holding that lock indefinitely. By inference, `SIGKILL` can leave the current child alive. That child could submit after recovery requeues the claim. An in-process transport dies with the sender unless it starts independent work.

## A measured second vendor channel would justify generalisation

Generalising now would change a tested interface without a qualifying second vendor channel. Codex `queue` alone passes native reach and idle wake for a live TUI in `native-channels.md`. Claude stream-JSON input fails reach because `--input-format stream-json` works only with `--print` and starts its own session. `compatibility.md` calls Claude shared-terminal typing **no-go** because items 1, 2, 3, and 6 remain unproven. `hook-wake.md` gives Claude FileChanged idle wake **cannot determine** under its quota limit. Its model-context exclusion is documented, not measured.

The trigger is a second vendor channel that passes all five `native-channels.md` items for a live interactive session on an exact version: reach, wake from idle, busy delivery, receipt signal, and human coexistence. Codex `queue` passed these on 0.158.0, with receipt API risk and human coexistence limited to the observed draft. By inference, the `contract.md` go rule governs shared-terminal typing. Its seven items concern readiness, dialogs, keystrokes, composer, submission bytes, reset, and payload. Codex was adopted through native-channel evidence while `compatibility.md` marked typing item 3 **fail**.

## A second vendor changes more than the table

| File | Change outside `ADAPTERS` | Scope |
| --- | --- | --- |
| `lib/tower_msg.py` | Change `register()` and its record field to `address`. Read existing live `thread` records. Keep `adapter_for()`'s vendor and `wake` checks. Change `deliver_queued()` for non-argv transport and add receipt handling. | Registration, delivery, receipt |
| `bin/tower-register` | Add `--address`, preserve `--thread`, and pass the selected value to `register()`. | Registration |
| `bin/tower-agents` | No change. It prints `wake`, not `thread`, from `list_agents()`. | None |
| `tests/msg_test.sh` | Update `record['thread'] == thread`. Cover the new channel and preserve `--thread` behavior. | Registration, delivery |
| `tests/agents_test.sh` | Update `register(..., thread='thread-1')` and cover the new channel's `wake` value. | Registration |
| `docs/agent-messaging/contract.md` | Reconcile proposed `socket` and `adapters` with implemented `thread` and `wake`, or proposed `address`. Preserve the submission and receipt distinction. | Contract |
| New host command in `bin/`, `bin/tower-bootstrap`, `lib/tower-dispatch.sh` | Tower would launch a hosted channel, expose a local endpoint, list the command in `COMMANDS`, and launch it through dispatch. `tests/shim_test.sh` requires every `bin/` command in `COMMANDS`. | Hosted channel only |
| `lib/tower-dispatch.sh` | Extend `prepare_launch()` beyond Claude and Codex launch arguments. Launch-side, outside the messaging table. | Second dispatched vendor |
| `bin/tower-dispatch` | Extend `case "$VENDOR" in claude\|codex)` validation. Launch-side, outside the messaging table. | Second dispatched vendor |

**Recommendation: generalise when a second vendor passes the contract.** Here the contract means the five `native-channels.md` items above. A measured second vendor channel would justify an opaque address and a helper executable before a callable. This gives a future change more direction than leaving the table unchanged.

The strongest argument against waiting is the missing receipt slot for Codex, the live adapter. Waiting leaves that known gap in place. One change could add receipt handling and `address` together. But `native-channels.md` measured receipt only in Codex's native rollout, whose format and path stability remain unverified. A receipt slot has no supported source to call yet.
