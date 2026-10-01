#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "$ROOT" <<'PY'
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(sys.argv[1])
sys.dont_write_bytecode = True
sys.path.insert(0, str(root / 'lib'))
import tower_msg

with tempfile.TemporaryDirectory() as scratch:
    project = Path(scratch)
    subprocess.run(['git', 'init', '-q', str(project)], check=True)
    (project / '.tower').mkdir()
    os.environ['TOWER_PROJECT_DIR'] = str(project)
    registry = project / '.git/tower/root/agents'
    child = '''import sys, time
sys.dont_write_bytecode = True
sys.path.insert(0, sys.argv[1])
import tower_msg
print(tower_msg.register('builder', 'codex', '1.0'), flush=True)
time.sleep(60)
'''
    owner = subprocess.Popen([sys.executable, '-c', child, str(root / 'lib')],
                             stdout=subprocess.PIPE, text=True)
    try:
        session = owner.stdout.readline().strip()
        assert len(session) == 32
        record = json.loads((registry / 'builder.json').read_text())
        assert record['session'] == session and record['wake'] == 'none'
        assert record['pid'] == owner.pid
        assert tower_msg.owner_status('builder') == (True, 'none')
        assert tower_msg.list_agents()[0]['vendor'] == 'codex'
        assert tower_msg.list_agents()[0]['live'] is True
        try:
            tower_msg.register('builder', 'claude')
        except ValueError as error:
            assert 'codex' in str(error) and str(owner.pid) in str(error)
        else:
            raise AssertionError('second live owner accepted')
        message = tower_msg.publish(tower_msg.mailbox('builder'), 'builder', 'hello', None)
        assert tower_msg.unacknowledged_count('builder') == 1
        tower_msg.acknowledge(tower_msg.mailbox('builder'), message)
        assert tower_msg.unacknowledged_count('builder') == 0
    finally:
        owner.kill()
        owner.wait()
    record['pid'] = os.getpid()
    (registry / 'builder.json').write_text(json.dumps(record))
    assert tower_msg.owner_status('builder') == (False, 'none')
    assert tower_msg.list_agents()[0]['live'] is False
    replacement = tower_msg.register('builder', 'claude')
    assert replacement != session and tower_msg.owner_status('builder') == (True, 'none')
    tower_msg.release('builder', session)
    assert json.loads((registry / 'builder.json').read_text())['session'] == replacement
    tower_msg.release('builder', replacement)
    assert not (registry / 'builder.json').exists()
    cleanup = tower_msg.register('cleanup', 'codex')
    cleanup_entry = registry / 'cleanup.json'
    changed = json.loads(cleanup_entry.read_text())
    changed['session'] = 'f' * 32
    cleanup_entry.write_text(json.dumps(changed))
    assert tower_msg.owner_status('cleanup') == (False, 'none')
    tower_msg.release('cleanup', cleanup)
    assert json.loads(cleanup_entry.read_text())['session'] == 'f' * 32
    assert tower_msg.owner_status('unregistered') == (False, 'none')
    native_child = '''import sys, time
sys.dont_write_bytecode = True
sys.path.insert(0, sys.argv[1])
import tower_msg
print(tower_msg.register('stalenative', 'codex', '1.0', thread='thread-1'), flush=True)
time.sleep(60)
'''
    native_owner = subprocess.Popen([sys.executable, '-c', native_child, str(root / 'lib')],
                                    stdout=subprocess.PIPE, text=True)
    try:
        native_session = native_owner.stdout.readline().strip()
        assert len(native_session) == 32
        native_record = json.loads((registry / 'stalenative.json').read_text())
        assert native_record['session'] == native_session and native_record['wake'] == 'native'
        assert tower_msg.owner_status('stalenative') == (True, 'native')
        agents_output = subprocess.check_output([str(root / 'bin/tower-agents')], text=True)
        assert 'stalenative\tcodex 1.0\tlive\twake:native' in agents_output
    finally:
        native_owner.kill()
        native_owner.wait()
    assert tower_msg.owner_status('stalenative') == (False, 'native')
    native_agent = next(agent for agent in tower_msg.list_agents()
                        if agent['role'] == 'stalenative')
    assert native_agent['live'] is False and native_agent['wake'] == 'native'
    agents_output = subprocess.check_output([str(root / 'bin/tower-agents')], text=True)
    assert 'stalenative\tcodex 1.0\tstale\twake:native' in agents_output
    stub = project / 'stub'
    stub.mkdir()
    marker = project / 'codex-invoked'
    codex = stub / 'codex'
    codex.write_text('#!/bin/sh\n: > "$TOWER_CODEX_MARKER"\n')
    codex.chmod(0o755)
    send_env = dict(os.environ, PATH=str(stub) + os.pathsep + os.environ['PATH'],
                    TOWER_CODEX_MARKER=str(marker))
    sent = subprocess.run([str(root / 'bin/tower-send'), 'stalenative', 'hello'],
                          env=send_env, capture_output=True, text=True)
    assert sent.returncode == 3
    assert 'has no live owner' in sent.stderr
    assert not marker.exists()
print('agents: all integration checks passed')
PY
