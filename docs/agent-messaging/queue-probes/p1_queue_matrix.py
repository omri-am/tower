"""Throwaway T053 queue delivery probe. Run only from a fresh T038 scratch directory."""
import datetime
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import time
import uuid

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / 'lifetime-probes'))
sys.path.insert(0, str(HERE.parent / 'sandbox-probes'))
from common import finish, guard, identity, parser, pump_for
from p2_live_session import quit_tui


RELEASES = Path.home() / '.codex/packages/standalone/releases'
V164 = RELEASES / '0.164.0-aarch64-apple-darwin/bin/codex'
OLD = RELEASES / '0.162.1-aarch64-apple-darwin/bin/codex'
SYSTEM = {'HOME': str(Path.home()), 'PATH': '/usr/bin:/bin:/usr/sbin:/sbin'}
CASES = (
    ('caller_path', 'caller', 'codex', (), 'live'),
    ('clean_local_bin', 'clean', 'codex', (), 'live'),
    ('clean_enable_hooks', 'clean', 'codex', ('--enable', 'hooks'), 'live'),
    ('clean_bypass_hook_trust', 'clean', 'codex', ('--dangerously-bypass-hook-trust',), 'live'),
    ('clean_config_override', 'clean', 'codex', ('-c', 'check_for_update_on_startup=false'), 'live'),
    ('clean_wrapper', 'clean_wrapper', 'codex', (), 'live'),
    ('v0_164_0', 'system', str(V164), (), 'live'),
    ('v0_164_0_enable_hooks', 'system', str(V164), ('--enable', 'hooks'), 'live'),
    ('v0_162_1', 'system', str(OLD), (), 'live'),
    ('v0_162_1_enable_hooks', 'system', str(OLD), ('--enable', 'hooks'), 'live'),
    ('remote_default', 'clean', 'codex', ('--remote', 'unix://'), 'live'),
    ('remote_socket_path', 'clean', 'codex', ('--remote', 'unix://{socket}'), 'live'),
    ('caller_remote_default', 'caller', 'codex', ('--remote', 'unix://'), 'live'),
    ('remote_missing_socket', 'clean', 'codex', ('--remote', 'unix://{missing}'), 'live'),
    ('missing_thread', 'clean', 'codex', (), 'missing'),
    ('missing_thread_remote', 'clean', 'codex', ('--remote', 'unix://'), 'missing'),
    ('caller_missing_thread', 'caller', 'codex', (), 'missing'),
)


def caller_environment(path):
    if not path:
        return None
    result = {}
    for entry in Path(path).read_bytes().split(b'\0'):
        if b'=' in entry:
            key, value = entry.split(b'=', 1)
            result[os.fsdecode(key)] = os.fsdecode(value)
    return result


def environment_log(env):
    # The caller's environment holds secrets, and the logs are committed to a public repository.
    return {'names': sorted(env)}


def executable_log(exe, env):
    path = exe if os.path.isabs(exe) else shutil.which(exe, path=env.get('PATH', ''))
    path = os.path.abspath(path) if path else None
    result = {'path': path, 'realpath': os.path.realpath(path) if path else None}
    if not path or not os.access(path, os.X_OK):
        return result
    with open(path, 'rb') as source:
        script = source.read(2) == b'#!'
    if script:
        wrapper_dir = str(Path.home() / '.superset/bin')
        for directory in env.get('PATH', '').split(os.pathsep):
            if directory == wrapper_dir:
                continue
            candidate = Path(directory or '.') / 'codex'
            if candidate.is_file() and os.access(str(candidate), os.X_OK):
                result['wrapper_binary'] = str(candidate.absolute())
                result['wrapper_binary_realpath'] = str(candidate.resolve())
                break
    binary = result.get('wrapper_binary_realpath', result['realpath'])
    if binary:
        try:
            version = subprocess.run([binary, '--version'], env=SYSTEM, cwd='/',
                                     stdin=subprocess.DEVNULL, capture_output=True,
                                     text=True, timeout=10)
            result['version'] = {'returncode': version.returncode,
                                 'stdout': version.stdout, 'stderr': version.stderr}
        except (OSError, subprocess.TimeoutExpired) as error:
            result['version'] = {'error': repr(error)}
    return result


