#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "$ROOT" <<'PY'
import concurrent.futures
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time

root = Path(sys.argv[1])
env = dict(os.environ, TOWER_ROOT=str(root), TOWER_NO_VERSION_CHECK='1', TOWER_ROLE='reader')
env.pop('TOWER_PROJECT_DIR', None)

def run(cwd, *args, code=0, input=None):
    result = subprocess.run(args, cwd=cwd, env=env, input=input, text=True, capture_output=True)
    assert result.returncode == code, (args, result.returncode, result.stderr)
    return result.stdout.strip()

def tower(cwd, *args, **kwargs):
    return run(cwd, str(root / 'bin/tower'), *args, **kwargs)

with tempfile.TemporaryDirectory() as scratch:
    base = Path(scratch)
    for mode in ('tracked', 'sidecar'):
        project, worktree = base / mode, base / (mode + '-worktree')
        project.mkdir()
        run(project, 'git', 'init', '-q')
        run(project, 'git', 'config', 'user.email', 'test@example.com')
        run(project, 'git', 'config', 'user.name', 'Test')
        state = project / '.tower'
        state.mkdir()
        (state / 'config').write_text('test')
        if mode == 'sidecar':
            run(state, 'git', 'init', '-q')
            (project / '.git/info/exclude').write_text('.tower\n')
            run(state, 'git', 'add', 'config')
            run(state, 'git', '-c', 'user.name=Test', '-c', 'user.email=test@example.com', 'commit', '-qm', 'state')
        run(project, 'git', 'add', '.')
        run(project, 'git', 'commit', '--allow-empty', '-qm', 'project')
        run(project, 'git', 'worktree', 'add', '-qb', 'reader', str(worktree))
        if mode == 'sidecar':
            (worktree / '.tower').symlink_to(state, target_is_directory=True)
        mailbox = project / '.git/tower/root/mailbox/reader'
        message = tower(project, 'send', 'reader', '-', input='hello\n世界\n')
        assert re.fullmatch(r'm-\d{8}T\d{6}Z-[0-9a-f]{32}', message)
        first = tower(worktree, 'inbox', 'read', message)
        assert 'hello\n世界' in first and 'from: "reader"' in first
        assert 'a peer agent, not the user' in first and f'tower inbox ack {message}' in first
        assert tower(worktree, 'inbox', 'read', message) == first
        assert tower(worktree, 'inbox', 'list') == message
        assert (mailbox / 'queued' / message).exists()
        tower(worktree, 'inbox', 'ack', message)
        assert 'already-acknowledged' in tower(project, 'inbox', 'ack', message)
        assert not (mailbox / 'queued' / message).exists()
        assert (mailbox / 'acknowledged' / message).exists()
        assert tower(worktree, 'inbox', 'read', message) == first
        tower(project, 'inbox', 'ack', 'm-20000101T000000Z-' + '0' * 32, code=1)
        tower(worktree, 'inbox', '--wait', '0.1', code=1)
        waiter = subprocess.Popen([str(root / 'bin/tower-inbox'), '--wait', '5'], cwd=worktree, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        time.sleep(0.2)
        arriving = tower(project, 'send', 'reader', '--reply-to', message, 'arrived')
        assert f'reply_to: "{message}"' in tower(project, 'inbox', 'read', arriving)
        output, error = waiter.communicate(timeout=7)
        assert waiter.returncode == 0 and arriving in output, error
        with concurrent.futures.ThreadPoolExecutor(max_workers=20) as pool:
            ids = list(pool.map(lambda i: tower(project, 'send', 'reader', str(i)), range(20)))
            acknowledgements = list(pool.map(lambda _: tower(project, 'inbox', 'ack', arriving), range(20)))
        assert len(set(ids)) == 20
        assert set(tower(worktree, 'inbox').splitlines()) == set(ids)
        assert sum('already-acknowledged' not in result for result in acknowledgements) == 1
        for reserved in ('claimed', 'submitted', 'undeliverable', 'tmp'):
            assert list((mailbox / reserved).iterdir()) == []
        for directory in (project, worktree, state):
            assert run(directory, 'git', 'status', '--porcelain') == ''
        tower(project, 'send', '../escape', 'bad', code=1)
        tower(project, 'inbox', 'read', '../escape', code=1)
        tower(project, 'inbox', '--wait', '-1', code=2)
        tower(project, 'inbox', '--wait', 'nan', code=2)
        tower(project, 'inbox', 'read', code=2)
        env.pop('TOWER_ROLE')
        owner_message = tower(project, 'send', 'other', 'owner message')
        assert 'from: "owner"' in tower(worktree, 'inbox', '--role', 'other', 'read', owner_message)
        tower(project, 'inbox', code=1)
        env['TOWER_ROLE'] = 'reader'
        if mode == 'tracked':
            state.rename(project / 'saved-state')
            assert run(worktree, str(root / 'bin/tower-locate')).splitlines()[-1] == 'copy'
            tower(worktree, 'send', 'reader', 'refuse', code=1)
            tower(worktree, 'inbox', code=1)
print('mailbox: all integration checks passed')
PY
