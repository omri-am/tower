# Distribution and version awareness

Status: approved design, not yet implemented.
Date: 2026-08-27

## Problem

Tower is shared today by `git clone` + `install.sh`. Every new feature requires each user to
remember to `git pull`. Nothing tells a user that a newer tower exists, so installs drift
silently and a stale session can misread a `.tower/` file written by a newer one.

Two requirements:

1. Share tower with other people so that features reach them without a manual pull.
2. Make an install aware of newer versions and surface a notice, the way Claude Code prints
   `update available! run: brew upgrade claude-code` above its input box.

## Chosen approach

Distribute tower as a Claude Code plugin, with a shim-based PATH bootstrap for its shell
commands.

Rejected alternatives:

- **Plugin only, commands exposed as slash commands.** Fully automatic, zero install steps,
  but removes shell usage and breaks tower's vendor-neutral claim: a codex implementor gets
  nothing from a Claude Code plugin.
- **Homebrew tap.** Matches the `brew upgrade` UX exactly, but needs a tap repo, a formula
  and per-version release tarballs, and skills still need linking into `~/.claude/skills`.
  Most infrastructure for the least gain, given plugin infrastructure already exists.

The plugin route wins because Claude Code already solves both requirements for plugins: it
keeps a marketplace clone updated, installs into a per-version cache directory, and records
the installed version and commit sha in `~/.claude/plugins/installed_plugins.json`.

## Constraints observed

- `statusLine` is a single global setting and is already occupied in this owner's
  `~/.claude/settings.json`. A plugin cannot add a second line above the input box, so the
  literal Claude Code notice placement is not reproducible. SessionStart `additionalContext`
  is the closest equivalent inside a Claude session.
- `bin/tower-locate` stdout is parsed by every other tool. It must not gain any new output.
  All notices go to stderr, and `tower-locate` itself gains no notice call.
- No new runtime dependency is mandatory. `jq` is used when present and has a fallback.
- Platform is macOS first. `sort -V` is not available reliably, so semver comparison is
  implemented in bash.

## Components

### 1. Plugin manifests

Repo becomes its own single-plugin marketplace. Existing layout (`skills/`, `hooks/`,
`templates/` at root) already matches the plugin convention; no files move.

New files:

- `.claude-plugin/marketplace.json` — marketplace `tower`, one plugin entry
  `{ "name": "tower", "source": "./" }`, owner block matching the repo owner.
- `.claude-plugin/plugin.json` — `name: tower`, `version`, description, repository,
  license. This `version` field is the single source of truth for the tower version.

Install, once per consumer:

```
/plugin marketplace add omri-am/tower
/plugin install tower@tower
```

`hooks/hooks.json` ships exactly one hook: the SessionStart version notice (component 4).
The implementor Stop hook and SendMessage guard stay copy-paste entries in
`hooks/settings-snippets.json`, installed per target project. They are per-project by
nature and `hooks/README.md` already commits to never auto-installing them.

`install.sh` is unchanged and remains supported as the vendor-neutral route.

### 2. Skill namespacing difference

Plugin skills are namespaced by plugin name: tower's skills resolve as
`tower:tower-orchestrator`, `tower:tower-implementor` and `tower:tower-flush` for plugin
users, and as the bare names for `install.sh` users.

`bin/tower-dispatch` and `bin/tower-orchestrate` build prompts that name the skill to
invoke. Those prompt strings gain a parenthetical covering both forms, for example
`Invoke the tower-implementor skill (listed as tower:tower-implementor when tower is
installed as a plugin)`. `PROTOCOL.md` and `README.md` note the same difference once.

### 3. PATH bootstrap via a resolver shim

The plugin cache path is version-qualified — the observed layout is
`~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/`, so tower's installs land in
`~/.claude/plugins/cache/tower/tower/<version>/`. A symlink pointing into it dangles on the
next `/plugin update`. Indirection through a mutable registry solves this the way `rbenv`
and `pyenv` shims do.

