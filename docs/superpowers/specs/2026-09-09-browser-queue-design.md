# Browser task queue

Tower's owner reviews 10–30 tickets daily. `tower-ui` opens a local, single-project workspace with a searchable grouped queue beside the complete selected card. Needs approval contains drafts; Ready to dispatch contains ready cards that pass the CLI preflight; Waiting contains ready cards with blockers and blocked cards. Active and merged work remains available through an All cards filter.

The browser preserves selection, filter, and reading position during refresh. It displays complete card content without generating summaries. Approve changes draft to ready and commits only that card. Dispatch invokes the existing terminal launch workflow. Both actions require the revision displayed to the owner; changes to the card or prompt reject the action and require renewed review. Dispatch retains its existing shared lock and repeats eligibility checks under that lock. Approval uses the same lock. Failed approval commits restore the previous card and preserve unrelated staged files.

The server binds only to 127.0.0.1 on an automatically allocated port, serves bundled assets without external requests, validates Host and Origin, and requires a per-session token for API access. It accepts fixed action names and card IDs, never arbitrary commands or filesystem paths. Task contents render as text, not executable HTML. Action results persist visibly until dismissed or replaced. Failed terminal launches report the actual card status and recovery guidance; the browser never automatically resumes a session.

The optional server runtime uses the proposed Python 3.9+ standard library, with vanilla HTML/CSS/JavaScript and no third-party packages. Existing CLI requirements remain unchanged. Browser dispatch initially supports sidecar worktrees; tracked-state projects can read and approve cards, and receive explicit guidance to use CLI in-place dispatch.

Layout: left-aligned 22rem queue, flexible detail pane, persistent action footer. Below 760px, stack the panes. Colors: canvas #edf2f7, paper #ffffff, ink #23364b, secondary #52677e, action #245cb0, waiting #875c15. System sans-serif for navigation; a system monospace face only for code. No web fonts or decorative animation.

Verification covers real Git fixtures, read-only listing, blockers, stale actions, scoped commits, shared locks, dispatch worktree creation, HTTP request isolation, and browser interactions at desktop and narrow widths. Real paid agent execution is outside automated testing.

Readiness is derived and cached, with project-wide invalidation on card/prompt revisions, local branches, the state index, or the dispatch lock. Initial classification uses up to four concurrent read-only CLI preflights. Action validation never uses the cache.


## Owner feedback and state colors

The owner requested persistent comments and stronger visual distinction between states.
Comments live in `.tower/comments/<task-id>/<UUID>.md`, one immutable Markdown record per
submission, with `author: owner`, `created_at` (UTC), and `card_revision` frontmatter.
They are individually committed under the existing action lock, preserve unrelated staged
work, and leave card scope/status unchanged. The POST /api/comment endpoint takes id,
revision, comment_id, and text; reusing a comment ID with identical contents is idempotent.
Blank comments and comments exceeding 10,000 characters are rejected. Rendering treats
comment text literally. Unsent drafts survive refresh and card switching for the current
page. Comments refresh independently of the selected card's revision. The orchestrator
reads feedback on rehydration and its normal loop; posting does not start or notify agents.

Blue approval, green dispatchable, amber waiting, purple active, gray merged, and red
attention colors are applied consistently to headings and badges. Labels remain visible,
and dependency-blocked ready cards display Waiting in the browser.

## Kanban follow-up

The owner also requested a Kanban view alongside Queue. It starts with all cards and
splits active work into In flight and In review columns. In review uses teal, superseding
the shared purple active color for that status; In flight remains purple. Each column
heading folds its cards into a narrow rail with its title and count still visible.
The browser tab remembers folded columns and the selected view across reloads.
Clicking a card opens the shared detail pane in a dialog, preserving comments and explicit
approval/dispatch actions. Escape closes the dialog and restores focus to the card.
There is no drag-and-drop status mutation. Both views use the same five-second polling.
