"""Throwaway T038 thread-identity probe. Run only from a fresh ~/.cache/tower-t038-probes/tmp.* directory.

Set CODEX_BIN to ~/.codex/packages/standalone/current/bin/codex.
"""
from common import finish, guard, read_env


def main():
    run, _state_root = guard('p3_thread_identity')
    thread = None
    try:
        prompt = ('Run exactly one shell command: /usr/bin/env -0 > session-env.txt. '
                  'Then reply ENV_DONE. Use no other tools.')
        run.launch(prompt)
        thread = run.thread_id(run.wait_marker('ENV_DONE', prompt))
    except BaseException as error:
        run.log('exception', repr(error))
        raise
    finally:
        try:
            run.read_notify()
            env = read_env(run, 'session-env.txt')
            run.log('thread_identity', {'notify_main_thread_id': thread,
                                        'matching_names': [key for key in env if thread and thread in key],
                                        'matching_values': [key for key, value in env.items()
                                                            if thread and thread in value],
                                        'thread_id_equals_notify':
                                        env.get('CODEX_THREAD_ID') == thread if thread else False})
            run.log('notify_order', [{'thread-id': event.get('payload', {}).get('thread-id'),
                                      'client': event.get('payload', {}).get('client')}
                                     for event in run.notifies])
            run.stop()
        finally:
            finish(run)


if __name__ == '__main__':
    main()
