#!/usr/bin/env python3
"""Create and observe disposable T082 Claude sessions through tmux.

Inspect each tmux pane before every input. Only accept trust for the printed
scratch path. Never answer another dialog. Use the send subcommand separately.
"""

import argparse
import json
import os
from pathlib import Path
import shlex
import shutil
import signal
import subprocess
import sys
import time


ROOT = Path(__file__).resolve().parents[3]
SCRIPT = Path(__file__).resolve()


def record(path, kind, value):
    with path.open('a') as output:
        output.write(json.dumps({'mono': time.monotonic(), 'utc': time.time(),
                                 'kind': kind, 'value': value}) + '\n')


def hook():
    payload = json.load(sys.stdin)
    record(Path(os.environ['T082_EVENTS']), 'hook', payload.get('hook_event_name'))


def capture(path):
    while chunk := os.read(sys.stdin.fileno(), 8192):
        record(path, 'terminal', chunk.decode('utf-8', errors='replace'))


def start(name):
    scratch = Path(subprocess.check_output(['mktemp', '-d'], text=True).strip()).resolve()
    subprocess.run(['git', 'init', '-q', str(scratch)], check=True)
    subprocess.run([str(ROOT / 'bin/tower-init'), '--sidecar', str(scratch)],
                   check=True, stdout=subprocess.DEVNULL)
    events = scratch / 'events.jsonl'
    binary = shutil.which('claude')
    record(events, 'setup', {
        'probe': name, 'scratch': str(scratch), 'claude_path': binary,
        'claude_real': str(Path(binary).resolve()),
        'version': subprocess.check_output(['claude', '--version'], text=True).strip(),
        'config_dir': os.environ.get('CLAUDE_CONFIG_DIR', str(Path.home() / '.claude')),
    })
    callback = shlex.join([sys.executable, str(SCRIPT), 'hook'])
    hooks = {name: [{'hooks': [{'type': 'command', 'command': callback}]}]
             for name in ('Stop', 'UserPromptSubmit')}
    if name == 'p4':
        waiter = str(ROOT / 'bin/tower-inbox')
        command = f'TOWER_ROLE=probe {waiter} list --wait 590 1>&2 && exit 2; exit 0'
        hooks['Stop'][0]['hooks'].append({'type': 'command', 'asyncRewake': True,
                                           'timeout': 600, 'command': command})
    settings = scratch / 'settings.json'
    settings.write_text(json.dumps({'hooks': hooks}))
    claude = ['claude', '--setting-sources', '', '--settings', str(settings),
              '--strict-mcp-config', '--model', 'claude-haiku-5-5',
              '--permission-mode', 'manual']
    if name in ('p1', 'p2a', 'p2b', 'p3', 'p3kill', 'p3quit'):
        claude.extend(['--allowedTools', 'Bash'])
    elif name == 'p2b2':
        waiter = str(ROOT / 'bin/tower-inbox')
        claude.extend(['--allowedTools', f'Bash(TOWER_ROLE=probe {waiter} list --wait 900)'])
    session = 't082-' + name
    command = f'cd {shlex.quote(str(scratch))} && exec env T082_EVENTS={shlex.quote(str(events))} DISABLE_AUTOUPDATER=1 {shlex.join(claude)}'
    subprocess.run(['tmux', 'new-session', '-d', '-s', session, '-x', '120', '-y', '40',
                    f'sleep 2; {command}'], check=True)
    pipe = shlex.join([sys.executable, str(SCRIPT), 'capture', str(events)])
    subprocess.run(['tmux', 'pipe-pane', '-t', session, '-o', pipe], check=True)
    record(events, 'launch', {'session': session, 'argv': claude})
    print(scratch)


def send(scratch, message):
    scratch = Path(scratch).resolve()
    events = scratch / 'events.jsonl'
    env = os.environ.copy()
    env['TOWER_ROLE'] = 'prober'
    command = [str(ROOT / 'bin/tower-send'), 'probe', message]
    record(events, 'send_start', message)
    result = subprocess.run(command, cwd=scratch, env=env, capture_output=True, text=True)
    record(events, 'send_end', {'exit': result.returncode, 'stdout': result.stdout.strip(),
                                'stderr': result.stderr.strip()})
    print(f'exit={result.returncode} id={result.stdout.strip()}')


def mark(scratch, kind, value):
    record(Path(scratch).resolve() / 'events.jsonl', kind, value)


def due(scratch):
    scratch = Path(scratch).resolve()
    events = scratch / 'events.jsonl'
    stops = [json.loads(line)['mono'] for line in events.read_text().splitlines()
             if '"kind": "hook", "value": "Stop"' in line]
    if not stops:
        raise RuntimeError('wait for a Stop hook before arming P3')
    deadline = stops[-1] + 7500
    record(events, 'due_armed', {'stop_mono': stops[-1], 'due_mono': deadline})
    while time.monotonic() < deadline:
        time.sleep(min(60, deadline - time.monotonic()))
    result = subprocess.run(['pgrep', '-f', 'tower_msg.py inbox'], capture_output=True, text=True)
    record(events, 'pgrep_2h5m', {'exit': result.returncode, 'pids': result.stdout.split()})
    session = 't082-p3'
    screen = subprocess.run(['tmux', 'capture-pane', '-pt', session, '-S', '-30'],
                            capture_output=True, text=True)
    record(events, 'screen_before_send', screen.stdout)
    send(scratch, 'PROBE_LIFETIME')


