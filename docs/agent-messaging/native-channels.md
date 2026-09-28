# M0b native input channels

Measured on macOS on 2026-09-28, in fresh `mktemp -d` directories outside the repository. The throwaway [queue](native-probes/codex_queue.py), [app-server](native-probes/app_server.py), and [Claude stream](native-probes/claude_stream.py) probes use Python 3.9+ standard library only. They used GPT-6-Luna and Haiku 4.5, accepted only the Codex scratch-directory trust prompt, and approved no tool, permission, or choice dialog. Scratch logs remain under `/tmp`-equivalent macOS temporary roots; excerpts below give their decisive records. A **pass** establishes the observed version and path, not a future-version contract. Receipt means entry into a turn, never completion of requested work.

## Codex CLI 0.158.0: `codex queue`

| Item | Verdict | Probe and log excerpt |
| --- | --- | --- |
| Reach | **pass** | `codex_queue.py`, run Q3: interactive TUI `session_meta.id=01a0e7e7-2172-7491-8fea-d1bd3ff4ebaa`; separate `codex queue --thread ...` returned `Queued message ... for thread ...`. Its rollout recorded the queued text as a user item. |
| Wake from idle | **pass** | Q3: `task_complete QUEUE_INITIAL` at `12:04:43.909Z`; `queue_idle` returned 0 at `12:04:43.98Z`; `task_started` at `12:04:46.347Z`, then native user record `Reply QUEUE_IDLE. No tools.` at `12:04:46.611Z`. |
| Busy delivery | **pass** | Q3: `queue_busy` returned 0 at `12:04:48.42Z` while `QUEUE_BUSY` ran (`task_started 12:04:48.320Z` to `task_complete 12:04:59.673Z`); a new `task_started 12:04:59.688Z` contained `Reply QUEUE_DURING_BUSY. No tools.` Queued, not steered. |
| Receipt signal | **pass**, with API risk | Q3 native rollout paired `task_started` with exact `response_item` user payload and turn id. Queue's own `Queued message ...` output is acceptance into the queue, not receipt. The rollout is an on-disk internal record; its format/path stability is unverified. |
| Human coexistence | **pass** for observed draft | Q3 wrote `HUMAN_DRAFT_é` to the TUI during `QUEUE_BUSY`, then sent via queue. The subsequent native user record was exactly `Reply QUEUE_DURING_BUSY. No tools.`; no draft text entered that turn. This does not prove every TUI editing path. |

**Codex recommendation:** a native `queue` adapter **can meet** the measured wake guarantee for an interactive TUI on 0.158.0. Before advertising a durable acknowledgement contract, validate how an adapter will consume the native rollout receipt and detect format changes. The queue command's exit alone cannot acknowledge delivery.

## Codex CLI 0.158.0: app-server `turn/start`

| Item | Verdict | Probe and log excerpt |
| --- | --- | --- |
| Reach | **fail** for a live TUI | `app_server.py` run A2 sent `thread/resume` for live TUI thread `01a0e7e2-dd8a-7912-984f-5e4e012a6b61`; response: `thread ... already has an active writer`. A1's `thread/start` created its own thread. |
| Wake from idle | **pass** in hosted thread | A1 sent `turn/start` with `Reply APP_WAKE. No tools.` after the prior `turn/completed`; it received `turn/started`, exact `item/started` user content, and `turn/completed` with `APP_WAKE`. |
| Busy delivery | **pass**, steered | A3 sent `turn/start` with `Also include APP_START_BUSY.` during active turn `01a0e7e6-1d5f-7e01-a4d3-30334a949a70`; response returned that same turn id, and `item/started` carried the text in that turn. Final answer included `APP_START_BUSY`. |
| Receipt signal | **pass** in hosted thread | A1's `item/started` contained `Reply APP_WAKE. No tools.` and the same `turnId` as `turn/started`; this is a streaming event on the connection. |
| Human coexistence | **fail** for existing TUI | A2's active-writer rejection prevents this separate app-server client from delivering into that TUI. A host could multiplex human and agent requests on its own connection; that architecture was not probed. |

## Codex CLI 0.158.0: app-server `turn/steer`

| Item | Verdict | Probe and log excerpt |
| --- | --- | --- |
| Reach | **fail** for a live TUI | A2's `thread/resume` active-writer error also blocks obtaining the TUI's active turn for `turn/steer`. |
| Wake from idle | **fail** | A4 sent `turn/steer` with the just-completed turn id while idle; response `-32600: no active turn to steer`. The installed 0.158.0 schema requires an active `expectedTurnId`. |
| Busy delivery | **pass** in hosted thread | A3 sent `turn/steer` for active turn `01a0e7e6-1d5f-7e01-a4d3-30334a949a70`; response carried that `turnId`, then `item/started` recorded `Also include APP_STEER in the reply.` in the same turn. Final answer: `APP_BUSY APP_START_BUSY APP_STEER`. |
| Receipt signal | **pass** in hosted thread | A1 `item/started` and `item/completed` gave the exact steered user text and active `turnId`; the request response alone was not used as receipt. |
| Human coexistence | **fail** for existing TUI | A2 could not join its live writer. In a hosted thread the transport is separate from terminal keystrokes, but human multiplexing was not exercised. |

**Codex app-server recommendation:** `turn/start` plus `turn/steer` **cannot meet** the wake guarantee for a human's already-running TUI through a second app-server writer. They can meet wake and receipt in a session hosted by the app-server client; adopting that would change who owns the human interface.

## Claude Code 2.1.283: stream JSON input with replay

| Item | Verdict | Probe and log excerpt |
| --- | --- | --- |
| Reach | **fail** for a live TUI | `claude --help` says `--input-format stream-json` works only with `--print`. `claude_stream.py` run C created its own `system/init` session `1fc26364-dcae-4565-8827-6535ad9295fc`, rather than attaching to an interactive TUI. |
| Wake from idle | **pass** in hosted process | C sent `CLAUDE_WAKE` after `result CLAUDE_IDLE`; stdout replayed the exact second user content, then emitted assistant text and `result CLAUDE_WAKE` under the same session id. |
| Busy delivery | **pass**, queued | C sent `CLAUDE_STEER` after replay of `CLAUDE_BUSY` and before its result. `result CLAUDE_BUSY` preceded replay of `CLAUDE_STEER`, which then received its own result. This did not steer the active turn. |
| Receipt signal | **pass** in hosted process | With `--replay-user-messages`, C's `type:user` event carried the exact content `Reply CLAUDE_WAKE. No tools.` and session id. A result later confirmed model execution. |
| Human coexistence | **fail** for existing TUI | The input pipe belongs to the `--print` process, which has no interactive composer. The probe never sent terminal keys; it cannot protect or observe a human draft in another TUI. |

**Claude recommendation:** the stream JSON channel **cannot meet** the wake guarantee for an already-running interactive TUI. It can wake its own hosted print/SDK session; using that path requires a human interface hosted around the stream.

The app-server protocol is documented in [Codex App Server](https://developers.openai.com/codex/app-server); Claude's print hosting is documented in [programmatic usage](https://code.claude.com/docs/en/headless). The installed CLIs' help and generated 0.158.0 schema supplied the version-specific flags and `expectedTurnId` requirement.
