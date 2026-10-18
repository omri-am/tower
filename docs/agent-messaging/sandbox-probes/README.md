# T045 sandbox probes

Run each probe from a separate, fresh, mode-0700 directory outside Git. Set `<path>` to the installed `~/.codex/packages/standalone/current/bin/codex` binary and `<probe>` to the absolute path of this directory. The reused T038 guard creates `repo/` and a linked `wt/`. Each probe writes a JSONL log beside them. Copy that log into `logs/<run directory name>/` as soon as the run ends. Put the results in [`../sandbox-access.md`](../sandbox-access.md).

p2's launcher `PATH` is the one a new terminal gives. In its default mode, dispatch opens a new terminal window. In `here` and `headless` modes, it starts Codex with the dispatcher's environment (`lib/tower-dispatch.sh:201`). Either way, the agent gets a terminal's `PATH`. In run tmp.TN38cRgr, under the `workspace` profile the tool-call shell could not read the user's startup files, so it did not rebuild `PATH` from a system `PATH` launcher.

```sh
TERMINAL_PATH=$(env -i HOME=$HOME USER=$USER LOGNAME=$USER SHELL=/bin/zsh TERM=xterm-256color LANG=en_US.UTF-8 PATH=/usr/bin:/bin:/usr/sbin:/sbin /bin/zsh -lic 'print -r -- $PATH' | tail -1)
mkdir -p ~/.cache/tower-t038-probes
cd "$(mktemp -d ~/.cache/tower-t038-probes/tmp.XXXXXXXX)"
env -i HOME=$HOME USER=$USER LOGNAME=$USER SHELL=/bin/zsh TERM=xterm-256color LANG=en_US.UTF-8 PATH="$TERMINAL_PATH" CODEX_HOME=$HOME/.codex CODEX_BIN=<path> /usr/bin/python3 <probe>/p2_live_session.py --discover-only
```

Use `p2_live_session.jsonl`'s `tool-path.txt` line 1 as `--tool-path` for p1. Repeat `--entry LABEL=ABSPATH` for each candidate read path. Use a new run directory for every run. Run p1 with the Claude sandbox disabled: otherwise `--log-denials` reports “None found.” The owner profile check reads `~/.codex/config.toml` and stops if its base filesystem entries changed.

```sh
cd "$(mktemp -d ~/.cache/tower-t038-probes/tmp.XXXXXXXX)"
env -i HOME=$HOME USER=$USER LOGNAME=$USER SHELL=/bin/zsh TERM=xterm-256color LANG=en_US.UTF-8 PATH=/usr/bin:/bin:/usr/sbin:/sbin CODEX_HOME=$HOME/.codex CODEX_BIN=<path> python3 <probe>/p1_sandbox_matrix.py --tool-path '<recorded PATH>' --entry LABEL=ABSPATH
```

```sh
cd "$(mktemp -d ~/.cache/tower-t038-probes/tmp.XXXXXXXX)"
env -i HOME=$HOME USER=$USER LOGNAME=$USER SHELL=/bin/zsh TERM=xterm-256color LANG=en_US.UTF-8 PATH="$TERMINAL_PATH" CODEX_HOME=$HOME/.codex CODEX_BIN=<path> /usr/bin/python3 <probe>/p2_live_session.py --entry LABEL=ABSPATH
```

No dialog is answered. The live probe adds `<git common dir>/tower` for writes and gives the TUI a run-only trust override for the fixture repository. It never passes `--sandbox`. Omit `--discover-only` for the full live run.

p1 runs `tower_help`, `register_help`, `python`, `bash_git`, and `runtime_root` in the fixture worktree. A case passes when all five commands exit 0 and sandboxed `tower_help`, `runtime_root`, and `bash_git` stdout each equal their unsandboxed reference. `tower-locate` runs git from bash and hides its failure. It records `none`, `all`, and each `minus-LABEL` case.

p2 delimits each shell command between `<<<CMD` and `CMD>>>` in its prompt. Q2 passes if `after_register` has `lock_held: true` and `lock_content_matches_session: true`. It fails if `reg.out` has a session token but the lock is free. Otherwise it cannot be determined. Q3 passes if the lock is held at `after_call1`, `after_call2`, and `after_call3`. It fails if Q2 passed and any of those stages has a free lock. Otherwise it cannot be determined. Q4 uses `holder_after_quit` to report whether the saved holder PID exists and the lock is held at `after_quit`. It passes when the TUI exits and the holder still runs and holds its lock. It fails if the TUI exits and either state is false. It cannot be determined if the TUI did not exit after `/quit` or no holder PID was recorded.

Cleanup sends SIGTERM only when the recorded holder's command line contains the installed `lib` path and `t045-holder`. Check each run's `cleanup` event for `exited` and `lock_free`.
