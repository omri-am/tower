# T053 queue delivery probe

Run the probe from a fresh, mode-0700 scratch directory outside Git. Set `<scratch>` to a private path outside that run directory and `<probe>` to the absolute path of this directory. Results belong in [`../queue-delivery.md`](../queue-delivery.md).

Run the first line in the caller's own shell, such as a Claude Code session's Bash tool. Keep `caller.env` outside the run directory and never copy it into `logs/`.

```sh
env -0 > <scratch>/caller.env
mkdir -p ~/.cache/tower-t038-probes
cd "$(mktemp -d ~/.cache/tower-t038-probes/tmp.XXXXXXXX)"
env -i HOME=$HOME USER=$USER LOGNAME=$USER SHELL=/bin/zsh TERM=xterm-256color LANG=en_US.UTF-8 PATH=/usr/bin:/bin:/usr/sbin:/sbin CODEX_HOME=$HOME/.codex CODEX_BIN=$HOME/.codex/packages/standalone/current/bin/codex /usr/bin/python3 <probe>/p1_queue_matrix.py --caller-env <scratch>/caller.env
```

Run with the Claude sandbox disabled. As soon as the run ends, copy only `p1_queue_matrix.jsonl` and `wt/notify.jsonl` into `logs/<run directory name>/`.

No dialog is answered. Queue calls get no `-c` except `clean_config_override`, because a configuration override is part of the behavior measured here. The throwaway TUI starts with `--disable hooks`: Codex 0.165.0 otherwise opens a hook-trust selector at startup (run tmp.kShL1tDS), and the probe must not answer it.

The log records environment variable names only, never values, because the caller's environment holds secrets and the logs are committed.

The probe signals only its own process groups. It never starts, stops, or restarts the daemon, and it never runs `codex agents`.

Codex itself writes the session rollout and state under `~/.codex`. The reused `finish` function logs paths modified there during the run.

The caller cases run the Superset wrapper with the caller's environment. In a Superset terminal, the wrapper reports `SessionEnd` for that terminal to Superset, as every `tower send` from such a session does.

`caller_path` and `clean_local_bin` isolate the caller environment from a clean environment. `clean_enable_hooks` isolates `--enable hooks`, and `clean_bypass_hook_trust` isolates the hook-trust bypass. `clean_config_override` isolates `-c`, while `clean_wrapper` isolates the wrapper under a clean environment. The `v0_164_0` and `v0_162_1` cases isolate older CLIs and their hooks flag: 0.164.0 is the version that failed on 2026-10-26. The remote cases isolate the default and explicit socket forms, the caller's remote form, and a missing socket. The missing-thread cases isolate an unknown thread with local, remote, and caller paths.