def process_rows(args, columns, matches):
    result = subprocess.run(args, env=SYSTEM, stdin=subprocess.DEVNULL,
                            capture_output=True, text=True, timeout=10)
    rows = []
    for line in result.stdout.splitlines()[1:]:
        parts = line.split(None, columns - 1)
        if len(parts) == columns and matches(parts):
            rows.append(line.strip())
    return {'rows': rows, 'returncode': result.returncode, 'stderr': result.stderr}


def daemon_state(run, stage):
    result = subprocess.run([run.codex, 'app-server', 'daemon', 'version'],
                            env=SYSTEM, cwd=str(run.cwd), stdin=subprocess.DEVNULL,
                            capture_output=True, text=True, timeout=20)
    parsed = json.loads(result.stdout) if result.returncode == 0 else None
    processes = process_rows(['ps', '-axo', 'pid,ppid,lstart,command'], 8,
                            lambda row: len(row[7].split()) >= 2 and
                            row[7].split()[0].endswith('/codex') and
                            row[7].split()[1] == 'app-server')
    socket = Path(os.environ.get('CODEX_HOME', str(Path.home() / '.codex')))
    socket = socket / 'app-server-control/app-server-control.sock'
    run.log('daemon_state', {'stage': stage, 'returncode': result.returncode,
                            'stdout': result.stdout, 'stderr': result.stderr,
                            'json': parsed, 'processes': processes,
                            'socket_symlink': os.readlink(socket) if socket.is_symlink() else None})
    return parsed.get('status') == 'running' if parsed else False, parsed.get('socketPath') if parsed else None


def tui_processes(run, child):
    processes = process_rows(['ps', '-axo', 'pid,ppid,pgid,command'], 4,
                             lambda row: row[2] == str(child['pid']))
    holders = []
    for row in processes['rows']:
        pid = row.split(None, 1)[0]
        result = subprocess.run(['lsof', '-a', '-U', '-p', pid], env=SYSTEM,
                                stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=10)
        holders.append({'pid': pid, 'returncode': result.returncode,
                        'stdout': result.stdout, 'stderr': result.stderr})
    run.log('tui_processes', {'processes': processes, 'sockets': holders})


def find_rollout(run, thread):
    home = Path(os.environ.get('CODEX_HOME', str(Path.home() / '.codex')))
    end = time.monotonic() + 15
    while time.monotonic() < end:
        found = list((home / 'sessions').glob('*/*/*/rollout-*-{0}.jsonl'.format(thread)))
        if found:
            run.log('rollout_path', str(found[0]))
            return found[0]
        run.pump(seconds=0.1)
    raise TimeoutError('rollout not found for ' + thread)


def rollout_records(path):
    lines = path.read_text(errors='replace').splitlines()
    records = []
    for index, line in enumerate(lines):
        try:
            entry = json.loads(line)
        except json.JSONDecodeError:
            if index == len(lines) - 1:
                break
            raise
        payload = entry.get('payload') or {}
        record = {'index': index, 'timestamp': entry.get('timestamp'),
                  'type': entry.get('type'), 'payload_type': payload.get('type'),
                  'turn_id': payload.get('turn_id') or payload.get('turnId')}
        if record['type'] == 'response_item' and payload.get('role') == 'user':
            record['texts'] = [part.get('text', '') for part in payload.get('content', [])
                               if part.get('type') == 'input_text']
        elif record['type'] == 'event_msg' and record['payload_type'] == 'user_message':
            record['texts'] = [payload.get('message', '')]
        if record['payload_type'] == 'task_complete':
            record['last_agent_message'] = payload.get('last_agent_message', '')
        records.append(record)
    return records