def after(scratch, message):
    scratch = Path(scratch).resolve()
    events = scratch / 'events.jsonl'
    stops = [json.loads(line)['mono'] for line in events.read_text().splitlines()
             if '"kind": "hook", "value": "Stop"' in line]
    if not stops:
        raise RuntimeError('wait for a Stop hook before arming send')
    deadline = stops[-1] + 120
    record(events, 'send_armed', {'stop_mono': stops[-1], 'due_mono': deadline})
    while time.monotonic() < deadline:
        time.sleep(min(60, deadline - time.monotonic()))
    screen = subprocess.run(['tmux', 'capture-pane', '-pt', 't082-' +
                             json.loads(events.read_text().splitlines()[0])['value']['probe'],
                             '-S', '-30'], capture_output=True, text=True)
    record(events, 'screen_before_send', screen.stdout)
    send(scratch, message)


def kill_session(scratch):
    scratch = Path(scratch).resolve()
    events = scratch / 'events.jsonl'
    pane = subprocess.check_output(['tmux', 'list-panes', '-t', 't082-p3kill',
                                    '-F', '#{pane_pid}'], text=True).strip()
    process = subprocess.check_output(['ps', '-p', pane, '-o', 'comm='], text=True).strip()
    if process != 'claude':
        raise RuntimeError(f'expected Claude session, found {process}')
    before = subprocess.run(['pgrep', '-f', 'tower_msg.py inbox'], capture_output=True, text=True)
    record(events, 'pgrep_before_sigkill', {'exit': before.returncode, 'pids': before.stdout.split()})
    descendants = []
    for waiter in before.stdout.split():
        current = waiter
        chain = [current]
        while current != pane:
            parent = subprocess.run(['ps', '-p', current, '-o', 'ppid='],
                                    capture_output=True, text=True).stdout.strip()
            if not parent or parent == '1':
                break
            current = parent
            chain.append(current)
        if current == pane:
            descendants.append((waiter, chain))
    if len(descendants) != 1:
        raise RuntimeError(f'expected one waiter under Claude PID {pane}: {descendants}')
    waiter, chain = descendants[0]
    record(events, 'waiter_before_sigkill', {'pid': waiter, 'ancestry': chain})
    os.kill(int(pane), signal.SIGKILL)
    record(events, 'sigkill', int(pane))
    time.sleep(3)
    after = subprocess.run(['pgrep', '-f', 'tower_msg.py inbox'], capture_output=True, text=True)
    record(events, 'pgrep_after_sigkill', {'exit': after.returncode, 'pids': after.stdout.split()})
    record(events, 'waiter_after_sigkill', {'pid': waiter, 'present': waiter in after.stdout.split()})


def watch_timeout(scratch, pid):
    scratch = Path(scratch).resolve()
    events = scratch / 'events.jsonl'
    pid = int(pid)
    record(events, 'waiter_watch_start', pid)
    while True:
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            record(events, 'waiter_exit_observed', pid)
            break
        time.sleep(0.5)
    stops = [json.loads(line)['mono'] for line in events.read_text().splitlines()
             if '"kind": "hook", "value": "Stop"' in line]
    deadline = stops[-1] + 605
    if time.monotonic() < deadline:
        time.sleep(deadline - time.monotonic())
    screen = subprocess.run(['tmux', 'capture-pane', '-pt', 't082-p4', '-S', '-30'],
                            capture_output=True, text=True)
    record(events, 'timeout_screen', screen.stdout)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('operation', choices=('start', 'capture', 'hook', 'send', 'mark',
                                               'due', 'after', 'kill_session', 'watch_timeout'))
    parser.add_argument('arg1', nargs='?')
    parser.add_argument('arg2', nargs='?')
    parser.add_argument('arg3', nargs='?')
    args = parser.parse_args()
    if args.operation == 'start':
        start(args.arg1)
    elif args.operation == 'capture':
        capture(Path(args.arg1))
    elif args.operation == 'hook':
        hook()
    elif args.operation == 'mark':
        mark(args.arg1, args.arg2, args.arg3)
    elif args.operation == 'due':
        due(args.arg1)
    elif args.operation == 'after':
        after(args.arg1, args.arg2)
    elif args.operation == 'kill_session':
        kill_session(args.arg1)
    elif args.operation == 'watch_timeout':
        watch_timeout(args.arg1, args.arg2)
    else:
        send(args.arg1, args.arg2)
