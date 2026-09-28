#!/usr/bin/env python3
"""Throwaway T015 Codex queue probe. Run only from a mktemp -d directory."""
import fcntl
import json
import os
from pathlib import Path
import pty
import re
import select
import shutil
import signal
import struct
import subprocess
import termios
import time


def log(label, value):
    with open('codex-queue.jsonl', 'a') as output:
        output.write(json.dumps({'time': time.time(), label: value}) + '\n')


def main():
    cwd = Path.cwd().resolve()
    assert subprocess.run(['git', 'rev-parse', '--show-toplevel'],
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode != 0
    assert not Path('codex-queue.jsonl').exists()
    codex = str(Path(shutil.which('codex')).resolve())
    sessions = Path.home() / '.codex' / 'sessions'
    before = set(sessions.rglob('*.jsonl'))
    pid, master = pty.fork()
    if pid == 0:
        os.environ['TERM'] = 'xterm-256color'
        os.execv(codex, [codex, '-m', 'gpt-6-luna',
                         '-c', 'approvals_reviewer="user"',
                         'Reply QUEUE_INITIAL. No tools.'])
    fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack('HHHH', 40, 120, 0, 0))
    screen = ''
    trusted = False
    trust_seen = None
    thread = None
    rollout = None
    queued = False
    draft = False
    busy = False
    start = time.monotonic()
    try:
        while time.monotonic() - start < 150:
            if select.select([master], [], [], 0.1)[0]:
                try:
                    chunk = os.read(master, 65536)
                except OSError:
                    break
                if not chunk:
                    break
                rendered = chunk.decode('utf-8', errors='replace')
                log('output', rendered)
                screen += rendered
                if any(s in screen for s in ['Would you like to run', 'Select model',
                                               'Approval requested:']):
                    log('dialog_stop', True)
                    break
            plain = re.sub(r'\x1b\[[0-?]*[ -/]*[@-~]', '', screen)
            if not trusted and str(cwd) in plain and '1. Trust and continue' in plain:
                if trust_seen is None:
                    trust_seen = time.monotonic()
                if time.monotonic() - trust_seen >= 2:
                    os.write(master, b'\r')
                    log('workspace_trust', str(cwd))
                    trusted = True
            if trusted and thread is None:
                for path in set(sessions.rglob('*.jsonl')) - before:
                    with path.open(errors='replace') as source:
                        first = json.loads(source.readline())
                    if first.get('type') == 'session_meta' and first['payload'].get('cwd') == str(cwd):
                        thread = first['payload']['id']
                        rollout = path
                        log('thread', {'id': thread, 'rollout': str(path)})
                        break
            events = []
            if rollout:
                for line in rollout.read_text(errors='replace').splitlines():
                    entry = json.loads(line)
                    if entry['type'] == 'event_msg':
                        events.append(entry['payload'])
            completed = [event.get('last_agent_message') for event in events
                         if event.get('type') == 'task_complete']
            started = sum(event.get('type') == 'task_started' for event in events)
            if thread and not queued and 'QUEUE_INITIAL' in completed:
                result = subprocess.run([codex, 'queue', '--thread', thread,
                                         '--message', 'Reply QUEUE_IDLE. No tools.'],
                                        capture_output=True, text=True, timeout=20)
                log('queue_idle', {'returncode': result.returncode,
                                   'stdout': result.stdout, 'stderr': result.stderr})
                assert result.returncode == 0
                queued = True
            if queued and not busy and 'QUEUE_IDLE' in completed:
                prompt = b'Count silently for 8 seconds, then reply QUEUE_BUSY. No tools.'
                os.write(master, b'\x1b[200~' + prompt + b'\x1b[201~')
                time.sleep(0.2)
                os.write(master, b'\r')
                log('terminal_busy_turn', True)
                busy = True
            if busy and not draft and started >= 3:
                os.write(master, b'HUMAN_DRAFT_\xc3\xa9')
                log('human_draft', 'HUMAN_DRAFT_é')
                result = subprocess.run([codex, 'queue', '--thread', thread,
                                         '--message', 'Reply QUEUE_DURING_BUSY. No tools.'],
                                        capture_output=True, text=True, timeout=20)
                log('queue_busy', {'returncode': result.returncode,
                                   'stdout': result.stdout, 'stderr': result.stderr})
                assert result.returncode == 0
                draft = True
            if draft and 'QUEUE_DURING_BUSY' in plain:
                break
        log('observed', {'trusted': trusted, 'thread': thread, 'queued': queued,
                         'busy': busy, 'draft': draft})
        if draft:
            user_texts = []
            for line in rollout.read_text(errors='replace').splitlines():
                entry = json.loads(line)
                payload = entry['payload']
                if entry['type'] == 'response_item' and payload.get('role') == 'user':
                    user_texts += [part['text'] for part in payload.get('content', [])
                                   if part.get('type') == 'input_text']
            log('native_user_texts', user_texts)
            assert 'Reply QUEUE_DURING_BUSY. No tools.' in user_texts
            assert all('HUMAN_DRAFT_é' not in value for value in user_texts)
    finally:
        try:
            os.killpg(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        reaped = False
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            if os.waitpid(pid, os.WNOHANG)[0]:
                reaped = True
                break
            time.sleep(0.05)
        os.close(master)
        log('exit', {'child_reaped': reaped})


if __name__ == '__main__':
    main()