`bin/tower-bootstrap` (idempotent):

1. Copies `bin/tower-shim` to `~/.local/libexec/tower-shim`.
2. Creates one symlink per user-facing command in `~/.local/bin`, each pointing at that
   single shim copy.
3. Prints the PATH line if `~/.local/bin` is not already on PATH.

`bin/tower-shim` dispatches on its own basename and resolves the live tower root at call
time, in order:

1. `TOWER_ROOT`, if set and containing `bin/` — the development and worktree override.
2. `~/.claude/plugins/installed_plugins.json`, the `installPath` recorded for
   `tower@tower`. Parsed with `jq` when available; otherwise the highest-semver directory
   under `~/.claude/plugins/cache/tower/tower/` is used. The fallback disagrees with the registry
   only when a consumer has deliberately pinned an older version while a newer cache
   directory remains on disk — accepted, and documented.
3. The shim's own real path resolved to `../bin`, which covers a plain checkout.

Then it calls the version check (component 4) and `exec`s
`<root>/bin/<basename> "$@"`.

A version bump changes only what step 2 reads. No symlink is rewritten and no re-bootstrap
is needed. The shim is the single copied file that can go stale, so it deliberately holds no
logic beyond resolve-and-exec.

Commands that get a shim: `tower-init`, `tower-orchestrate`, `tower-dispatch`,
`tower-watch`, `tower-learnings`, `tower-pr-wait`, `tower-notify`, `tower-locate`,
`tower-version-check`, `tower-bootstrap`. Internal call sites that resolve siblings by
absolute path (`tower-orchestrate` calling `tower-locate`) continue to bypass the shim.

`commands/tower-bootstrap.md` exposes the bootstrap as `/tower-bootstrap`, so a plugin user
with nothing on PATH yet can run it from inside Claude Code.

### 4. Version check

`bin/tower-version-check` holds the entire mechanism. Both surfaces are thin callers.

Local version: `version` from `<root>/.claude-plugin/plugin.json`.

Latest version: highest semver tag from `git ls-remote --tags <remote> 'v*'` — one network
call, no clone, and it does not disturb the marketplace clone Claude Code maintains. The
remote URL comes from `~/.claude/plugins/known_marketplaces.json` for the `tower`
marketplace, falling back to `git remote get-url origin` in the tower root. Both work for a
private repo over SSH.

Caching and non-blocking behaviour:

- Cache file `${XDG_CACHE_HOME:-$HOME/.cache}/tower/version-check`, holding the check epoch
  and the latest version seen.
- The notice is always printed from cache, never from a live call, so no command ever waits
  on the network. Staleness is bounded by the TTL.
- TTL default 86400 seconds, overridable with `TOWER_VERSION_CHECK_TTL`.
- On an expired TTL the refresh is spawned detached, guarded by an `mkdir` lock in the cache
  directory, so ten commands in a row spawn one fetch rather than ten.
- The script always exits 0. An unreachable network, a missing `jq`, an absent cache or an
  unparseable manifest all print nothing and break nothing.
- `TOWER_NO_VERSION_CHECK=1` silences it entirely.
- Run directly, it performs a synchronous check and reports even when up to date, so a user
  can ask the question on demand.

Notice text, stderr, one line:

```
tower: 0.4.0 available (you have 0.3.1) -> /plugin update tower@tower
```

For a root resolved from a plain checkout rather than the plugin cache, the suggested
command is `git pull` instead.

Surfaces:

- **Shell** — `tower-shim` calls the check before `exec`. One call site covers every
  shimmed command. The pre-exec call is skipped when the target is `tower-version-check`
  itself, and `tower-version-check` reaches `tower-locate` through `<root>/bin/tower-locate`
  rather than through PATH. Both are required: a shimmed `tower-locate` invoked from inside
  the version check would re-enter the check and recurse without terminating.
