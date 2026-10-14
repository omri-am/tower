"""Throwaway T031 session-environment probe. Run only from a mktemp -d directory.

For live runs set CODEX_BIN=/Users/omriam/.codex/packages/standalone/releases/0.159.3-aarch64-apple-darwin/bin/codex.
"""
import json
import os
from pathlib import Path
import subprocess
import time

from common import guard, parser


def descendants(pid):
    found = {pid}
    frontier = [pid]
    while frontier:
        parent = frontier.pop()
        result = subprocess.run(['pgrep', '-P', str(parent)], capture_output=True, text=True)
        for line in result.stdout.splitlines():
            child = int(line)
            if child not in found:
                found.add(child)
                frontier.append(child)
    return found


def main():
    options = parser('Session environment probe')
    options.add_argument('--inherit-none', action='store_true')
    args = options.parse_args()
    run = guard('p2_session_env', args.deadline)
    launched = time.time()
    try:
        command = '/usr/bin/env -0' if args.inherit_none else 'env -0'
        prompt = ('Run exactly one shell command: ' + command + ' > session-env.txt. '
                  'Then reply ENV_DONE. Use no other tools.')
        extra = ('-c', 'shell_environment_policy.inherit="none"') if args.inherit_none else ()
        child = run.launch(prompt, extra=extra)
        thread = run.thread_id(run.wait_marker('ENV_DONE', prompt))
        path = run.cwd / 'session-env.txt'
        if not path.exists():
            run.log('env_missing', str(path))
            return
        env = {}
        for entry in path.read_bytes().split(b'\0'):
            if b'=' in entry:
                key, value = entry.split(b'=', 1)
                env[os.fsdecode(key)] = os.fsdecode(value)
        (run.cwd / 'session-env.json').write_text(json.dumps(env, indent=2) + '\n')
        if args.inherit_none:
            run.log('environment_names', sorted(env))
        codex = {key: value for key, value in env.items() if key.startswith('CODEX_')}
        run.log('codex_environment', {'variables': codex,
                                       'thread_id': thread,
                                       'matching_names': [key for key in env if thread in key],
                                       'matching_values': [key for key, value in env.items() if thread in value]})
        for pid in sorted(descendants(child['pid'])):
            result = subprocess.run(['lsof', '-Fn', '-p', str(pid)], capture_output=True,
                                    text=True, timeout=10)
            paths = [line[1:] for line in result.stdout.splitlines()
                     if line.startswith('n') and thread in line]
            run.log('lsof_thread_paths', {'pid': pid, 'paths': paths,
                                           'returncode': result.returncode})
        home = Path(env.get('CODEX_HOME', str(Path.home() / '.codex'))).expanduser()
        paths = []
        if home.is_dir():
            for base, dirs, files in os.walk(str(home)):
                run.check_time()
                dirs[:] = [name for name in dirs if not name.startswith('.')]
                for name in files:
                    run.check_time()
                    file = Path(base) / name
                    if thread in str(file):
                        try:
                            if file.stat().st_mtime >= launched:
                                paths.append(str(file))
                        except OSError:
                            pass
        run.log('modified_codex_home_paths', paths)
    finally:
        run.stop()


if __name__ == '__main__':
    main()
