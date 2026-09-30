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
print('agents: all integration checks passed')
PY
