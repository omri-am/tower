#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "$ROOT" <<'PY'
import concurrent.futures
import fcntl
import json
import os
from pathlib import Path
import re
import signal
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
        message = tower(project, 'send', 'reader', '-', input='hello\n世界\n', code=3)
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
        arriving = tower(project, 'send', 'reader', '--reply-to', message, 'arrived', code=3)
        assert f'reply_to: "{message}"' in tower(project, 'inbox', 'read', arriving)
        output, error = waiter.communicate(timeout=7)
        assert waiter.returncode == 0 and arriving in output, error
        with concurrent.futures.ThreadPoolExecutor(max_workers=20) as pool:
            ids = list(pool.map(lambda i: tower(project, 'send', 'reader', str(i), code=3), range(20)))
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
        owner_message = tower(project, 'send', 'other', 'owner message', code=3)
        assert 'from: "owner"' in tower(worktree, 'inbox', '--role', 'other', 'read', owner_message)
        tower(project, 'inbox', code=1)
        env['TOWER_ROLE'] = 'reader'
        stub_dir = base / (mode + '-bin')
        stub_dir.mkdir()
        stub = stub_dir / 'codex'
        stub.write_text('#!/bin/bash\nprintf "%s\\0" "$@" > "$CODEX_ARGS"\n'
                        'cat "$CODEX_CLAIM_DIR"/*.claim > "$CODEX_CLAIMS"\n'
                        'if [ -n "${CODEX_BLOCK:-}" ]; then\n'
                        '  : > "$CODEX_BLOCK"\n'
                        '  if [ -n "${CODEX_RELEASE:-}" ]; then\n'
                        '    while [ ! -e "$CODEX_RELEASE" ]; do sleep 0.01; done\n'
                        '  else\n    exec sleep 10\n  fi\nfi\n'
                        'echo "stub diagnostic" >&2\nexit "$CODEX_EXIT"\n')
        stub.chmod(0o755)
        argv_file = base / (mode + '-argv')
        env.update(PATH=str(stub_dir) + os.pathsep + env['PATH'], CODEX_ARGS=str(argv_file))
        for role, vendor, thread, code in (('native', 'codex', 'exact session name', 0),
                                           ('failing', 'codex', 'thread-id', 1),
                                           ('unset', 'codex', '', 4), ('claude', 'claude', 'thread-id', 4)):
            env['CODEX_EXIT'] = '9' if code == 1 else '0'
            env['CODEX_CLAIM_DIR'] = str(mailbox.parent / role / 'claimed')
            env['CODEX_CLAIMS'] = str(base / (mode + '-claims'))
            argv_file.unlink(missing_ok=True)
            command = [str(root / 'bin/tower-register'), role, '--vendor', vendor]
            if thread:
                command += ['--thread', thread]
            owner = subprocess.Popen(command, cwd=project, env=env, text=True,
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                session = owner.stdout.readline().strip()
                assert len(session) == 32
                record = json.loads((project / '.git/tower/root/agents' / (role + '.json')).read_text())
                wake = 'native' if code != 4 else 'none'
                assert record['thread'] == thread and record['wake'] == wake
                assert f'{role}\t{vendor}\tlive\twake:{wake}' in tower(project, 'agents')
                result = subprocess.run([str(root / 'bin/tower'), 'send', role, 'hello\n世界\n'],
                                        cwd=project, env=env, text=True, capture_output=True)
                assert result.returncode == code, result.stderr
                message = result.stdout.strip()
                assert re.fullmatch(r'm-\d{8}T\d{6}Z-[0-9a-f]{32}', message)
                box = mailbox.parent / role
                assert list((box / 'claimed').iterdir()) == list((box / 'acknowledged').iterdir()) == []
                stored = tower(worktree, 'inbox', '--role', role, 'read', message)
                assert 'hello\n世界' in stored
                if code == 4:
                    assert f'queued; {role} cannot be woken automatically' in result.stderr
                    assert (box / 'queued' / message).is_file() and not argv_file.exists()
                else:
                    argv = argv_file.read_bytes().decode().split('\0')[:-1]
                    assert argv[:4] == ['queue', '--thread', thread, '--message'] and len(argv) == 5
                    assert argv[4].startswith(f'[tower message {message} ') and argv[4].endswith('hello\n世界\n')
                    if code == 1:
                        assert (box / 'queued' / message).is_file()
                        assert 'redelivery: 1' in stored and '; possibly a duplicate]\n' in stored
                        log = (box / 'delivery.log').read_text().splitlines()
                        assert len(log) == 1 and f'{message} exit=9 stub diagnostic' in log[0]
                        assert 'stub diagnostic' in result.stderr
                        with concurrent.futures.ThreadPoolExecutor(max_workers=5) as pool:
                            retried = list(pool.map(lambda i: tower(project, 'send', role, str(i), code=1), range(5)))
                        assert set(path.name for path in (box / 'queued').iterdir()) == {message, *retried}
                        assert not list((box / 'claimed').iterdir()) and not list((box / 'acknowledged').iterdir())
                        stored = tower(project, 'inbox', '--role', role, 'read', message)
                        assert 'redelivery: 6' in stored and stored.count('; possibly a duplicate]') == 1
                        env['CODEX_EXIT'] = '0'
                        recovered = tower(project, 'send', role, 'retry succeeded')
                        assert all((box / 'submitted' / item).is_file() for item in [message, *retried, recovered])
                        assert not list((box / 'queued').iterdir()) and not list((box / 'claimed').iterdir())
                        first = 'm-20000101T000000Z-' + '1' * 32
                        (box / 'queued' / first).write_text((box / 'submitted' / message).read_text().replace(message, first))
                        marker, release = base / (mode + '-batch-running'), base / (mode + '-batch-release')
                        sender = subprocess.Popen([sys.executable, str(root / 'lib/tower_msg.py'),
                                                   'send', role, 'second in batch'], cwd=project,
                                                  env=dict(env, CODEX_BLOCK=str(marker), CODEX_RELEASE=str(release)),
                                                  text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                        try:
                            pending = sender.stdout.readline().strip()
                            deadline = time.monotonic() + 5
                            while not marker.exists() and sender.poll() is None and time.monotonic() < deadline:
                                time.sleep(0.01)
                            assert marker.exists(), 'batch stub did not start'
                            assert (box / 'claimed' / first).is_file() and (box / 'queued' / pending).is_file()
                            owner.terminate()
                            owner.communicate(timeout=5)
                            owner = subprocess.Popen([str(root / 'bin/tower-register'), role,
                                                      '--vendor', 'claude', '--thread', 'x'], cwd=project,
                                                     env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                            assert len(owner.stdout.readline().strip()) == 32
                            release.touch()
                            output, error = sender.communicate(timeout=5)
                            assert sender.returncode == 4, ('mid-batch ownership exit', sender.returncode)
                            assert f'queued; {role} cannot be woken automatically' in error
                            assert (box / 'submitted' / first).is_file() and (box / 'queued' / pending).is_file()
                            assert not list((box / 'claimed').iterdir())
                        finally:
                            release.touch()
                            if sender.poll() is None:
                                sender.kill()
                                sender.communicate(timeout=5)
                    else:
                        claims = Path(env['CODEX_CLAIMS']).read_text().splitlines()
                        assert f'claimant={session}' in claims and any(line.startswith('at=') for line in claims)
                        assert (box / 'submitted' / message).is_file()
                        assert (box / 'submitted' / (message + '.submitted')).read_text().startswith('at=')
                        assert tower(worktree, 'inbox', '--role', role, 'list') == message
                        assert tower(worktree, 'inbox', '--role', role, '--wait', '0') == message
                        assert f'{role}\t{vendor}\tlive\twake:native\tunacknowledged:1' in tower(project, 'agents')
                        with concurrent.futures.ThreadPoolExecutor(max_workers=20) as pool:
                            acks = list(pool.map(lambda _: tower(project, 'inbox', '--role', role, 'ack', message), range(20)))
                        assert sum('already-acknowledged' not in ack for ack in acks) == 1
                        assert (box / 'acknowledged' / message).is_file() and not list((box / 'submitted').iterdir())
                        marker = base / (mode + '-running')
                        sender = subprocess.Popen([sys.executable, str(root / 'lib/tower_msg.py'),
                                                   'send', role, 'interrupt me'], cwd=project,
                                                  env=dict(env, CODEX_BLOCK=str(marker)), text=True,
                                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                        try:
                            interrupted = sender.stdout.readline().strip()
                            deadline = time.monotonic() + 5
                            while not marker.exists() and sender.poll() is None and time.monotonic() < deadline:
                                time.sleep(0.01)
                            assert marker.exists(), 'stub did not start'
                            sender.send_signal(signal.SIGINT)
                            output, error = sender.communicate(timeout=5)
                            assert sender.returncode != 0 and 'KeyboardInterrupt' in error
                            assert (box / 'queued' / interrupted).is_file(), 'interrupted message was not requeued'
                            stored = (box / 'queued' / interrupted).read_text()
                            assert 'redelivery: 1' in stored and '; possibly a duplicate]' in stored
                            assert not list((box / 'claimed').iterdir())
                            assert f'{interrupted} exit=130 codex queue interrupted' in (box / 'delivery.log').read_text()
                        finally:
                            if sender.poll() is None:
                                sender.kill()
                                sender.communicate(timeout=5)
                        nul = tower(project, 'send', role, '-', input='a\0b', code=1)
                        assert (box / 'queued' / nul).is_file(), 'NUL message was not requeued'
                        assert 'redelivery: 1' in (box / 'queued' / nul).read_text()
                        assert not list((box / 'claimed').iterdir())
                        assert f'{nul} exit=127 embedded null byte' in (box / 'delivery.log').read_text()
                        result = subprocess.run([str(root / 'bin/tower'), 'send', role, 'valid after NUL'],
                                                cwd=project, env=env, text=True, capture_output=True)
                        assert result.returncode == 0, ('own message delivery exit', result.returncode)
                        assert (box / 'submitted' / result.stdout.strip()).is_file()
                        assert (box / 'queued' / nul).is_file() and not list((box / 'claimed').iterdir())
                        argv_file.unlink()
                        # Signal the delivery lock attempt so ownership can be swapped deterministically.
                        child = """import fcntl, runpy, sys
flock = fcntl.flock
def signal_delivery_lock(stream, operation):
    if stream.name.endswith('/delivery.lock'):
        print('waiting for delivery lock', flush=True)
    return flock(stream, operation)
fcntl.flock = signal_delivery_lock
sys.argv = sys.argv[1:]
runpy.run_path(sys.argv[0], run_name='__main__')
"""
                        with (box / 'delivery.lock').open('a') as lock:
                            fcntl.flock(lock, fcntl.LOCK_EX)
                            sender = subprocess.Popen([sys.executable, '-c', child, str(root / 'lib/tower_msg.py'),
                                                       'send', role, 'owner changed'], cwd=project, env=env,
                                                      text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                            try:
                                pending = sender.stdout.readline().strip()
                                assert sender.stdout.readline().strip() == 'waiting for delivery lock'
                                assert (box / 'queued' / pending).is_file()
                                owner.terminate()
                                owner.communicate(timeout=5)
                                owner = subprocess.Popen([str(root / 'bin/tower-register'), role,
                                                          '--vendor', 'claude', '--thread', 'x'], cwd=project,
                                                         env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                                assert len(owner.stdout.readline().strip()) == 32
                                fcntl.flock(lock, fcntl.LOCK_UN)
                                output, error = sender.communicate(timeout=5)
                                assert sender.returncode == 4, ('owner replacement exit', sender.returncode, error)
                                assert f'queued; {role} cannot be woken automatically' in error
                                assert not argv_file.exists() and (box / 'queued' / pending).is_file()
                            finally:
                                if sender.poll() is None:
                                    sender.kill()
                                    sender.communicate(timeout=5)
            finally:
                owner.terminate()
                owner.communicate(timeout=5)
        for directory in (project, worktree, state):
            assert run(directory, 'git', 'status', '--porcelain') == ''
        if mode == 'tracked':
            state.rename(project / 'saved-state')
            assert run(worktree, str(root / 'bin/tower-locate')).splitlines()[-1] == 'copy'
            tower(worktree, 'send', 'reader', 'refuse', code=1)
            tower(worktree, 'inbox', code=1)
print('mailbox: all integration checks passed')
PY
