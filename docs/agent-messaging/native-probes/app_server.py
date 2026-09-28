#!/usr/bin/env python3
"""Throwaway T015 Codex app-server probe. Run only from a mktemp -d directory."""
import json
import os
from pathlib import Path
import select
import shutil
import subprocess
import time


def log(label, value):
    with open('app-server.jsonl', 'a') as output:
        output.write(json.dumps({'time': time.time(), label: value}) + '\n')


def main():
    assert subprocess.run(['git', 'rev-parse', '--show-toplevel'],
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode != 0
    assert not Path('app-server.jsonl').exists()
    codex = str(Path(shutil.which('codex')).resolve())
    process = subprocess.Popen([codex, 'app-server', '--stdio',
                                '-c', 'approvals_reviewer="user"'],
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, bufsize=0)
    pending = b''
    seen = []

    def send(number, method, params):
        message = {'id': number, 'method': method, 'params': params}
        log('send', message)
        process.stdin.write((json.dumps(message) + '\n').encode())
        process.stdin.flush()

    def until(predicate, seconds=50):
        nonlocal pending
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            if not select.select([process.stdout], [], [], 0.2)[0]:
                continue
            pending += os.read(process.stdout.fileno(), 65536)
            while b'\n' in pending:
                line, pending = pending.split(b'\n', 1)
                event = json.loads(line)
                log('receive', event)
                seen.append(event)
                if predicate(event):
                    return event
        raise TimeoutError('event not observed')

    try:
        send(1, 'initialize', {'clientInfo': {'name': 'tower-native-probe', 'version': '0.1.0'}})
        until(lambda e: e.get('id') == 1)
        process.stdin.write(b'{"method":"initialized"}\n')
        attached = os.environ.get('ATTACH_THREAD')
        method = 'thread/resume' if attached else 'thread/start'
        params = {'threadId': attached} if attached else {
            'cwd': str(Path.cwd()), 'model': 'gpt-6-luna', 'approvalsReviewer': 'user'}
        send(2, method, params)
        reply = until(lambda e: e.get('id') == 2)
        if 'error' in reply:
            return
        thread = reply['result']['thread']['id']
        text = lambda s: [{'type': 'text', 'text': s}]
        if attached:
            send(3, 'turn/start', {'threadId': thread,
                                   'input': text('Reply APP_ATTACH. No tools.')})
            until(lambda e: e.get('method') == 'turn/completed', 90)
            return
        send(3, 'turn/start', {'threadId': thread, 'input': text('Reply APP_IDLE. No tools.')})
        until(lambda e: e.get('method') == 'turn/completed', 90)
        send(4, 'turn/start', {'threadId': thread,
                               'input': text('Reply APP_WAKE. No tools.')})
        completed = until(lambda e: e.get('method') == 'turn/completed', 90)
        send(8, 'turn/steer', {'threadId': thread,
                               'expectedTurnId': completed['params']['turn']['id'],
                               'input': text('Reply APP_IDLE_STEER.')})
        rejected = until(lambda e: e.get('id') == 8, 30)
        assert rejected.get('error', {}).get('message') == 'no active turn to steer'
        send(5, 'turn/start', {'threadId': thread,
                               'input': text('Count silently for 8 seconds, then reply APP_BUSY. No tools.')})
        started = until(lambda e: e.get('method') == 'turn/started', 30)
        turn = started['params']['turn']['id']
        send(6, 'turn/start', {'threadId': thread,
                               'input': text('Also include APP_START_BUSY.')})
        assert until(lambda e: e.get('id') == 6, 30)['result']['turn']['id'] == turn
        send(7, 'turn/steer', {'threadId': thread, 'expectedTurnId': turn,
                               'input': text('Also include APP_STEER in the reply.')})
        assert until(lambda e: e.get('id') == 7, 30)['result']['turnId'] == turn
        completed = until(lambda e: e.get('method') == 'turn/completed', 90)
        assert completed['params']['turn']['id'] == turn
        for marker in ['APP_START_BUSY', 'APP_STEER']:
            assert any(event.get('method') == 'item/started'
                       and event['params']['turnId'] == turn
                       and marker in str(event['params']['item'].get('content', ''))
                       for event in seen)
    finally:
        process.terminate()
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
        log('exit', {'returncode': process.returncode,
                     'stderr': process.stderr.read().decode(errors='replace')[-3000:]})


if __name__ == '__main__':
    main()
