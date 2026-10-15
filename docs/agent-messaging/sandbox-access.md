# Codex permission entries that let a sandboxed agent run tower

Measured on macOS, 2026-10-15, with the real `~/.codex/packages/standalone/releases/0.162.1-aarch64-apple-darwin/bin/codex` (`codex-cli 0.162.1`) and the model `gpt-6-luna`. Each run logged `"version": "codex-cli 0.162.1"` at start and `installed_after` as `0.162.1-aarch64-apple-darwin` at the end. These are results for **codex-cli 0.162.1**, not a general claim about Codex.

The [probes](sandbox-probes/) reuse T038's harness from [`lifetime-probes/common.py`](lifetime-probes/common.py) without edits, so each run used a fresh `~/.cache/tower-t038-probes/tmp.*` fixture with a repository `repo/`, a linked worktree `wt/` and the state root `repo/.git/tower/root`. Every run started from the owner's `workspace` profile (`":minimal" = "read"`, project roots writable, `~/.codex/config.toml:228-232`). The candidate entries were added with one run-only override, because a dotted `-c` key splits a path at its dots: `-c 'permissions.workspace.filesystem={":minimal"="read", ":project_roots"={"."="write"}, "<path>"="read", ...}'`. The probe checks that `config.toml` still holds those two base entries before it builds the override. No run passed `--sandbox`.

[`p1_sandbox_matrix.py`](sandbox-probes/p1_sandbox_matrix.py) runs four commands through `codex sandbox -P workspace --log-denials` in the worktree: `tower --help`, `tower-register --help`, `python3 -c ...`, and a `runtime_root` command that imports `tower_msg` and calls `runtime_root()`. That function runs `tower-locate` and `git rev-parse`, which are the external commands that `register()` runs before it writes. [`p2_live_session.py`](sandbox-probes/p2_live_session.py) runs an interactive TUI under `env -i` with the entries and `--add-dir <git common dir>/tower`.

In this document, **pass** means that the probe observed the behaviour that the question asks about. **fail** means that the probe observed its absence. **cannot determine** means that the probe did not reach the observation. A p1 case passes when all four commands exit 0 and the sandboxed `tower --help` and `runtime_root` output equal the unsandboxed output.

| Question | Verdict | Probe and log excerpt |
| --- | --- | --- |
| 1. Minimal entries | **pass** on codex-cli 0.162.1: 11 read entries, each needed | [`logs/tmp.xSSbUjZK/p1_sandbox_matrix.jsonl`](sandbox-probes/logs/tmp.xSSbUjZK/p1_sandbox_matrix.jsonl): `summary` `"all": "pass"`, `"none": "fail"`, and `"fail"` for each of the 11 `minus-<entry>` cases. Live confirmation in [`tmp.EJwmuOBy`](sandbox-probes/logs/tmp.EJwmuOBy/p2_live_session.jsonl): `tower-help.exit` `"0\n"`, `reg-help.exit` `"0\n"`, `py.out` `"/Users/omriam/.pyenv/versions/3.10.4/bin/python3\n..."`. |
| 2. Registration under the profile | **pass** on codex-cli 0.162.1 | [`logs/tmp.EJwmuOBy/p2_live_session.jsonl`](sandbox-probes/logs/tmp.EJwmuOBy/p2_live_session.jsonl): `"stage": "after_register", "pid": 90167, "pid_exists": true, "lock_held": true, "lock_content_matches_session": true`, `ps` row `90167     1 90167      0 Ss`, `reg.out` `"aa12a1b93d5867cbd5ecef109f217757\n"`. |
| 3. Later tool calls | **pass** on codex-cli 0.162.1 | Same log: `after_call1`, `after_call2` and `after_call3` each show `"pid": 90167, "pid_exists": true, "lock_held": true`. Each call was its own turn. |
| 4. Normal exit | **pass** on codex-cli 0.162.1: the holder still runs and holds the lock | Same log: `tui_exit` `"exited": true, "waitpid_status": 0` after `/quit`, then `holder_after_quit` `"pid": 90167, "pid_exists": true, "lock_held": true, "tui_exited": true`. |

## Question 1: the entries, general form first

The tool call can reach only what its `PATH` names, and that `PATH` comes from the launcher. Each entry below is named by what it is, then by the owner's measured path. A user derives each one from the commands in the first column. Every entry is `"read"`.

