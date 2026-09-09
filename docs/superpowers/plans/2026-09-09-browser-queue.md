# Browser queue implementation plan

**Goal:** Review, approve, and dispatch daily task cards through an optional local browser workspace.

**Architecture:** A local server adapts file state and the existing Bash dispatch command to a fixed JSON API. Bundled browser assets provide the queue and complete-card reader.

**Spec:** ../specs/2026-09-09-browser-queue-design.md

## Constraints

Bash 3.2 compatibility for existing commands. No third-party packages. Optional server runtime discussed with the owner. Preserve card content and unrelated staged changes. No agent launches from tests; substitute only the external terminal boundary.

## Execution

- [x] Add real fixture tests in `tests/ui_test.py` and a suite wrapper in `tests/ui_test.sh`: empty state; full card content; dependency, prompt, ownership blockers; stale approval and dispatch; scoped approval commits; shared locks; actual dispatch status and worktree effects; HTTP authorization and request validation.
- [x] Add `bin/tower-ui`, `lib/tower_ui.py`, and `lib/tower_ui_server.py` for project discovery, data adaptation, guarded approval, and loopback HTTP. Extend dispatch with an optional expected revision checked under its existing lock.
- [x] Add `web/index.html`, `web/tower.css`, and `web/tower.js`: grouped queue, full titles, search and All cards filter, full card reader, explicit actions, retained selection, refresh, loading/errors, keyboard navigation, responsive layout.
- [x] Register the command in bootstrap, document usage and runtime in README/reference, and update the Unreleased changelog and orchestrator browser approval guidance.
- [x] Run the focused tests, complete shell suite, syntax/static checks, and desktop/narrow browser checks. Review the final diff and record remaining integration limitations.

The 30-ready-card load check exposed repeated ownership scans. Dispatch now selects active ownership cards in one scan; browser readiness runs four read-only checks concurrently and caches results until card/prompt revisions, local branches, the state index, or the dispatch lock change. Final local measurements: 3.28 seconds initial load and 0.29 seconds unchanged refresh.

- [x] Owner-requested follow-up: persistent per-card comments with scoped commits, idempotent retry, revision checks, retained in-page drafts, orchestrator read guidance, and accessible state colors on headings and badges. Browser checks covered posting, switching cards, completed refresh retention, and narrow layout; backend checks cover failure rollback, interrupted-save recovery, and path isolation.

- [x] Owner-requested Kanban view: separate workflow columns, collapsible headings remembered per tab, shared card/comment dialog, retained per-view filters, and distinct purple In flight / teal In review colors. Browser checks covered folding, reload persistence, draft retention between views, Escape focus restoration, and 390px layouts.
