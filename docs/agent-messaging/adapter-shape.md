# A second vendor fits the adapter table if one command can reach it

For messaging, yes: `register()` and `deliver_queued()` accept a channel that one command keyed by one string can reach. For dispatch, no: `bin/tower-dispatch` accepts only `claude` and `codex`. A hosted channel, receipt handling, or an in-process transport needs more work.

## Registration already carries any one-string address

`register()` stores `thread` unchanged. Only the adapter's `qualifies` and `command` interpret it. `--thread` is `bin/tower-register`'s only vendor-specific flag, but it accepts any string. `tests/msg_test.sh` registers `exact session name`. By inference, another adapter could use the string as a socket path or port.

`native-channels.md` measured Claude stream-JSON input through its hosted `--print` process's stdin pipe. The Codex probe hosted app-server over `--stdio`. Neither pipe belongs to a later `tower send` process. Both fail reach into an existing TUI and change who owns the human interface. By inference, tower would need to own a host process exposing a local endpoint. Its path fits the existing string. `contract.md` proposed `socket` for a PTY relay, but M0 gave shared-terminal typing **no-go**.

The smallest naming change is an opaque `address` field and `--address` flag, with `--thread` as an alias. A call with both flags fails. This changes names, not capability. Keep `--thread` because `thread-identity.md` (T031, unmerged when this was written) recommends passing the main agent's `CODEX_THREAD_ID` to `tower-register --thread`. That value equalled its notify `thread-id` on codex-cli 0.159.3. A rename needs a compatibility read for live `thread` records, since `tower-register` keeps them until exit.

## Delivery fits one command but not every transport

`deliver_queued()` runs any argv returned by `adapter['command']`. Exit 0 moves `claimed` to `submitted`. It maps timeout to 124, interruption to 130, and `OSError` or `ValueError` to 127. Failure requeues or retires the claim.

By inference, a helper executable could convert a socket write, HTTP or JSON-RPC call, or file drop to one argv command. A file drop needs a defined successful submission, such as atomic publish. `native-channels.md` says Claude stream-JSON can wake its own hosted print/SDK session. By inference, an in-process transport would call that SDK as a library inside `tower send`. It needs a callable with a submission outcome and error.

Codex app-server `turn/start` and `turn/steer` are measured JSON-RPC examples in `native-channels.md`. `turn/start` wakes a hosted thread, and `item/started` later carries receipt on the same connection. `turn/steer` fails idle wake. Both fail reach into a live TUI because `thread/resume` reports an active writer. The probe did not use the request response as receipt.

By inference, an argv helper reports only exit status. Even if it waits for `item/started`, `deliver_queued()` can only mark `submitted`. It has no path for receipt handling. Codex `queue` exit 0 means enqueued, not received. Mapping exit 0 to `submitted` matches `contract.md`, which requires separate acknowledgement.

`tests/msg_test.sh` runs real `bin/tower send` with a stub `codex` on `PATH`. It checks four argv fields exactly and the message's envelope prefix and body suffix. By inference, an in-process callable needs a fake transport or local endpoint, equivalent state checks, and bounded I/O. By inference, it loses the executable-boundary test. `subprocess.run` kills a timed-out child after 30 seconds, bounding one command's hold on `delivery.lock`. `deliver()` holds the batch lock. `CHANGELOG.md` documents that a killed sender can leave an adapter command running after recovery requeues the claim. By inference, an in-process transport dies with its sender unless it starts independent work.

## A second vendor channel can require changes outside the table

| File | Change outside `ADAPTERS` | Scope |
| --- | --- | --- |
| `lib/tower_msg.py` | Rename `thread` in `register()` and records for non-thread input, with a live-record read. Change `deliver_queued()` for callables. Add receipt handling when supported. | Conditional |
| `bin/tower-register` | Add `--address` and keep `--thread` as an alias only with that rename. | Conditional |
| `bin/tower-agents` | No change. It prints `wake`, not `thread`. | None |
| `tests/msg_test.sh` | Update `record['thread'] == thread` with the rename. Cover the new adapter. | Conditional and new vendor |
| `tests/agents_test.sh` | Update `register(..., thread='thread-1')` with the rename. | Conditional |
| `docs/agent-messaging/contract.md` | Reconcile `socket` and `adapters` with `thread` and `wake`. State native and typing go rules. | Already needed for Codex |
| New host command in `bin/` | Own the vendor process and expose an endpoint. No such command exists today. | Hosted channel only |
| `bin/tower-bootstrap` | Add the host command to `COMMANDS`, as `tests/shim_test.sh` requires. | Hosted channel only |
| `lib/tower-dispatch.sh` | Extend `prepare_launch()` for vendor arguments. Start the host command for a hosted channel. Launch-side, outside the table. | Launch |
| `bin/tower-dispatch` | Extend `case "$VENDOR" in claude\|codex)` validation. Launch-side, outside the table. | Launch |
| `PROTOCOL.md` | Extend the card template's `vendor: any # claude \| codex \| any`. | Launch |
| `docs/REFERENCE.md` | Extend its `--vendor claude\|codex` flag table. | Launch |
| `tests/dispatch_test.sh` | Cover the new dispatched vendor beyond Claude and Codex. | Launch |
| `changelog.d/<task-id>.md` | Add a fragment for any `bin/` or `lib/` change, per `docs/REFERENCE.md`. | Changed code |

## The adapter table needs no planned generalisation

A rename clarifies non-thread input. Codex `queue` alone passed native wake for a live TUI in `native-channels.md`. Claude stream-JSON input has Reach **fail** for a live TUI because `--print` starts its own session. `compatibility.md` calls Claude shared-terminal typing **no-go** because items 1, 2, 3, and 6 remain unproven. `hook-wake.md` gives Claude FileChanged idle wake **cannot determine** under its quota limit. Its model-context exclusion is documented, not measured.

A second vendor channel should pass all five `native-channels.md` items for a live interactive session on an exact version: reach, wake from idle, busy delivery, receipt signal, and human coexistence. Codex `queue` passed on 0.158.0, with receipt API risk and human coexistence limited to the observed draft. By inference, the `contract.md` go rule (items 1, 2, 3, 5, and 6) governs shared-terminal typing. Codex used native-channel evidence although `compatibility.md` marked typing item 3 **fail**.

**Recommendation: leave the table as it is.** A passing channel reaches its session through one command and one string, which the table already carries. No generalisation step follows from that pass. Its vendor card adds one table entry and changes outside code only when its measured channel needs it.

The strongest argument against this recommendation is missing receipt handling for Codex, the live adapter. By inference, vendor-specific sources like Codex's rollout and app-server `item/started` favor a per-adapter receipt key in `ADAPTERS` now. Yet `native-channels.md` measured Codex TUI receipt only in the native rollout, whose format and path stability remain unverified. Receipt handling has no supported source yet.