| Entry | How to derive it | Owner's measured path | Without it (`tmp.xSSbUjZK`) |
| --- | --- | --- | --- |
| tower's resolved install root | `dirname "$(dirname "$(realpath "$(command -v tower-register)")")"` | `~/Documents/personal-projects/tower` | `tower` exit 71 `execvp() of 'tower' failed`, `tower-register` exit 126 `Operation not permitted` |
| tower's plugin cache | `~/.claude/plugins/cache/tower` | same | all exit 0, but `tower --help` lists the checkout's commands (`agents`, `register`, `send`), not plugin `0.6.0`'s |
| the interpreter's root | `pyenv root`, which holds the shim, the `version` file and `sys.base_prefix` | `~/.pyenv` | `python3` exit 126 `bash: /Users/omriam/.pyenv/shims/python3: Operation not permitted` |
| Homebrew's `opt` links | `$(brew --prefix)/opt` | `/opt/homebrew/opt` | exit 1 `/opt/homebrew/opt/pyenv/bin/pyenv: Operation not permitted` |
| Homebrew's `bin` links | `$(brew --prefix)/bin`, where `command -v git` points | `/opt/homebrew/bin` | `runtime_root` exit 1, `xcode-select: error: No developer tools were found` |
| the shim's program package | `$(brew --prefix)/Cellar/pyenv` | same | exit 1, denial `file-read-metadata /opt/homebrew/Cellar/pyenv/2.8.4/bin/pyenv` |
| each package whose library the interpreter needs at start | from `otool -L` on `realpath` of `sys.executable` | `/opt/homebrew/Cellar/gettext` | exit 134 `dyld[...]: Library not loaded: /opt/homebrew/opt/gettext/lib/libintl.8.dylib` |
| each package whose library `git` needs | from `otool -L "$(realpath "$(command -v git)")"` | `/opt/homebrew/Cellar/pcre2` | `git` `died with <Signals.SIGABRT: 6>` |
| git's system config file | `$(brew --prefix)/etc/gitconfig` for Homebrew git | `/opt/homebrew/etc/gitconfig` | `fatal: unable to access '/opt/homebrew/etc/gitconfig': Operation not permitted` |
| the user's global git config file | `~/.gitconfig` | same | `fatal: unable to access '/Users/omriam/.gitconfig': Operation not permitted` |
| the project's git common dir | `git rev-parse --path-format=absolute --git-common-dir` in the worktree | the fixture's `repo/.git` | `fatal: not a git repository: (null)` |

The last entry depends on the project, not the machine. The fixture's worktree is linked, so its `.git` file points into the common dir outside the worktree. Dispatch already adds `<git common dir>/tower` for writes. For the owner's tower project the common dir is `~/Documents/personal-projects/tower/.git`, inside the first entry. That this alone covers it there is **inference**.

Removing an entry fails for the reason in the last column, and the denials in each `test` event name the path. Git treats an unreadable config file as fatal. So any file that `~/.gitconfig` includes is **inferred** to need an entry too when the include applies. The owner's `includeIf "gitdir:~/Documents/personal-projects/"` did not apply to the fixture, so this was not measured.

Four candidates were not needed. Run [`tmp.L9v1bWzQ`](sandbox-probes/logs/tmp.L9v1bWzQ/p1_sandbox_matrix.jsonl) passed without `~/.config/git` and without `/opt/homebrew/Cellar/git`. Run [`tmp.SJNPb0H1`](sandbox-probes/logs/tmp.SJNPb0H1/p1_sandbox_matrix.jsonl) passed without each of `openssl@3`, `readline` and `xz`, although `otool -L` lists them for `python3.10`. Run [`tmp.3GWaynJl`](sandbox-probes/logs/tmp.3GWaynJl/p1_sandbox_matrix.jsonl) passed without `~/.claude/plugins/installed_plugins.json`. Without that file, `tower` falls back to the newest cached version, which is the same `0.6.0` here. With two cached versions the fallback could differ, which was not measured. Why `git` runs without its package directory, while its libraries need theirs, was not observed. The kernel is **inferred** to load the main executable without the profile's read check.

An entry for a symlink does not open the link itself. In [`tmp.ouqVwros`](sandbox-probes/logs/tmp.ouqVwros/p1_sandbox_matrix.jsonl), the entry `/opt/homebrew/opt/pyenv` still left `file-read-metadata /opt/homebrew/opt/pyenv` denied. Only the directory that holds the link, `/opt/homebrew/opt`, worked. Codex is **inferred** to resolve each entry to its target.

