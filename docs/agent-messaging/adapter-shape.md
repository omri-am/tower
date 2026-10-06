# A second vendor needs evidence before a wider adapter shape

`ADAPTERS` in `lib/tower_msg.py` has one `codex` entry with `qualifies`, `command`, and `name`. Registration hard-codes `thread`. Delivery uses subprocess exit status. A second vendor cannot always fit the table alone.

## Registration needs an address rather than a thread

`register()` stores `thread` in every record. `bin/tower-register` accepts only `--thread`. Codex requires a nonempty thread for `codex queue --thread`.

`contract.md` lists `socket` for its PTY relay. M0's `compatibility.md` gave shared-terminal typing a **no-go** verdict. No relay command exists in `bin/`. In `native-channels.md`, Claude's stream-JSON input is the stdin pipe of its hosted `--print` process. Codex app-server `turn/start` needs its host client's connection. Neither belongs to a later `tower send` process. Both hosting approaches change who owns the human interface. I infer that a viable hosted vendor needs a host process exposing a local endpoint. Registration would store that endpoint's path, the role intended for the relay's `socket` field.

The smallest general change is one opaque `address` string in the registry and `register()` signature. Each adapter interprets it. Codex would pass it to `--thread`. `bin/tower-register` would add `--address` and retain `--thread` as a Codex-compatible alias. A call that passes both flags fails. `thread-identity.md` (T031, unmerged when this was written) measured `CODEX_THREAD_ID` equal to `CODEX_SESSION_ID` in an interactive Codex TUI on codex-cli 0.159.3. The main dispatched agent can pass it to `tower-register --thread`. `codex queue --thread` accepts a UUID or exact session name. T031 did not measure prompt compliance or registration from that sandbox. Existing live `thread` records need a compatibility read or fresh registration.

## Delivery needs a transport result and separate receipt evidence

`deliver_queued()` calls `subprocess.run(adapter['command'](...), capture_output=True, text=True, errors='replace', timeout=30)`. Exit 0 moves `claimed` to `submitted`. `TimeoutExpired` becomes 124, `KeyboardInterrupt` 130, and `OSError` or `ValueError` 127. Failure requeues or retires the claim.

A helper executable could expose socket, HTTP, JSON-RPC, or file delivery as argv. This is an inference, not a measured vendor channel. Direct socket and HTTP calls need connection and response handling. A file drop needs a successful write, such as atomic publish, before submission. A callable is needed only if transport runs inside `tower send`. It should return a submission outcome and error while shared code retains claim transitions.

Codex app-server `turn/start` and `turn/steer` are measured JSON-RPC examples in `native-channels.md`. In a client-hosted thread, `turn/start` wakes from idle and `item/started` later carries receipt on the same connection. `turn/steer` fails idle wake. Both fail reach into a live TUI because `thread/resume` reports an active writer. A request response alone is not receipt. Codex `queue` exit 0 means enqueued, not received. Mapping that exit to `submitted` matches `contract.md`, where submission means bytes written without acknowledgement. The table lacks receipt observation and transition to `acknowledged`. The native rollout contains measured receipt evidence, but its format and path stability remain unverified.

`tests/msg_test.sh` runs real `bin/tower send` with a stub `codex` on `PATH`. It compares exact NUL-separated argv bytes and checks submission, failure, interruption, and recovery. An in-process callable needs a fake transport or local endpoint and equivalent state assertions. It loses the executable-boundary test. `subprocess.run` kills the child on timeout, limiting one stuck command's hold on `delivery.lock` to 30 seconds. `deliver()` keeps the lock for the whole batch. An in-process callable needs bounded I/O or process isolation to avoid holding that lock indefinitely. By inference, `SIGKILL` can leave the current child alive. That child could submit after recovery requeues the claim, based on the process boundary and recovery code. An in-process transport dies with the sender unless it starts independent work.

## A measured second channel would justify generalisation

Generalising now would permit transports beyond argv. It would change a tested interface without a qualifying second vendor. Codex `queue` alone passes native reach and idle wake for a live TUI in `native-channels.md`. Claude stream-JSON input fails reach because `--input-format stream-json` works only with `--print` and starts its own session. `compatibility.md` calls Claude shared-terminal typing **no-go** because items 1, 2, 3, and 6 remain unproven under quota limits. `hook-wake.md` gives Claude FileChanged idle wake **cannot determine** under that quota limit. Its model-context exclusion is documented, not measured.

The trigger is a second vendor channel that passes all five `native-channels.md` items for a live interactive session on an exact version: reach, wake from idle, busy delivery, receipt signal, and human coexistence. Codex `queue` passed these on 0.158.0, with receipt API risk and human coexistence limited to the observed draft. The `contract.md` go rule applies only to a channel that types into a shared terminal.

## A second vendor changes more than the table

| File | Change outside `ADAPTERS` | Scope |
| --- | --- | --- |
| `lib/tower_msg.py` | Change `register()` and its record field to accept `address`. Keep `adapter_for()`'s vendor lookup and `wake` gate unless the new channel needs different qualification. Change `deliver_queued()` only for a transport that cannot use the argv subprocess contract. Add receipt handling for durable acknowledgement. | Registration, conditional delivery, receipt |
| `bin/tower-register` | Add `--address`, preserve `--thread`, and pass the selected value to `register()`. | Registration |
| `bin/tower-agents` | No change for an address alone. It prints `wake`, not `thread`, and reads counts from `list_agents()`. | None |
| `tests/msg_test.sh` | Cover the new registration input, vendor transport, state transitions, and existing `--thread` behavior. Replace the stub argv assertion only for a callable transport. | Registration and delivery |
| `tests/agents_test.sh` | Extend its registry and `wake` assertions for a qualifying second vendor. Its current native case registers Codex with `thread`. | Registration |
| `docs/agent-messaging/contract.md` | Reconcile its proposed `socket` and `adapters` registry fields with implemented `thread` and `wake`, or the proposed `address` field. Keep `submitted` distinct from acknowledgement. | Contract |
| `lib/tower-dispatch.sh` | Extend `prepare_launch()` beyond its Claude and Codex launch arguments. This is launch-side work, outside the messaging table. | Second dispatched vendor |
| `bin/tower-dispatch` | Extend `case "$VENDOR" in claude\|codex)` validation. This is launch-side work, outside the messaging table. | Second dispatched vendor |

**Recommendation: generalise when a second vendor passes the contract.** This trigger defines a measured reason to change and an intended shape: opaque address, then a helper executable before a callable. It gives a future change more direction than leaving the table as it is.

The strongest argument against waiting is the missing receipt slot for Codex, the live adapter. Waiting leaves that known gap in place. One change could add receipt handling and `address` together. But `native-channels.md` measured receipt only in Codex's native rollout, whose format and path stability remain unverified. A receipt slot has no supported source to call yet.
