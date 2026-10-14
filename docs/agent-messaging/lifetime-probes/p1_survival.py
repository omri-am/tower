"""Throwaway T038 survival probe. Run only from a fresh ~/.cache/tower-t038-probes/tmp.* directory.

Set CODEX_BIN to ~/.codex/packages/standalone/current/bin/codex.
"""
import time

from common import (CHECKOUT, check_registration, finish, guard, kill_registrations,
                    log_file, parser, pump_for, read_env)


def main():
    options = parser('T038 survival probe')
    options.add_argument('--sandbox', help='passed to codex as --sandbox')
    args = options.parse_args()
    run, state_root = guard('p1_survival', max(args.deadline, 420))
    variants = ('plain', 'nohup', 'disown', 'setsid')
    roles = {name: 't038-' + name for name in variants}
    checks = {name: {} for name in variants}
    started = []
    completed = False
    try:
        add_dir = state_root.parent
        add_dir.mkdir(parents=True, exist_ok=True)
        run.log('add_dir', str(add_dir))
        tr = str(CHECKOUT / 'bin' / 'tower-register')
        extra = ('--add-dir', str(add_dir))
        if args.sandbox:
            extra += ('--sandbox', args.sandbox)
        run.log('sandbox_flags', list(extra))
        prompt = ('Run exactly one shell command: /usr/bin/env -0 > session-env.txt; '
                  '/usr/bin/python3 -c pass 2>python.err; echo $? >python.exit. '
                  'Then reply ENV_DONE. Use no other tools.')
        child = run.launch(prompt, extra=extra)
        run.wait_marker('ENV_DONE', prompt)
        read_env(run, 'session-env.txt')
        log_file(run, 'python.exit')
        log_file(run, 'python.err')
        for name in variants:
            role = roles[name]
            started.append(name)
            prefix = '' if name == 'plain' else 'nohup '
            if name == 'setsid':
                prefix = ("/usr/bin/python3 -c 'import os,sys; os.setsid(); "
                          "os.execv(sys.argv[1], sys.argv[1:])' ")
            cmd = (prefix + tr + ' ' + role +
                   ' --vendor codex --thread "$CODEX_THREAD_ID" </dev/null >reg-' + name +
                   '.out 2>reg-' + name + '.err &')
            if name == 'disown':
                cmd += ' disown;'
            # Return only after tower-register has printed its session, as an agent would.
            cmd += (' for i in $(seq 50); do [ -s reg-' + name + '.out ] && break; sleep 0.1; done; '
                    'cat reg-' + name + '.out')
            marker = name.upper() + '_DONE'
            prompt = 'Run exactly one shell command: ' + cmd + '. Then reply ' + marker + '. Use no other tools.'
            child['prompt'] = prompt
            child['prompt_sent'] = False
            run.wait_marker(marker, prompt)
            pump_for(run, 3)
            for seen in started:
                stage = 'after_turn_' + name
                checks[seen][stage] = check_registration(run, roles[seen], state_root, stage)
            log_file(run, 'reg-' + name + '.out')
            log_file(run, 'reg-' + name + '.err')
        prompt = 'Reply IDLE_DONE. Use no tools.'
        child['prompt'] = prompt
        child['prompt_sent'] = False
        run.wait_marker('IDLE_DONE', prompt)
        pump_for(run, 30)
        for name in variants:
            checks[name]['after_idle'] = check_registration(
                run, roles[name], state_root, 'after_idle')
        completed = True
    except BaseException as error:
        run.log('exception', repr(error))
        raise
    finally:
        try:
            if not completed:
                for name in started:
                    checks[name]['last_observed'] = check_registration(
                        run, roles[name], state_root, 'last_observed')
                    log_file(run, 'reg-' + name + '.out')
                    log_file(run, 'reg-' + name + '.err')
            run.stop()
            if completed:
                time.sleep(5)
                for name in variants:
                    checks[name]['after_tui_stop'] = check_registration(
                        run, roles[name], state_root, 'after_tui_stop')
            kill_registrations(run, list(roles.values()), state_root)
            run.log('summary', {name: {stage: item['lock_held']
                                       for stage, item in checks[name].items()}
                                for name in variants})
        finally:
            finish(run)


if __name__ == '__main__':
    main()
