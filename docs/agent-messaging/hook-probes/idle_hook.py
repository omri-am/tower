#!/usr/bin/env python3
"""Throwaway T020 probe, borrowing T014's operator-controlled PTY harness.

Run from mktemp -d. Inspect events.jsonl before appending one {label,text}
action to actions.jsonl. Never input at tool/permission/choice dialogs.
After confirmed completion, wait 120 seconds, invoke --write in a separate
process, wait another 120 seconds, inspect, then submit a context recall turn.
"""
import importlib.util
import json
import os
import re
from pathlib import Path
import select
import shlex
import shutil
import subprocess
import sys
import time


def record(kind, value):
    with open('events.jsonl', 'a') as log:
        log.write(json.dumps({'at': time.monotonic(), 'utc': time.time(), kind: value}) + '\n')


def main():
    cwd = Path.cwd().resolve()
    assert subprocess.run(['git', 'rev-parse', '--show-toplevel'],
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode != 0
    if sys.argv[1:] == ['--write']:
        target = cwd / 'watched' / 'message.txt'
        assert target.parent.is_dir() and not target.exists()
        target.write_text('External file appeared.\n')
        record('external_write', {'path': str(target), 'pid': os.getpid()})
        return
    if sys.argv[1:2] == ['--record']:
        event = json.loads(sys.argv[2] if len(sys.argv) > 2 else sys.stdin.read())
        record('hook', event)
        if event.get('hook_event_name') == 'FileChanged':
            output = {'systemMessage': 'T020_HOOK_SECRET_71492'}
            record('hook_stdout', output)
            print(json.dumps(output))
        return
    vendor = sys.argv[1]
    assert vendor in ('claude', 'codex')
    assert not Path('events.jsonl').exists()
    config = cwd / 'config'
    config.mkdir()
    (cwd / 'watched').mkdir()
    callback = [sys.executable, str(Path(__file__).resolve()), '--record']
    if vendor == 'claude':
        os.environ['CLAUDE_CONFIG_DIR'] = str(config)
        source = json.loads((Path.home() / '.claude.json').read_text())
        keys = ['hasCompletedOnboarding', 'lastOnboardingVersion', 'oauthAccount']
        (config / '.claude.json').write_text(json.dumps({k: source[k] for k in keys if k in source}))
        hooks = {event: [{'hooks': [{'type': 'command', 'command': shlex.join(callback)}]}]
                 for event in ['SessionStart', 'Stop', 'StopFailure', 'UserPromptSubmit']}
        # The matcher seeds literal paths and filters by basename, hence both entries.
        hooks['FileChanged'] = [{'matcher': 'watched/message.txt|message.txt',
                                 'hooks': [{'type': 'command', 'command': shlex.join(callback)}]}]
        settings = config / 'settings.json'
        settings.write_text(json.dumps({'hooks': hooks}))
        command = [str(Path(os.environ.get('T020_CLAUDE_BINARY', shutil.which('claude'))).resolve()), '--setting-sources', '', '--settings', str(settings),
                   '--permission-mode', 'manual', '--tools', '', '--strict-mcp-config',
                   '--model', 'haiku', '--debug-file', str(cwd / 'debug.log')]
    else:
        source = Path(os.environ.get('CODEX_HOME', str(Path.home() / '.codex')))
        shutil.copyfile(source / 'auth.json', config / 'auth.json')
        (config / 'auth.json').chmod(0o600)
        os.environ['CODEX_HOME'] = str(config)
        command = [str(Path(shutil.which('codex')).resolve()), '--no-daemon',
                   '--model', 'gpt-6-luna', '-c', 'notify=' + json.dumps(callback),
                   '-c', 'approvals_reviewer="user"', '--sandbox', 'read-only']
    command += ['Reply READY. Do not use any tools.']
    harness_path = Path(__file__).resolve().parents[1] / 'probes' / 'terminal_probe.py'
    spec = importlib.util.spec_from_file_location('t014', harness_path)
    harness = importlib.util.module_from_spec(spec)
    sys.dont_write_bytecode = True
    spec.loader.exec_module(harness)
    def capture(kind, value):
        if kind == 'start':
            value['version'] = subprocess.check_output([command[0], '--version'], text=True).strip()
            value['argv'] = command
            value['config'] = str(config)
        record(kind, value)
    harness.record = capture
    # Reuse its continuous drain, operator actions, scratch trust, and bounded cleanup.
    original_read = os.read
    managed_screen = ''
    approved = False
    def read_terminal(fd, size):
        nonlocal managed_screen
        data = original_read(fd, size)
        managed_screen += data.decode('utf-8', errors='replace')
        return data
    original_select = select.select
    def select_terminal(readers, writers, errors, timeout):
        nonlocal approved
        if (vendor == 'claude' and not approved
                and Path('approve-managed-settings').exists()
                and 'Managedsettingsrequireapproval' in re.sub(
                    r'\s+', '', re.sub(r'\x1b\[[0-?]*[ -/]*[@-~]', '', managed_screen))):
            assert Path(os.environ['CLAUDE_CONFIG_DIR']).resolve() == config
            os.write(readers[0], b'\r')
            record('managed_settings_approval', {'config': str(config), 'bytes_hex': '0d'})
            approved = True
        return original_select(readers, writers, errors, timeout)
    select.select = select_terminal
    os.read = read_terminal
    original_exec = os.execvp
    def launch(_command, _args):
        original_exec(command[0], command)
    os.execvp = launch
    harness.main()


if __name__ == '__main__':
    main()
