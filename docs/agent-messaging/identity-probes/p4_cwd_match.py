"""Throwaway T031 cwd-match probe. Run only from a mktemp -d directory.

For live runs set CODEX_BIN=/Users/omriam/.codex/packages/standalone/releases/0.159.3-aarch64-apple-darwin/bin/codex.
"""
import os

from common import guard, parser
from listing import Client


def snapshot(run, label, ids):
    counts = {}
    for transport in ('stdio', 'proxy'):
        client = None
        try:
            client = Client(run, transport)
            records = client.list_for_cwd(set(ids.values()))
            counts[transport] = len(records)
            run.log('cwd_match', {'stage': label, 'transport': transport,
                                  'matching_count': len(records),
                                  'ids': [item.get('id') for item in records],
                                  'notify_ids': ids, 'records': records})
        except (OSError, RuntimeError, TimeoutError) as error:
            run.log('cwd_match_failure', {'stage': label, 'transport': transport,
                                          'error': str(error)})
        finally:
            if client:
                client.close()
    return counts


def thread_variables(run, filename):
    path = run.cwd / filename
    if not path.exists():
        run.log('env_missing', filename)
        return {'CODEX_THREAD_ID': None, 'CODEX_SESSION_ID': None}
    env = {}
    for entry in path.read_bytes().split(b'\0'):
        if b'=' in entry:
            key, value = entry.split(b'=', 1)
            env[os.fsdecode(key)] = os.fsdecode(value)
    return {key: env.get(key) for key in ('CODEX_THREAD_ID', 'CODEX_SESSION_ID')}


def main():
    args = parser('Cwd-match probe').parse_args()
    run = guard('p4_cwd_match', args.deadline)
    try:
        prompt_a = ('Run exactly one shell command: /usr/bin/env -0 > env-A.txt. '
                    'Then reply CWD_A. Use no other tools.')
        run.launch(prompt_a)
        notify_a = run.wait_marker('CWD_A', prompt_a)
        a = run.thread_id(notify_a)
        snapshot(run, 'one_tui', {'A': a})
        prompt_b = ('Run exactly one shell command: /usr/bin/env -0 > env-B.txt. '
                    'Then reply CWD_B. Use no other tools.')
        run.launch(prompt_b)
        notify_b = run.wait_marker('CWD_B', prompt_b)
        b = run.thread_id(notify_b)
        counts = snapshot(run, 'two_tuis', {'A': a, 'B': b})
        variables = {'A': thread_variables(run, 'env-A.txt'),
                     'B': thread_variables(run, 'env-B.txt')}
        for label, own, other, notify in (('A', a, b, notify_a), ('B', b, a, notify_b)):
            values = variables[label]
            other_values = variables['B' if label == 'A' else 'A']
            run.log('session_variables', {
                'tui': label, 'notify_thread_id': own,
                'notify_input_messages': notify.get('payload', {}).get('input-messages'),
                **values,
                'CODEX_THREAD_ID_matches_notify': values.get('CODEX_THREAD_ID') == own,
                'CODEX_SESSION_ID_matches_notify': values.get('CODEX_SESSION_ID') == own,
                'CODEX_THREAD_ID_differs_other': bool(values.get('CODEX_THREAD_ID')) and
                    values.get('CODEX_THREAD_ID') != other_values.get('CODEX_THREAD_ID'),
                'CODEX_SESSION_ID_differs_other': bool(values.get('CODEX_SESSION_ID')) and
                    values.get('CODEX_SESSION_ID') != other_values.get('CODEX_SESSION_ID'),
                'notify_id_differs_other': own != other})
        thread_a = variables['A'].get('CODEX_THREAD_ID')
        thread_b = variables['B'].get('CODEX_THREAD_ID')
        run.log('disambiguation', {
            'cwd_listing_match_count': counts.get('stdio', counts.get('proxy')),
            'cwd_listing_counts': counts,
            'thread_ids_distinct_and_match': bool(thread_a and thread_b and thread_a != thread_b
                                                   and thread_a == a and thread_b == b)})
        run.log('ambiguity', {'distinct_notify_ids': a != b,
                              'same_cwd': True,
                              'concurrent_tuis': len([child for child in run.children if child['alive']])})
    finally:
        run.stop()


if __name__ == '__main__':
    main()