def filtered_record(record):
    result = {key: record[key] for key in ('index', 'timestamp', 'type', 'payload_type', 'turn_id')}
    for field in ('texts', 'last_agent_message'):
        if field in record:
            values = record[field] if field == 'texts' else [record[field]]
            safe = [value if any(marker in value for marker in ('READY', 'Q_', 'BUSY_'))
                    else {'length': len(value)} for value in values]
            result[field] = safe if field == 'texts' else safe[0]
    return result


def rollout_summary(records):
    return [filtered_record(record) for record in records
            if record['payload_type'] in ('task_started', 'task_complete') or 'texts' in record]


def turn_records(records, message, marker):
    user = next((record for record in records if message in record.get('texts', [])), None)
    if not user:
        return None, None, None
    started = next((record for record in reversed(records[:user['index']])
                    if record['payload_type'] == 'task_started'), None)
    completed = next((record for record in records[user['index'] + 1:]
                      if record['payload_type'] == 'task_complete' and
                      marker in record.get('last_agent_message', '')), None)
    return user, started, completed


def first_completion_after(records, user):
    if user is None:
        return None
    return next((record for record in records[user['index'] + 1:]
                 if record['payload_type'] == 'task_complete'), None)


def notify_time(run, message, marker):
    for event in run.notifies:
        payload = event.get('payload', {})
        if message in payload.get('input-messages', []) and marker in str(payload.get('last-assistant-message', '')):
            return event.get('time')
    return None


def rollout_holders(path):
    result = subprocess.run(['lsof', '-Fpc', '--', str(path)], env=SYSTEM,
                            stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=10)
    holders = []
    for line in result.stdout.splitlines():
        if line.startswith('p'):
            holders.append({'pid': line[1:], 'command': None})
        elif line.startswith('c') and holders:
            holders[-1]['command'] = line[1:]
    return holders


def seconds_from_exit(timestamp, exit_time):
    if not timestamp:
        return None
    received = datetime.datetime.fromisoformat(timestamp.replace('Z', '+00:00'))
    return received.timestamp() - exit_time


def completed_by(record, wall_time):
    if not record or not record['timestamp']:
        return None
    return seconds_from_exit(record['timestamp'], wall_time) <= 0


def kill_queue_group(proc):
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass


def run_queue(run, name, env, exe, extra, thread, marker, phase='idle', resolution=None):
    message = 'Reply ' + marker + '. No tools.'
    argv = [exe, 'queue', *extra, '--thread', thread, '--message', message]
    resolution = resolution or executable_log(exe, env)
    if not resolution['path'] or not os.access(resolution['path'], os.X_OK):
        run.log('case_skipped', {'name': name, 'phase': phase, 'reason': 'executable unavailable',
                                 'environment': environment_log(env), 'resolution': resolution})
        return None
    run.log('queue_case_start', {'name': name, 'phase': phase, 'argv': argv,
                                 'environment': environment_log(env), 'resolution': resolution,
                                 'wall_time': time.time()})
    started = time.monotonic()
    proc = subprocess.Popen(argv, env=env, cwd=str(run.cwd), stdin=subprocess.DEVNULL,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                            start_new_session=True)
    start_wall_time = time.time()
    timed_out = False
    try:
        while True:
            try:
                stdout, stderr = proc.communicate(timeout=0.1)
                break
            except subprocess.TimeoutExpired:
                run.pump(seconds=0.1)
            if time.monotonic() - started >= 30:
                kill_queue_group(proc)
                timed_out = True
                try:
                    stdout, stderr = proc.communicate(timeout=2)
                except subprocess.TimeoutExpired as pending:
                    stdout, stderr = pending.stdout or b'', pending.stderr or b''
                    stdout = stdout.decode(errors='replace') if isinstance(stdout, bytes) else stdout
                    stderr = stderr.decode(errors='replace') if isinstance(stderr, bytes) else stderr
                    proc.stdout.close()
                    proc.stderr.close()
                    proc.wait(timeout=2)
                break
    except BaseException:
        if proc.poll() is None:
            kill_queue_group(proc)
        proc.stdout.close()
        proc.stderr.close()
        proc.wait(timeout=2)
        raise
    result = {'name': name, 'phase': phase, 'returncode': proc.returncode,
              'stdout': stdout, 'stderr': stderr, 'elapsed_seconds': time.monotonic() - started,
              'timed_out': timed_out, 'start_wall_time': start_wall_time,
              'exit_wall_time': time.time()}
    run.log('queue_case_result', result)
    return result


