"""Throwaway T038 subagent-identity probe. Run only from a fresh ~/.cache/tower-t038-probes/tmp.* directory.

Set CODEX_BIN to ~/.codex/packages/standalone/current/bin/codex.
"""
import os
from pathlib import Path

from common import finish, guard, read_env


def rollout_evidence(run, threads):
    sessions = Path(os.environ.get('CODEX_HOME', str(Path.home() / '.codex'))) / 'sessions'
    found = []
    if sessions.is_dir():
        for base, dirs, files in os.walk(str(sessions)):
            dirs[:] = [name for name in dirs if not name.startswith('.')]
            for name in files:
                path = Path(base) / name
                if path.stat().st_mtime < run.started_at:
                    continue
                matches_known_thread = any(thread in name for thread in threads)
                with path.open(errors='replace') as source:
                    lines = []
                    for line in source:
                        if 'sub-env.txt' in line:
                            start = max(0, line.index('sub-env.txt') - 120)
                            lines.append(line[start:start + 300])
                            if len(lines) == 5:
                                break
                if matches_known_thread or lines:
                    found.append({'filename': str(path), 'matches_known_thread': matches_known_thread,
                                  'sub_env_lines': lines})
    run.log('rollout_evidence', found)


def main():
    run, _state_root = guard('p4_subagent_identity')
    thread = None
    try:
        prompt = ('Spawn exactly one subagent. Tell it to run exactly one shell command, '
                  '/usr/bin/env -0 > sub-env.txt, then reply SUB_DONE and use no other tools. '
                  'Wait for it to finish. Then run exactly one shell command yourself: '
                  '/usr/bin/env -0 > main-env.txt. Then reply BOTH_DONE. Use no other tools.')
        run.launch(prompt)
        thread = run.thread_id(run.wait_marker('BOTH_DONE', prompt))
    except BaseException as error:
        run.log('exception', repr(error))
        raise
    finally:
        try:
            try:
                run.read_notify()
                main = read_env(run, 'main-env.txt')
                sub = read_env(run, 'sub-env.txt')
                main_thread = main.get('CODEX_THREAD_ID')
                sub_thread = sub.get('CODEX_THREAD_ID')
                run.log('notify_order', [{'thread-id': event.get('payload', {}).get('thread-id'),
                                          'client': event.get('payload', {}).get('client'),
                                          'last-assistant-message':
                                          str(event.get('payload', {}).get('last-assistant-message', ''))[:200]}
                                         for event in run.notifies])
                run.log('subagent_identity', {
                    'notify_main_thread_id': thread,
                    'main_thread_id': main_thread, 'sub_thread_id': sub_thread,
                    'main_session_id': main.get('CODEX_SESSION_ID'),
                    'sub_session_id': sub.get('CODEX_SESSION_ID'),
                    'sub_thread_equals_main_thread': bool(sub_thread and main_thread and
                                                          sub_thread == main_thread),
                    'sub_thread_equals_notify_main': bool(sub_thread and thread and sub_thread == thread),
                    'main_thread_equals_notify_main': bool(main_thread and thread and main_thread == thread),
                    'sub_session_equals_main_session': bool(sub.get('CODEX_SESSION_ID') and
                                                            main.get('CODEX_SESSION_ID') and
                                                            sub['CODEX_SESSION_ID'] == main['CODEX_SESSION_ID'])})
                rollout_evidence(run, {value for value in (thread, main_thread, sub_thread) if value})
            finally:
                run.stop()
        finally:
            finish(run)


if __name__ == '__main__':
    main()
