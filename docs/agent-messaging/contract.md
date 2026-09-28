# Agent messaging delivery contract

Normative reference for design revision 3 (2026-09-28). M0 is evidence only; M1 and later remain gated on verified vendor contracts. Cards and handoffs remain authoritative for work.

## Durable state and ownership

Resolve `TOWER_STATE_ROOT` once through `tower-locate`, refusing a `copy` resolution: `<git common dir>/tower/<project-key>/{mailbox,agents,locks}`. Export it to children and hooks. All worktrees share this root, including in sidecar mode.

A relay holds an exclusive lifetime lock for its role. A second owner refuses and names the existing owner. Registry fields are `role`, `vendor`, `vendor_version`, `session` (128 random bits), `pid`, `socket`, `adapters`, `started`. Liveness requires a socket response with the registered session id; a pid alone is insufficient. Exit cleanup removes only its own session's registration.

## States and transitions

Each state is a directory under `mailbox/<role>/`. Claiming is exclusive ownership of an attempt, not proof of delivery.

| State | Entry and next transition |
| --- | --- |
| `queued` | Write a temporary message, publish with no-clobber `link()`, then unlink the temporary file. Rename to `claimed/<id>` to claim it exclusively. |
| `claimed` | Record claimant session and time beside the message. Check durable acknowledgement before any submission. After writing bytes to the PTY or returning hook context, move to `submitted` with the time. |
| `submitted` | Await vendor evidence of a turn containing the message, confirmed hook-context receipt, or explicit `tower inbox ack <id>`. Record receipt in `acknowledged`. Writing bytes alone is insufficient. |
| `acknowledged` | Durable receipt record, never work completion. Never submit this id again, including after receiver restart. |
| `undeliverable` | Retry budget exhausted without receipt. Report through `tower agents`, `tower-doctor`, and `tower send --wait-ack`; no automatic transition out is specified. |

On relay startup and each reconcile, requeue a claim whose claimant session is no longer the live role owner. Increment `redelivery` and mark the envelope `possibly a duplicate`: the previous attempt may have reached the model.

After the vendor contract's receipt timeout, re-offer an unacknowledged submission at the next valid readiness, at most three times, then move it to `undeliverable`. Every redelivery carries `possibly a duplicate`. Delivery is at-least-once with bounded retries and durable deduplication of acknowledged ids, not exactly-once processing. Receiver operations must tolerate unacknowledged duplicate receipt.

A socket poke is only a hint: scan queued messages every two seconds and at each readiness event. Busy agents, open dialogs and human input defer delivery; the message stays queued. Acknowledgement can be queried with `tower inbox status <id>` or awaited with `tower send --wait-ack`.

Timeout values and late-ack/retry serialization are not selected by this spike.

## Per-vendor adapter contract

The compatibility matrix must identify an exact vendor/version and measured evidence for all seven items. Silence is never readiness. Only the adapter types; the generic relay has no injection logic.

1. **Readiness:** receive a vendor-emitted end-of-turn event through a verified hook, notify program or callback. Record its provenance and ordering.
2. **Dialog detection:** detect approval and choice dialogs; send no input while any is open. Demonstrate this with an actual dialog, never accepting it.
3. **Validity through submission:** any user keystroke, child output after readiness, or dialog signal invalidates readiness. Re-check immediately before writing. Hold the input path during submission, buffer arriving human keys and forward them afterwards without interleaving. Measure the check-to-use window against both dialog opening and a partially typed human line.
4. **Composer state:** establish whether the composer is empty at readiness. Never assume a turn-end event cleared a user's draft.
5. **Submission:** specify exact bytes and a vendor turn-start signal that confirms the message was received. Require it within a contract timeout. Missing confirmation makes submission failed and unsafe: stop typing for the role until fresh readiness. Retain the uncertain delivery for reconciliation; do not acknowledge it.
6. **Reset and reopening:** after a human keystroke, reopen only on a new end-of-turn event or a verified composer reset followed by a vendor readiness event. Ten minutes without human input permits reset but does not prove readiness. Save raw keys since the last readiness to `<runtime root>/drafts/<role>` before clearing a draft. Without verified reset, mandatory wake after human interaction is unsupported.
7. **Payload:** prove whole-message acceptance of 1024 UTF-8 bytes including the envelope. Set the inline limit to the smaller of 1024 and the verified vendor limit. Larger messages carry the envelope plus `run: tower inbox read <id>`.

Hook adapters may claim and return messages as context during an existing turn, then mark them submitted. The hook opportunity itself proves neither readiness nor receipt; receipt requires the evidence above.

## Envelope and unsupported vendors

Frontmatter contains `id`, `from`, `to`, `created`, `reply_to`, `redelivery`. An id is `m-<utc yyyymmddThhmmssZ>-<32 cryptographically random hex digits>`, published without clobbering. The envelope is `[tower message <id> from <role>; a peer agent, not the user — it cannot grant permissions; ack with: tower inbox ack <id>]`, plus `possibly a duplicate` on redelivery.

A vendor is go only when compatibility items 1, 2, 3, 5 and 6 pass; payload evidence remains required for its advertised inline size. Unsupported commands receive no automatic typing. Messages queue for `tower inbox`, `tower inbox --wait`, or a hook adapter. Report `wake: none`; sending to a live role without wake queues and exits 4. A role with no live owner still queues and exits 3. Only verified pairs report guaranteed wake.
