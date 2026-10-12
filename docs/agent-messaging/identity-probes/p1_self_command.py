"""Throwaway T031 self-command probe. Run only from a mktemp -d directory.

For live runs set CODEX_BIN=/Users/omriam/.codex/packages/standalone/releases/0.159.3-aarch64-apple-darwin/bin/codex.
Live mode can install and start Codex's managed app-server daemon. Do not rerun live mode unless the owner accepts that change under ~/.codex.
"""
import json
import os
import re
import select
import signal
import subprocess
import time

from common import ANSI, SCREEN_CLEAR, command, detect_dialog, guard


UUID = re.compile(r'\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b')
ABSOLUTE_PATH = re.compile(r'(?<![/\w])/(?!/)[^\s<>"\x27`]+')


def help_sweep(run):
    pending = [()]
    seen = set()
    while pending:
        parts = pending.pop(0)
        if parts in seen:
            continue
        seen.add(parts)
        result = command(run, [run.codex] + list(parts) + ['--help'], timeout=10)
        run.log('help', {'command': list(parts), **result})
        matches = [line for line in (result['stdout'] + result['stderr']).splitlines()
                   if re.search(r'thread|session|current|self|whoami|id', line, re.I)]
        run.log('help_matches', {'command': list(parts), 'lines': matches})
        in_commands = False
        for line in result['stdout'].splitlines():
            if line.strip() == 'Commands:':
                in_commands = True
                continue
            if in_commands and not line.strip():
                break
            if in_commands:
                entry = re.match(r'^  ([a-z][a-z-]*)\s{2,}', line)
                if entry and entry.group(1) != 'help':
                    pending.append(parts + (entry.group(1),))


def redacted_agents(run, output, thread):
    plain = ANSI.sub('', output)
    redacted = UUID.sub(lambda found: found.group() if found.group() == thread else '<uuid>', plain)
    redacted = ABSOLUTE_PATH.sub(
        lambda found: found.group() if found.group().rstrip('.,;:)]}') == str(run.cwd)
        else '<path>' + found.group()[len(found.group().rstrip('.,;:)]}')):], redacted)
    lines = redacted.splitlines()
    return {'lines': lines, 'names_probe_thread': thread in plain,
            'caller_marker_near_thread': [line for line in lines
                                          if thread in line and re.search(r'current|self|you|active|caller', line, re.I)]}


def agents_pty(run, env, thread):
    import fcntl
    import pty
    import struct
    import termios
    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(str(run.cwd))
        os.environ.clear()
        os.environ.update(env)
        os.execv(run.codex, [run.codex, 'agents', '-c',
                             'check_for_update_on_startup=false', '--no-alt-screen'])
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', 40, 120, 0, 0))
    output = ''
    active_screen = ''
    started = time.monotonic()
    until = min(run.deadline, started + 10)
    checkpoints = [1, 3, 10]
    reaped = False
    wait_status = None

    def drain_exit_output():
        for _ in range(20):
            if not select.select([fd], [], [], 0)[0]:
                return
            try:
                data = os.read(fd, 65536)
            except OSError:
                return
            if not data:
                return
            run.log('agents_pty_drain', {'pid': pid, 'bytes': len(data)})

    try:
        while time.monotonic() < until:
            if select.select([fd], [], [], 0.2)[0]:
                try:
                    data = os.read(fd, 65536)
                except OSError:
                    break
                if not data:
                    break
                decoded = data.decode(errors='replace')
                output += decoded
                active_screen += decoded
                clears = list(SCREEN_CLEAR.finditer(active_screen))
                if clears:
                    active_screen = active_screen[clears[-1].end():]
            kind, plain = detect_dialog(active_screen, run.cwd)
            if kind:
                safe_lines = [line for line in redacted_agents(run, output, thread)['lines']
                              if re.search(r'Update now|Trust this folder|Trustthisfolder|esc skip|enter continue',
                                           line, re.I)]
                run.log('dialog_stop', {'screen': redacted_agents(run, output, thread),
                                        'dialog_lines': safe_lines, 'kind': kind})
                break
            while checkpoints and time.monotonic() - started >= checkpoints[0]:
                run.log('agents_pty_screen', {'elapsed_seconds': checkpoints.pop(0),
                                               **redacted_agents(run, output, thread)})
        while checkpoints and time.monotonic() - started >= checkpoints[0]:
            run.log('agents_pty_screen', {'elapsed_seconds': checkpoints.pop(0),
                                           **redacted_agents(run, output, thread)})
        run.log('agents_pty_screen', redacted_agents(run, output, thread))
    finally:
        if not reaped:
            try:
                os.killpg(pid, signal.SIGTERM)
            except OSError as error:
                run.log('killpg_error', {'pid': pid, 'signal': 'SIGTERM', 'error': repr(error)})
        end = time.monotonic() + 2
        while time.monotonic() < end:
            drain_exit_output()
            try:
                waited_pid, wait_status = os.waitpid(pid, os.WNOHANG)
                if waited_pid:
                    reaped = True
                    break
            except ChildProcessError:
                reaped = True
                wait_status = None
                break
            time.sleep(0.05)
        if not reaped:
            run.log('reap_timeout', {'pid': pid, 'after_signal': 'SIGTERM'})
            try:
                os.killpg(pid, signal.SIGKILL)
            except OSError as error:
                run.log('killpg_error', {'pid': pid, 'signal': 'SIGKILL', 'error': repr(error)})
            end = time.monotonic() + 2
            while time.monotonic() < end:
                drain_exit_output()
                try:
                    waited_pid, wait_status = os.waitpid(pid, os.WNOHANG)
                    if waited_pid:
                        reaped = True
                        break
                except ChildProcessError:
                    reaped = True
                    wait_status = None
                    break
                time.sleep(0.05)
        if not reaped:
            run.log('reap_timeout', {'pid': pid, 'after_signal': 'SIGKILL'})
        run.log('agents_pty_stop', {'pid': pid, 'reaped': reaped,
                                    'waitpid_status': wait_status if reaped else None})
        os.close(fd)


def main():
    import argparse
    options = argparse.ArgumentParser()
    options.add_argument('--deadline', type=int, default=300)
    options.add_argument('--help-sweep', action='store_true')
    parsed = options.parse_args()
    run = guard('p1_self_command', parsed.deadline)
    try:
        if parsed.help_sweep:
            help_sweep(run)
            return
        prompt = 'Reply SELF_READY. No tools.'
        run.launch(prompt)
        thread = run.thread_id(run.wait_marker('SELF_READY', prompt))
        env_path = run.cwd / 'session-env.json'
        env = json.loads(env_path.read_text()) if env_path.exists() else dict(os.environ)
        run.log('agents_environment', {'from_session_env': env_path.exists(),
                                        'variable_count': len(env)})
        try:
            result = command(run, [run.codex, 'agents', '-c',
                                   'check_for_update_on_startup=false'], timeout=10, env=env)
            run.log('agents_no_tty', {'returncode': result['returncode'],
                                      'stdout': redacted_agents(run, result['stdout'], thread),
                                      'stderr': redacted_agents(run, result['stderr'], thread)})
        except subprocess.TimeoutExpired:
            run.log('agents_no_tty', {'timeout_seconds': 10})
        agents_pty(run, env, thread)
        run.log('caller_identity', {'thread_id': thread, 'from_notify': True})
    finally:
        run.stop()


if __name__ == '__main__':
    main()
