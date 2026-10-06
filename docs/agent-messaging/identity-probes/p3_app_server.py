"""Throwaway T031 app-server probe. Run only from a mktemp -d directory.

For live runs set CODEX_BIN=/Users/omriam/.codex/packages/standalone/releases/0.159.3-aarch64-apple-darwin/bin/codex.
"""
import os
from pathlib import Path
import subprocess

from common import command, guard, parser
from listing import Client, schema_excerpt


def daemon_socket(run):
    home = Path(os.environ.get('CODEX_HOME', str(Path.home() / '.codex')))
    candidates = []
    if home.is_dir():
        for base, dirs, files in os.walk(str(home)):
            run.check_time()
            dirs[:] = [name for name in dirs if name not in ('plugins', 'sessions', 'archived_sessions')]
            for name in files:
                run.check_time()
                path = Path(base) / name
                try:
                    if path.is_socket():
                        candidates.append(str(path))
                except OSError:
                    pass
    for path in Path('/tmp').glob('*codex*'):
        run.check_time()
        if path.is_socket():
            candidates.append(str(path))
    run.log('daemon_socket_candidates', {'paths': candidates})
    return candidates


def daemon_pids():
    result = subprocess.run(['pgrep', '-f', 'codex.*app-server'],
                            capture_output=True, text=True)
    return [line for line in result.stdout.splitlines() if line.isdigit()]


def main():
    args = parser('App-server probe').parse_args()
    run = guard('p3_app_server', args.deadline)
    try:
        schema_excerpt(run)
        prompt = 'Reply APP_READY. No tools.'
        run.launch(prompt)
        thread = run.thread_id(run.wait_marker('APP_READY', prompt))
        run.log('probe_thread', thread)
        daemon_socket(run)
        before = daemon_pids()
        run.log('daemon_processes_before', {'count': len(before)})
        for transport in ('stdio', 'proxy'):
            client = None
            try:
                client = Client(run, transport)
                records = client.list_for_cwd({thread})
                run.log('listing_result', {'transport': transport,
                                            'probe_present': any(item.get('id') == thread for item in records),
                                            'matching_count': len(records),
                                            'caller_fields': [item for item in records
                                                              if item.get('id') == thread]})
            except (OSError, RuntimeError, TimeoutError) as error:
                run.log('listing_failure', {'transport': transport, 'error': str(error)})
            finally:
                if client:
                    client.close()
        after = daemon_pids()
        run.log('daemon_processes_after', {'count': len(after),
                                           'new_pids': [line for line in after if line not in before]})
        queued_prompt = 'Reply AFTER_LIST. No tools.'
        result = command(run, [run.codex, 'queue', '--thread', thread, '--message',
                               queued_prompt], timeout=20)
        run.log('queue_after_listing', {'thread': thread, **result})
        if result['returncode'] == 0:
            event = run.wait_marker('AFTER_LIST', queued_prompt)
            payload = event.get('payload', {})
            run.log('after_list_notify', {'thread': run.thread_id(event),
                                          'last_assistant_message': payload.get('last-assistant-message'),
                                          'contains_marker': 'AFTER_LIST' in str(payload.get('last-assistant-message', ''))})
    finally:
        run.stop()


if __name__ == '__main__':
    main()