def receipt(run, path, name, message, marker, exit_time, timeout):
    end = time.monotonic() + timeout
    user = started = completed = None
    while time.monotonic() < end:
        user, started, completed = turn_records(rollout_records(path), message, marker)
        if user and completed:
            break
        run.pump(seconds=0.1)
    pump_for(run, 2)
    matched_at = notify_time(run, message, marker)
    result = {'name': name, 'received': bool(user and completed),
              'user': filtered_record(user) if user else None,
              'task_started': filtered_record(started) if started else None,
              'task_complete': filtered_record(completed) if completed else None,
              'notify_matched': matched_at is not None, 'notify_time': matched_at,
              'seconds_exit_to_user': seconds_from_exit(user['timestamp'], exit_time) if user else None,
              'rollout_holders': rollout_holders(path)}
    run.log('receipt', result)
    return result


def busy_phase(run, child, path, case, env, exe, extra, thread, timeout):
    name = case
    resolution = executable_log(exe, env)
    busy_marker = 'BUSY_' + name.upper()
    prompt = 'Count silently from 1 to 300, then reply ' + busy_marker + '. No tools.'
    child['prompt'], child['prompt_sent'] = prompt, False
    end = time.monotonic() + timeout
    busy_user = None
    while time.monotonic() < end:
        records = rollout_records(path)
        busy_user, _, _ = turn_records(records, prompt, busy_marker)
        busy_done = first_completion_after(records, busy_user)
        if busy_user and not any(record['payload_type'] == 'task_complete'
                                 for record in records[busy_user['index'] + 1:]):
            break
        if busy_done:
            run.log('busy_skipped', {'name': name, 'reason': 'busy turn completed before queue'})
            return
        run.pump(seconds=0.1)
    else:
        run.log('busy_skipped', {'name': name, 'reason': 'busy user record not observed in time'})
        return
    marker = 'Q_' + name.upper() + '_DURING_BUSY'
    message = 'Reply ' + marker + '. No tools.'
    result = run_queue(run, name, env, exe, extra, thread, marker, 'busy', resolution)
    records = rollout_records(path)
    busy_user, _, _ = turn_records(records, prompt, busy_marker)
    busy_done = first_completion_after(records, busy_user)
    run.log('busy_queue', {'name': name, 'result': result,
                            'busy_completed_before_start': (completed_by(busy_done, result['start_wall_time'])
                                                            if result else None),
                            'busy_completed_before_exit': (completed_by(busy_done, result['exit_wall_time'])
                                                           if result else None)})
    if result is None:
        return
    end = time.monotonic() + timeout
    queued_user = queued_done = None
    while time.monotonic() < end:
        records = rollout_records(path)
        busy_user, _, _ = turn_records(records, prompt, busy_marker)
        busy_done = first_completion_after(records, busy_user)
        queued_user, _, queued_done = turn_records(records, message, marker)
        if busy_done and queued_done:
            break
        run.pump(seconds=0.1)
    pump_for(run, 2)
    run.log('busy_result', {'name': name,
                            'busy_user': filtered_record(busy_user) if busy_user else None,
                            'busy_task_complete': filtered_record(busy_done) if busy_done else None,
                            'queued_user': filtered_record(queued_user) if queued_user else None,
                            'queued_task_complete': filtered_record(queued_done) if queued_done else None,
                            'steered': (queued_user['index'] < busy_done['index']
                                        if queued_user and busy_done else None),
                            'same_turn': (queued_done['turn_id'] == busy_done['turn_id']
                                          if queued_done and busy_done and queued_done['turn_id']
                                          and busy_done['turn_id'] else None),
                            'notify_matched': notify_time(run, message, marker) is not None})


