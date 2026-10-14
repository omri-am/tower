# T038 lifetime probes

Run each probe from a separate, fresh, mode-0700 directory outside Git. Set `<path>` to the installed `~/.codex/packages/standalone/current/bin/codex` binary and `<probe>` to one of the four Python scripts in this directory. The guard creates `repo/` and a linked `wt/` in that directory. Each probe writes its JSONL log beside them. Copy the log into `logs/<run directory name>/` as soon as the run ends. Results are in [`../registration-lifetime.md`](../registration-lifetime.md).

```sh
mkdir -p ~/.cache/tower-t038-probes
cd "$(mktemp -d ~/.cache/tower-t038-probes/tmp.XXXXXXXX)"
env -i HOME=$HOME USER=$USER LOGNAME=$USER SHELL=/bin/zsh TERM=xterm-256color LANG=en_US.UTF-8 PATH=/usr/bin:/bin:/usr/sbin:/sbin CODEX_HOME=$HOME/.codex CODEX_BIN=<path> python3 <probe>
```

No dialog is answered, including workspace trust. Every launch passes a run-only `-c 'projects={"<fixture repo>"={trust_level="trusted"}}'`. That override trusts the fixture without a dialog and without a save to `config.toml`. Codex keys trust by repository root, so a dispatched worktree is assumed to inherit the trust of its repository root. That assumption is inference.

`p1_survival.py` first logs the session's `CODEX_*` variables and whether `/usr/bin/python3` runs. Then it starts four detached registrations in one interactive session, one turn each. Each command waits up to 5 seconds for the session line before it returns. The probe checks each lock after its turn, after 30 idle seconds, and five seconds after the TUI stops. It always passes `--add-dir <common>/tower`, and `--sandbox <mode>` passes a sandbox mode to Codex. The run passes Q1 if at least one variant has `lock_held: true` at `after_idle`. It fails if at least one variant registered (its record exists) and no variant holds the lock at `after_idle`. If no variant registered, Q1 cannot be determined from that run. Compare `plain`, `nohup`, `disown`, and `setsid` separately to see whether the detach method mattered.

`p2_write_access.py` runs one command from the linked worktree. The command creates `<state root>/agents` with `mkdir`, runs `/usr/bin/python3 -c pass`, and then starts one registration. Each step records its exit status or stderr in its own file. Run it once with no option and once with `--add-dir`, using a fresh directory each time. Q2 asks about writes, not survival, so a run passes Q2 if `mkdir.exit` is `0` and `agents/t038-write.json` exists. Its `lock_held` value is not part of the rule, because p2 starts the holder with `nohup`, and p1 found that `nohup` holders do not outlive the tool call. A run fails if `mkdir.err` shows a permission error. If `mkdir.exit` is `0` but `reg-write.err` shows that `tower-register` could not start, the state root is writable but the registration write cannot be determined from that run.

`p3_thread_identity.py` compares the shell's `CODEX_THREAD_ID` with the main turn's notify `thread-id`. It also logs all notify thread IDs in arrival order. Q3 passes when `CODEX_THREAD_ID` is present and `thread_id_equals_notify` is true.

`p4_subagent_identity.py` asks one subagent to write `sub-env.txt`, then writes `main-env.txt` from the root session. It logs both thread and session IDs, and fresh rollout lines that mention `sub-env.txt`. Q4 passes (the subagent sees its own ID) if the subagent's `CODEX_THREAD_ID` differs from the main's and rollout evidence shows the subagent thread ran `sub-env.txt`. It fails (the subagent sees the root's ID) if the IDs match and rollout evidence shows the subagent ran it. Otherwise, including a dialog stop, no subagent, or no rollout evidence, the result cannot be determined.

Cleanup sends SIGTERM only when `ps` shows both the checkout's `lib` path and the role in the recorded process's command line. `tower-register` replaces its shell with `python3 - <checkout>/lib <role> ...`, so its own name is not in that command line. Each log's `cleanup` events record whether every registration exited.