- **Claude session** — `hooks/tower-version-notice.sh`, registered as a SessionStart hook in
  `hooks/hooks.json` and invoked through `${CLAUDE_PLUGIN_ROOT}`, emits the same string as
  `hookSpecificOutput.additionalContext`. It prints nothing when there is no update, so a
  current install costs no tokens.

Plain-checkout users get the SessionStart notice only if they install the hook manually; the
shell notice requires the shim. This is documented rather than worked around.

### 5. Protocol version, tracked separately

A tower version bump on every feature would mark every existing project stale immediately,
so the `.tower/` file format carries its own counter.

- `PROTOCOL_VERSION` at repo root: a single integer, bumped only when a card, handoff,
  learnings or design file format changes in a way an older session misreads.
- `tower-init` writes `.tower/version` recording both the tower version that scaffolded the
  project and the protocol integer at that time.
- `tower-version-check` compares the integer against the running tower's `PROTOCOL_VERSION`
  and, on mismatch, prints a second stderr line naming both values. It locates the project
  with `tower-locate --quiet` and stays silent when no project is found.
- No automatic migration. A wrong migration corrupts a project's audit trail, which is worse
  than a warning a human acts on.

`.tower/version` is written by `tower-init` directly and gets no entry in `templates/`. The
template directory holds markdown documents a human or an agent edits; a two-field machine
record does not belong there.

### 6. Release process

1. Bump `version` in `.claude-plugin/plugin.json`.
2. Add the entry to `CHANGELOG.md`.
3. Tag `vX.Y.Z` matching that version exactly, and push tag plus commit.

`CHANGELOG.md` is new and load-bearing for the requirement: `0.4.0 available` alone does not
tell anyone which feature landed.

Tag and manifest drift breaks the notice silently, since the notice compares a manifest
against a tag. `scripts/tower-release` does the bump, changelog heading and tag in one step
to prevent that drift, and refuses to run on a dirty tree or when the tag already exists.

Consumers are advised to leave `autoUpdate` off for the tower marketplace. Skills mutating
mid-session is safe for a skills library; it is not safe for tower, where a live orchestrator
rehydrates from `.tower/` files whose templates could change underneath it. Notice-then-
manual-update is the documented default.

### 7. Documentation changes

`README.md` gains a plugin install section as the recommended route, keeps the clone route
for non-Claude agents, documents the version notice and its two environment variables, and
states the `autoUpdate` recommendation. `PROTOCOL.md` gains the protocol-version rule and
`.tower/version`. `hooks/README.md` gains the version-notice hook and states that it is the
only auto-installed hook.

## Testing

The repo has no test directory and no test framework today. None is introduced. Tests are
plain bash asserts under `tests/`, dependency-free, runnable individually and from one
`tests/run.sh`, covering the paths where a bug is silent rather than loud:

- Semver comparison: equal, patch, minor, major, differing component counts, non-numeric
  and empty input.
- Cache behaviour: fresh cache prints from cache and makes no network call; expired TTL
  triggers exactly one refresh under the lock; a held lock suppresses further refreshes.
- Failure containment: unreachable remote, absent cache file, malformed cache, malformed
  `plugin.json`, and `jq` absent — each exits 0 and prints nothing.
- Shim resolution: `TOWER_ROOT` override wins; registry path is used next; a registry
  entry pointing at a missing directory falls through to the cache glob; a plain checkout
  resolves through its own path; the basename dispatch reaches the right command with
  arguments and exit status preserved.
- Protocol mismatch: equal integers stay silent, differing integers warn once, missing
  `.tower/version` stays silent.
- `tower-locate` stdout is byte-identical with the version check enabled and disabled.

Verified by hand, not automated: the real `/plugin marketplace add`, `/plugin install` and
`/plugin update` round trip, and the SessionStart hook firing in a live session.

## Out of scope

Automatic `.tower/` format migration, a Homebrew tap, npm publication, non-Claude plugin
manifests (`.codex-plugin` and similar), and multi-plugin marketplace layout.
