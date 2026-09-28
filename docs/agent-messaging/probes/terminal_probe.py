#!/usr/bin/env python3
"""Throwaway T014 PTY probe; not a safe delivery adapter.

Run in your own mktemp scratch. After inspecting events.jsonl, append one JSON
{label, text} action to actions.jsonl; {"label": "quit"} terminates the child.
Never append input while a tool/permission/choice dialog is open.
"""
import argparse
import fcntl
import json
import os
from pathlib import Path
import pty
import re
import select
import shlex
import shutil
import signal
import struct
import subprocess
import sys
import termios
import time


def record(kind, value):
    with open('events.jsonl', 'a') as log:
        log.write(json.dumps({'at': time.monotonic(), kind: value}) + '\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('vendor', choices=['claude', 'codex'])
    parser.add_argument('--seconds', type=float, default=600)
    args = parser.parse_args()
    cwd = Path.cwd().resolve()
    if subprocess.run(['git', 'rev-parse', '--show-toplevel'], cwd=cwd,
                      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0:
        parser.error('run from your own mktemp -d scratch directory, outside any repository')
    if Path('events.jsonl').exists():
        parser.error('use a fresh scratch directory; do not overwrite evidence')
    recorder = [sys.executable, str(Path(__file__).resolve()), '--record']
    if args.vendor == 'claude':
        hooks = {event: [{'hooks': [{'type': 'command', 'command': shlex.join(recorder)}]}]
                 for event in ['Stop', 'UserPromptSubmit', 'PermissionRequest',
                               'Notification', 'PreToolUse', 'Elicitation']}
        Path('settings.json').write_text(json.dumps({'hooks': hooks}))
        command = ['claude', '--setting-sources', '', '--settings', 'settings.json',
                   '--permission-mode', 'manual', '--model', 'haiku']
    else:
        command = [str(Path(shutil.which('codex')).resolve()), '--no-daemon', '--model', 'gpt-6-luna',
                   '-c', 'notify=' + json.dumps(recorder),
                   '-c', 'approvals_reviewer="user"',
                   '-c', 'tui.notification_condition="always"',
                   '-c', 'tui.notification_method="osc9"']
    command += ['Reply READY. Do not use any tools.']
    record('start', {'version': subprocess.check_output([args.vendor, '--version'],
                                                       text=True).strip(),
                     'cwd': str(cwd), 'argv': command})
    started = time.monotonic()
    pid, master = pty.fork()
    if pid == 0:
        os.environ['TERM'] = 'xterm-256color'
        os.execvp(command[0], command)
    fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack('HHHH', 40, 120, 0, 0))
    trusted, ended, action_index = False, 0, 0
    screen = ''
    trust_seen = None
    try:
        while time.monotonic() - started < args.seconds:
            if select.select([master], [], [], 0.05)[0]:
                try:
                    data = os.read(master, 65536)
                except OSError:
                    break
                if not data:
                    break
                output = data.decode('utf-8', errors='replace')
                record('output', output)
                screen += output
            plain = re.sub(r'\x1b\[[0-9;]+[GH]', ' ', screen)
            plain = re.sub(r'\x1b\[[0-?]*[ -/]*[@-~]', '', plain)
            trust_label = 'Yes, I trust this folder' if args.vendor == 'claude' else '1. Trust and continue'
            if not trusted and str(cwd) in plain and trust_label in plain:
                if trust_seen is None:
                    trust_seen = time.monotonic()
                if time.monotonic() - trust_seen < 2:
                    continue
                if args.vendor == 'claude':
                    os.write(master, b'\x1b[B')
                    record('trust_selection', {'bytes_hex': '1b5b42'})
                    time.sleep(0.3)
                keys = b'\r'
                record('workspace_trust', {'cwd': str(cwd), 'bytes_hex': keys.hex()})
                os.write(master, keys)
                trusted, screen = True, ''
            actions = Path('actions.jsonl')
            if actions.exists():
                lines = actions.read_text().splitlines()
                for line in lines[action_index:]:
                    action = json.loads(line)
                    if action['label'] == 'quit':
                        return
                    if not trusted:
                        raise RuntimeError('input refused before workspace trust')
                    record('input', action)
                    os.write(master, action['text'].encode('utf-8'))
                    action_index += 1
            ended, status = os.waitpid(pid, os.WNOHANG)
            if ended:
                break
    finally:
        if not ended:
            try:
                os.killpg(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            time.sleep(0.2)
            ended, status = os.waitpid(pid, os.WNOHANG)
        os.close(master)
        record('end', {'elapsed': time.monotonic() - started, 'reaped': bool(ended)})


if __name__ == '__main__':
    if sys.argv[1:2] == ['--record']:
        record('hook', json.loads(sys.argv[2] if len(sys.argv) > 2 else sys.stdin.read()))
    else:
        main()