## The launcher's PATH decides what the agent can find

Under the profile, the tool-call shell does not add the user's directories to `PATH`. Codex runs each call as `/bin/zsh -lc`, and the rollout shows `"command":["/bin/zsh","-lc",...]`. Codex also writes a shell snapshot at session start, outside the sandbox, which exports the launcher's `PATH`. With a system `PATH` launcher, [`tmp.TN38cRgr`](sandbox-probes/logs/tmp.TN38cRgr/p2_live_session.jsonl) logged a tool-call `PATH` of Codex's own directories plus `/usr/bin:/bin:/usr/sbin:/sbin`, then `zsh:1: command not found: tower`. With the owner's terminal `PATH`, the same profile found tower but could not run it ([`tmp.xEJAMdPW`](sandbox-probes/logs/tmp.xEJAMdPW/p2_live_session.jsonl): `zsh:1: operation not permitted: tower`).

Dispatch starts Codex with `env TOWER_TASK=... codex` (`lib/tower-dispatch.sh:201`), so a dispatched agent gets the dispatcher's `PATH`. The live runs therefore used `env -i` with the `PATH` of a new terminal login shell, not T038's system `PATH`. A dispatcher whose `PATH` lacks tower gives an agent that cannot find tower with any entries.

`/etc/zprofile` runs `path_helper`, which moves the system directories to the front. In a hand-run `codex sandbox ... /bin/zsh -lc 'command -v python3'` without the snapshot, `python3` resolved to `/usr/bin/python3`, the Xcode stub. That check was run in the Claude session and is not in the logs. In the live session the snapshot restored the order, and `python3` resolved to the pyenv shim.

## Questions 2 to 4: the holder survives the session

The live run [`tmp.EJwmuOBy`](sandbox-probes/logs/tmp.EJwmuOBy/p2_live_session.jsonl) used the 11 entries and `--add-dir .../repo/.git/tower`. The session logged `CODEX_PERMISSION_PROFILE=workspace` and `CODEX_SANDBOX=seatbelt`, so the profile was in effect. The second turn started `tower-register` through the `python3` on `PATH` with `os.setsid()`, as T038 did, and waited for the session line. `/usr/bin/python3` cannot be used for that step, because it is the Xcode stub.

The holder registered and held its lock after its own turn (question 2). It held the lock after `ls -la`, `git status --short` and `tower --help`, each in its own turn (question 3). Its `ps` row did not change between those checks.

The TUI exited normally 0.8 seconds after `/quit` with status 0. Five seconds later the holder still ran and held its lock (question 4). Its PPID was 1 and its process group was its own, so the TUI's exit did not reach it. "The holder is alive" therefore does not mean "the agent is alive" after a normal exit either. How M5 stops the holder at session end is M5's decision. The probe's cleanup then stopped it: `cleanup` `"signalled": true, "exited": true, "lock_free": true`.

The tool call `git status --short` itself failed in that session, with the Xcode stub error in `call2.err`. `tower-register`'s own `git` call worked. zsh is **inferred** to skip `/opt/homebrew/bin/git` because its target, `/opt/homebrew/Cellar/git`, is not readable, while Python executes the link directly. So the 11 entries are enough for tower, not for the agent's own use of `git`. A user who wants that adds the `git` package directory as well.

## The doctor check

A `tower doctor` check can run these two commands from the worktree, with the user's `PATH`, and require exit 0 from both:

```sh
codex sandbox -P <profile> -C <worktree> -- tower-register --help
codex sandbox -P <profile> -C <worktree> -- python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import tower_msg; print(tower_msg.runtime_root())' <tower install root>/lib
```

The measured runs added `-c check_for_update_on_startup=false`, the profile override and `--log-denials` to the same command line, because the probe could not change `config.toml`. A doctor that reads the user's own profile needs no override. The output below is from [`tmp.xSSbUjZK`](sandbox-probes/logs/tmp.xSSbUjZK/p1_sandbox_matrix.jsonl).

