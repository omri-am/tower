"""Throwaway T038 write-access probe. Run only from a fresh ~/.cache/tower-t038-probes/tmp.* directory.

Set CODEX_BIN to ~/.codex/packages/standalone/current/bin/codex.
"""
from common import (CHECKOUT, check_registration, finish, guard, kill_registrations,
                    log_file, parser, read_env)


def main():
    options = parser('T038 write-access probe')
    options.add_argument('--add-dir', action='store_true')
    args = options.parse_args()
    name = 'p2_write_access_add_dir' if args.add_dir else 'p2_write_access_default'
    run, state_root = guard(name, args.deadline)
    role = 't038-write'
    try:
        extra = ()
        if args.add_dir:
            state_root.parent.mkdir(parents=True, exist_ok=True)
            extra = ('--add-dir', str(state_root.parent))
        run.log('sandbox_flags', list(extra))
        tr = str(CHECKOUT / 'bin' / 'tower-register')
        cmd = ('/usr/bin/env -0 > session-env.txt; '
               'mkdir -p ' + str(state_root / 'agents') + ' 2>mkdir.err; echo $? >mkdir.exit; '
               '/usr/bin/python3 -c pass 2>python.err; echo $? >python.exit; '
               'nohup ' + tr + ' ' + role +
               ' --vendor codex --thread "$CODEX_THREAD_ID" </dev/null '
               '>reg-write.out 2>reg-write.err & sleep 3; cat reg-write.err')
        prompt = ('Run exactly one shell command inside the sandbox, without requesting approval or '
                  'escalated permissions: ' + cmd + '. Then reply WRITE_DONE. Use no other tools.')
        run.launch(prompt, extra=extra)
        run.wait_marker('WRITE_DONE', prompt)
    except BaseException as error:
        run.log('exception', repr(error))
        raise
    finally:
        try:
            read_env(run, 'session-env.txt')
            for name in ('mkdir.exit', 'mkdir.err', 'python.exit', 'python.err', 'reg-write.out'):
                log_file(run, name)
            log_file(run, 'reg-write.err')
            agents = state_root / 'agents'
            run.log('agents_directory', {'exists': agents.is_dir(),
                                         'listing': sorted(path.name for path in agents.iterdir())
                                         if agents.is_dir() else []})
            check_registration(run, role, state_root)
            kill_registrations(run, [role], state_root)
            run.stop()
        finally:
            finish(run)


if __name__ == '__main__':
    main()
