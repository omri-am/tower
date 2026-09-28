#!/usr/bin/env python3
"""Throwaway T015 Claude stream probe. Run only from a mktemp -d directory."""
import json
import os
from pathlib import Path
import select
import subprocess
import time


def log(label, value):
    with open('claude-stream.jsonl', 'a') as output:
        output.write(json.dumps({'time': time.time(), label: value}) + '\n')


def main():
    assert subprocess.run(['git', 'rev-parse', '--show-toplevel'],
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode != 0
    assert not Path('claude-stream.jsonl').exists()
    process = subprocess.Popen(['claude', '--print', '--verbose', '--input-format', 'stream-json',
                                '--output-format', 'stream-json', '--replay-user-messages',
                                '--setting-sources', '', '--strict-mcp-config',
                                '--permission-mode', 'manual',
                                '--tools', '', '--model', 'haiku'], stdin=subprocess.PIPE,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0)
    pending = b''

    def send(marker):
        message = {'type': 'user', 'message': {'role': 'user', 'content':
                   'Reply ' + marker + '. No tools.'}}
        log('send', message)
        process.stdin.write((json.dumps(message) + '\n').encode())
        process.stdin.flush()

    def until(predicate, seconds=50):
        nonlocal pending
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            if not select.select([process.stdout], [], [], 0.2)[0]:
                if process.poll() is not None:
                    break
                continue
            chunk = os.read(process.stdout.fileno(), 65536)
            if not chunk:
                break
            pending += chunk
            while b'\n' in pending:
                line, pending = pending.split(b'\n', 1)
                event = json.loads(line)
                log('receive', event)
                if predicate(event):
                    return event
        return None

    try:
        send('CLAUDE_IDLE')
        until(lambda e: e.get('type') == 'result', 75)
        send('CLAUDE_WAKE')
        replay = until(lambda e: e.get('type') == 'user', 75)
        assert replay['message']['content'] == 'Reply CLAUDE_WAKE. No tools.'
        until(lambda e: e.get('type') == 'result', 75)
        send('CLAUDE_BUSY')
        replay = until(lambda e: e.get('type') == 'user', 15)
        log('busy_replay', replay)
        send('CLAUDE_STEER')
        assert until(lambda e: e.get('type') == 'result', 75)['result'] == 'CLAUDE_BUSY'
        replay = until(lambda e: e.get('type') == 'user', 75)
        assert replay['message']['content'] == 'Reply CLAUDE_STEER. No tools.'
        assert until(lambda e: e.get('type') == 'result', 75)['result'] == 'CLAUDE_STEER'
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