| Case | `tower-register --help` | `runtime_root` |
| --- | --- | --- |
| pass (`all`) | exit 0, `usage: tower-register [-h] --vendor VENDOR [--vendor-version VENDOR_VERSION]` | exit 0, `/Users/omriam/.cache/tower-t038-probes/tmp.xSSbUjZK/repo/.git/tower/root` |
| fail (`none`) | exit 126, `bash: /Users/omriam/Documents/personal-projects/tower/bin/tower-register: Operation not permitted` | exit 126, `bash: /Users/omriam/.pyenv/shims/python3: Operation not permitted` |
| fail (`minus-git_global_config`) | exit 0, the same usage line | exit 1, `subprocess.CalledProcessError: Command '['git', '-C', '.../wt', 'rev-parse', '--show-toplevel']' returned non-zero exit status 128.` |

The third row is why `tower-register --help` alone is not enough: it imports `tower_msg` but never runs `git`. The check does not cover the plugin-cache case, where `tower --help` exits 0 but resolves a different root. A check for that compares the sandboxed `tower --help` output with the unsandboxed output, as p1 does. It also does not check the write to the state root, which `--add-dir` grants. `codex sandbox --log-denials` printed `None found.` for a real denial while the Claude sandbox was on. A doctor that runs outside the Claude sandbox is **inferred** to see the denials.

## Method incidents

- No run answered a dialog. Across the 11 logs the only `pty_write` labels are `bracketed_paste`, `prompt_enter`, `quit_command` and `quit_enter`. In [`tmp.uyfJeFw3`](sandbox-probes/logs/tmp.uyfJeFw3/p2_live_session.jsonl) the probe stopped at a false dialog detection after a paste and sent no Enter. The prompt held `2>&1.`, which T031's detector reads as the numbered option `1.`. The probe changed that command to `git status --short >call2.txt 2>call2.err`.
- In `tmp.TN38cRgr`, `tmp.xEJAMdPW` and `tmp.uyfJeFw3`, the model copied the sentence's final period into the command. It ran `echo $? >py.exit.` and `cat reg.out.`, so `py.exit` is missing in those logs. The committed `p2_live_session.py` puts the command between `<<<CMD` and `CMD>>>` lines. The deciding run `tmp.EJwmuOBy` used that prompt.
- `tmp.uyfJeFw3` had the first six entries only. Registration failed with `tower-register: Command '['git', ... 'rev-parse', '--show-toplevel']' returned non-zero exit status 1.`, which showed that `--help` tests do not reach `register()`. p1 runs before `tmp.L9v1bWzQ` had three tests and no `runtime_root`. The committed p1 has four.
- The p1 runs narrowed the entries in order: `tmp.3GWaynJl` (five broad entries, including all of `/opt/homebrew`), `tmp.ouqVwros`, `tmp.A1gjZXUS`, `tmp.SJNPb0H1` and `tmp.k9pFnYAE` (six entries, before `runtime_root`), `tmp.L9v1bWzQ` (13 entries) and the deciding `tmp.xSSbUjZK` (11 entries).
- The `git` entries were found by hand with `codex sandbox` in the Claude session before p1 measured them. Those hand runs and the `path_helper` checks are not in the logs. Every run ran with the Claude sandbox disabled.

## What was left in `~/.codex/`

The probes wrote nothing under `~/.codex/` and removed nothing there. `~/.codex/config.toml` had sha256 `5246261ea67ec0c117ad99f3447926417f2a89c21e4ddb67d30666bb2075d2c4` before the first probe and after the last. Codex itself wrote its usual session state during the live runs. The `modified_codex_home_paths` event in `tmp.EJwmuOBy` lists 21 paths under `cache/`, `history.jsonl`, `logs_2.sqlite`, `models_cache.json`, `plugins/`, `session_index.jsonl`, `sessions/`, `state_5.sqlite` and `thread_history_1.sqlite-wal`. That list is by modification time, so it also catches other Codex sessions on the machine. The p1 run `tmp.xSSbUjZK` lists a rollout from 2026-09-28 that belongs to another session. The managed app-server daemon from T031 is unchanged under `~/.codex/packages/app-server-daemon/`. No probe ran `codex agents`.

## Sources

Every run's JSONL log is kept in [`sandbox-probes/logs/`](sandbox-probes/logs/), one directory per run, named after its `~/.cache/tower-t038-probes/tmp.*` directory. The excerpts list selected fields of one event each, and the logs store keys in sorted order, so an excerpt is not always a literal substring. [`sandbox-probes/README.md`](sandbox-probes/README.md) gives the launch lines and each probe's verdict rule.