def main():
    options = parser('T053 queue matrix')
    options.add_argument('--caller-env')
    options.add_argument('--receipt-timeout', type=float, default=120)
    args = options.parse_args()
    run, _ = guard('p1_queue_matrix', max(args.deadline, 2700))
    try:
        home = str(Path.home())
        clean_path = home + '/.local/bin:' + SYSTEM['PATH']
        environments = {'clean': {'HOME': home, 'PATH': clean_path},
                        'clean_wrapper': {'HOME': home, 'PATH': home + '/.superset/bin:' + clean_path},
                        'system': SYSTEM, 'caller': caller_environment(args.caller_env)}
        running, socket = daemon_state(run, 'start')
        run.log('daemon_observed', {'running': running, 'socketPath': socket})
        socket = socket or home + '/.codex/app-server-control/app-server-control.sock'
        # Codex 0.165.0 opens a hook-trust selector at startup even with hooks disabled (runs tmp.zo8Im3ZW,
        # tmp.pP15AHYS). The bypass skips it without an answer, as the Superset wrapper does for real sessions.
        child = run.launch('Reply READY. No tools.',
                           extra=('--disable', 'hooks', '--disable', 'codex_hooks',
                                  '--dangerously-bypass-hook-trust'))
        event = run.wait_marker('READY', child['prompt'])
        thread = run.thread_id(event)
        path = find_rollout(run, thread)
        tui_processes(run, child)
        results = {}
        for name, env_key, exe, extra, kind in CASES:
            env = environments[env_key]
            if env is None:
                run.log('case_skipped', {'name': name, 'reason': 'caller environment absent',
                                         'environment': None, 'resolution': None})
                continue
            extra = tuple(part.format(socket=socket, missing=str(run.cwd.parent / 'no-such.sock'))
                          for part in extra)
            target = thread if kind == 'live' else str(uuid.uuid4())
            marker = 'Q_' + name.upper()
            result = run_queue(run, name, env, exe, extra, target, marker)
            if result is None:
                continue
            observed = None
            if kind == 'live' and result['returncode'] == 0:
                observed = receipt(run, path, name, 'Reply ' + marker + '. No tools.',
                                   marker, result['exit_wall_time'], args.receipt_timeout)
            results[name] = {'result': result, 'receipt': observed,
                             'message': 'Reply ' + marker + '. No tools.', 'marker': marker,
                             'env': env, 'exe': exe, 'extra': extra}
        late = {}
        for name, item in results.items():
            if item['result']['returncode'] == 0 and not (item['receipt'] and item['receipt']['received']):
                user, started, completed = turn_records(rollout_records(path), item['message'], item['marker'])
                late[name] = {'received': bool(user and completed),
                              'user': filtered_record(user) if user else None,
                              'task_started': filtered_record(started) if started else None,
                              'task_complete': filtered_record(completed) if completed else None,
                              'notify_matched': notify_time(run, item['message'], item['marker']) is not None}
        run.log('late_receipts', late)
        for name in ('remote_default', 'clean_local_bin'):
            item = results.get(name)
            received = (item and ((item['receipt'] and item['receipt']['received']) or
                                  late.get(name, {}).get('received')))
            if received:
                busy_phase(run, child, path, name, item['env'], item['exe'],
                           item['extra'], thread, args.receipt_timeout)
        quit_tui(run, child)
        daemon_state(run, 'end')
        run.log('rollout_summary', rollout_summary(rollout_records(path)))
        observed = {name: (late[name] if late.get(name, {}).get('received') else item['receipt'])
                    for name, item in results.items()}
        run.log('summary', {
            name: {'returncode': results[name]['result']['returncode'] if name in results else None,
                   'first_stderr_line': (next(iter(results[name]['result']['stderr'].splitlines()), None)
                                         if name in results else None),
                   'received': bool(observed[name] and observed[name]['received'])
                   if name in results else False,
                   'notify_matched': bool(observed[name] and observed[name]['notify_matched'])
                   if name in results else False}
            for name, _, _, _, _ in CASES})
    except BaseException as error:
        run.log('exception', repr(error))
        raise
    finally:
        try:
            run.stop()
        finally:
            finish(run)


if __name__ == '__main__':
    main()
