"""Throwaway T031 listing probe. Run only from a mktemp -d directory.

For live runs set CODEX_BIN=/Users/omriam/.codex/packages/standalone/releases/0.159.3-aarch64-apple-darwin/bin/codex.
"""
import json
import os
from pathlib import Path
import select
import signal
import subprocess
import time


class Client:
    def __init__(self, run, transport='stdio'):
        self.run = run
        args = [run.codex, 'app-server', '--stdio'] if transport == 'stdio' else [
            run.codex, 'app-server', 'proxy']
        self.process = subprocess.Popen(args, cwd=str(run.cwd), stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                        bufsize=0, start_new_session=True)
        self.pending = b''
        self.number = 0
        run.log('app_client_start', {'transport': transport, 'pid': self.process.pid, 'argv': args})
        try:
            reply = self.request('initialize', {'clientInfo': {'name': 'tower-t031-probe', 'version': '0.1.0'}})
            if 'error' in reply:
                raise RuntimeError('initialize: ' + str(reply['error']))
            self.process.stdin.write(b'{"method":"initialized"}\n')
            self.process.stdin.flush()
        except (OSError, RuntimeError, TimeoutError):
            self.close()
            raise

    def request(self, method, params):
        self.run.check_time()
        self.number += 1
        number = self.number
        message = {'id': number, 'method': method, 'params': params}
        self.run.log('app_send', message)
        self.process.stdin.write((json.dumps(message) + '\n').encode())
        self.process.stdin.flush()
        until = min(self.run.deadline, time.monotonic() + 20)
        while time.monotonic() < until:
            if self.process.poll() is not None:
                raise RuntimeError('app client exited ' + str(self.process.returncode))
            if not select.select([self.process.stdout], [], [], 0.2)[0]:
                continue
            self.pending += os.read(self.process.stdout.fileno(), 65536)
            while b'\n' in self.pending:
                line, self.pending = self.pending.split(b'\n', 1)
                event = json.loads(line)
                if event.get('id') == number:
                    if 'error' in event:
                        self.run.log('app_error', {'method': method, 'error': event['error']})
                    return event
        raise TimeoutError(method)

    def list_for_cwd(self, owned_ids):
        all_local = []
        cursor = None
        for _ in range(20):
            params = {'cwd': str(self.run.cwd), 'limit': 100}
            if cursor:
                params['cursor'] = cursor
            reply = self.request('thread/list', params)
            if 'error' in reply:
                raise RuntimeError('thread/list: ' + str(reply['error']))
            result = reply.get('result', {})
            records = result.get('data', [])
            local = [record for record in records if record.get('cwd') == str(self.run.cwd)]
            self.run.log('thread_list_page', {'total': len(records), 'local': local,
                                               'other_count': len(records)-len(local)})
            all_local.extend(local)
            cursor = result.get('nextCursor')
            if not cursor:
                break
        if cursor:
            raise RuntimeError('thread/list has more than 20 pages; result incomplete')
        loaded = []
        cursor = None
        for _ in range(20):
            params = {'limit': 1000}
            if cursor:
                params['cursor'] = cursor
            loaded_reply = self.request('thread/loaded/list', params)
            if 'error' in loaded_reply:
                raise RuntimeError('thread/loaded/list: ' + str(loaded_reply['error']))
            loaded.extend(loaded_reply.get('result', {}).get('data', []))
            cursor = loaded_reply.get('result', {}).get('nextCursor')
            if not cursor:
                break
        if cursor:
            raise RuntimeError('thread/loaded/list has more than 20 pages; result incomplete')
        self.run.log('thread_loaded_list', {'total_count': len(loaded),
                                            'own_ids': [item for item in loaded if item in owned_ids]})
        for thread in owned_ids:
            reply = self.request('thread/read', {'threadId': thread, 'includeTurns': False})
            record = reply.get('result', {}).get('thread')
            self.run.log('thread_read_own', record if record and record.get('cwd') == str(self.run.cwd)
                         else {'id': thread, 'matched_cwd': False, 'error': reply.get('error')})
        return all_local

    def close(self):
        pid = self.process.pid
        if self.process.poll() is None:
            try:
                os.killpg(pid, signal.SIGTERM)
            except OSError as error:
                self.run.log('killpg_error', {'pid': pid, 'signal': 'SIGTERM',
                                               'error': repr(error)})
        try:
            self.process.communicate(timeout=2)
        except subprocess.TimeoutExpired:
            if self.process.poll() is None:
                self.run.log('reap_timeout', {'pid': pid, 'after_signal': 'SIGTERM'})
                try:
                    os.killpg(pid, signal.SIGKILL)
                except OSError as error:
                    self.run.log('killpg_error', {'pid': pid, 'signal': 'SIGKILL',
                                                   'error': repr(error)})
            else:
                self.run.log('pipe_drain_timeout', {'pid': pid, 'after_signal': 'SIGTERM'})
            try:
                self.process.communicate(timeout=1)
            except subprocess.TimeoutExpired:
                label = 'reap_timeout' if self.process.poll() is None else 'pipe_drain_timeout'
                self.run.log(label, {'pid': pid, 'after_signal': 'SIGKILL'})
        self.run.log('app_client_stop', {'pid': pid, 'returncode': self.process.poll(),
                                         'reaped': self.process.returncode is not None})


def schema_excerpt(run):
    import tempfile
    run.check_time()
    with tempfile.TemporaryDirectory(dir=str(run.cwd)) as directory:
        result = subprocess.run([run.codex, 'app-server', 'generate-json-schema',
                                 '--out', directory], capture_output=True, text=True,
                                timeout=min(30, max(1, run.deadline-time.monotonic())))
        run.log('schema_generation', {'returncode': result.returncode,
                                      'stdout': result.stdout, 'stderr': result.stderr})
        root = Path(directory) / 'v2'
        for method, names in {'thread/list': ('ThreadListParams', 'ThreadListResponse'),
                              'thread/loaded/list': ('ThreadLoadedListParams', 'ThreadLoadedListResponse'),
                              'thread/read': ('ThreadReadParams', 'ThreadReadResponse')}.items():
            excerpts = {}
            for name in names:
                path = root / (name + '.json')
                if path.exists():
                    schema = json.loads(path.read_text())
                    excerpts[name] = {'properties': schema.get('properties'),
                                      'required': schema.get('required'),
                                      'thread_fields': schema.get('definitions', {}).get('Thread', {}).get('properties')}
            run.log('schema_excerpt', {'method': method, 'schema': excerpts})
