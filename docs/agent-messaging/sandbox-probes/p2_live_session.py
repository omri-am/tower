"""Throwaway T045 live session probe."""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'lifetime-probes'))
from common import (check_registration, detect_dialog, finish, guard, identity, log_file,
                    parser, pump_for, read_env)
from p1_sandbox_matrix import entries_from_args, profile_override


ROLE = 't045-holder'
FILES = ('session-env.txt', 'tool-path.txt', 'tower-help.out', 'tower-help.err',
         'tower-help.exit', 'reg-help.out', 'reg-help.err', 'reg-help.exit',
         'py.out', 'py.err', 'py.exit')


def prompt_for(command, marker):
    return ('Run exactly one shell command. The command is everything between the line <<<CMD and the line CMD>>>, without those two lines:\n<<<CMD\n'
            + command + '\nCMD>>>\n'
            'Run it inside the sandbox, without requesting approval or escalated permissions. '
            'Then reply ' + marker + '. Use no other tools.')


def turn(run, child, command, marker):
    prompt = prompt_for(command, marker)
    child['prompt'] = prompt
    child['prompt_sent'] = False
    run.wait_marker(marker, prompt)


def quit_tui(run, child):
    run.drain_screen(child)
    kind, plain = detect_dialog(child['screen'][child['input_offset']:], run.cwd,
                                child['scratch_path_seen'])
    if kind:
        run.log('dialog_stop', {'pid': child['pid'], 'kind': kind, 'screen': plain[-8000:]})
        raise RuntimeError('dialog before /quit; sent no response')
    run.write_pty(child, 'quit_command', b'/quit')
    time.sleep(0.5)
    run.drain_screen(child)
    kind, plain = detect_dialog(child['screen'][child['input_offset']:], run.cwd,
                                child['scratch_path_seen'])
    if kind:
        run.log('dialog_stop', {'pid': child['pid'], 'kind': kind, 'screen': plain[-8000:]})
        raise RuntimeError('dialog after /quit; sent no Enter')
    run.write_pty(child, 'quit_enter', b'\r')
    start = time.monotonic()
    exited, status = False, None
    while time.monotonic() - start < 20:
        run.drain_exit_output(child)
        try:
            waited, observed_status = os.waitpid(child['pid'], os.WNOHANG)
            exited = bool(waited)
            if exited:
                status = observed_status
        except ChildProcessError:
            exited = True
        if exited:
            child['alive'] = False
            break
        time.sleep(0.05)
    run.log('tui_exit', {'exited': exited, 'waitpid_status': status,
                         'elapsed_seconds': time.monotonic() - start,
                         'screen_tail': identity.ANSI.sub('', child['screen'])[-2000:]})
    return exited


def pid_exists(pid):
    if not isinstance(pid, int) or pid <= 0:
        return None
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        pass
    return True


def kill_holder(run, role, state_root, lib_dir, holder_pid):
    path = state_root / 'agents' / (role + '.json')
    pid = json.loads(path.read_text()).get('pid') if path.is_file() else holder_pid
    command_line = ''
    signalled = False
    if isinstance(pid, int) and pid > 0:
        ps = subprocess.run(['ps', '-o', 'command=', '-p', str(pid)],
                            stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=10)
        command_line = ps.stdout.strip()
        if ps.returncode == 0 and lib_dir in command_line and role in command_line:
            try:
                os.kill(pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            signalled = True
            end = time.monotonic() + 5
            while time.monotonic() < end and pid_exists(pid):
                time.sleep(0.1)
    observed = check_registration(run, role, state_root, stage='after_cleanup')
    run.log('cleanup', {'role': role, 'pid': pid, 'command': command_line,
                        'signalled': signalled, 'exited': pid_exists(pid) is False,
                        'lock_free': observed['lock_held'] is False})
    return observed


def main():
    options = parser('T045 live session probe')
    options.add_argument('--entry', action='append', default=[])
    options.add_argument('--discover-only', action='store_true')
    args = options.parse_args()
    entries = entries_from_args(args.entry)
    run, state_root = guard('p2_live_session', max(args.deadline, 900))
    checks = {}
    completed = False
    holder_pid = None
    try:
        override = profile_override(run, entries)
        add_dir = state_root.parent
        add_dir.mkdir(parents=True, exist_ok=True)
        run.log('add_dir', str(add_dir))
        discover = ('/usr/bin/env -0 > session-env.txt; '
                    '{ echo "$PATH"; command -v tower; command -v tower-register; '
                    'command -v python3; } > tool-path.txt; '
                    'tower --help >tower-help.out 2>tower-help.err; echo $? >tower-help.exit; '
                    'tower-register --help >reg-help.out 2>reg-help.err; echo $? >reg-help.exit; '
                    "python3 -c 'import sys; print(sys.executable); print(sys.base_prefix)' "
                    '>py.out 2>py.err; echo $? >py.exit')
        prompt = prompt_for(discover, 'DISCOVER_DONE')
        child = run.launch(prompt, extra=('-c', override, '--add-dir', str(add_dir)))
        run.wait_marker('DISCOVER_DONE', prompt)
        read_env(run, 'session-env.txt')
        for name in FILES:
            log_file(run, name)
        if args.discover_only:
            completed = True
            return
        register = ("python3 -c 'import os,sys; os.setsid(); "
                    "os.execv(sys.argv[1], sys.argv[1:])' "
                    '"$(command -v tower-register)" t045-holder --vendor codex '
                    '--thread "$CODEX_THREAD_ID" </dev/null >reg.out 2>reg.err & '
                    'for i in $(seq 50); do [ -s reg.out ] && break; sleep 0.1; done; cat reg.out')
        turn(run, child, register, 'REGISTER_DONE')
        pump_for(run, 3)
        checks['after_register'] = check_registration(run, ROLE, state_root, 'after_register')
        holder_pid = checks['after_register']['pid']
        log_file(run, 'reg.out')
        log_file(run, 'reg.err')
        for number, command in enumerate(('ls -la > call1.txt',
                                          'git status --short >call2.txt 2>call2.err',
                                          'tower --help > call3.txt 2>&1'), 1):
            turn(run, child, command, 'CALL%d_DONE' % number)
            pump_for(run, 3)
            stage = 'after_call%d' % number
            checks[stage] = check_registration(run, ROLE, state_root, stage)
            log_file(run, 'call%d.txt' % number)
            if number == 2:
                log_file(run, 'call2.err')
        tui_exited = quit_tui(run, child)
        time.sleep(5)
        checks['after_quit'] = check_registration(run, ROLE, state_root, 'after_quit')
        run.log('holder_after_quit', {'pid': holder_pid, 'pid_exists': pid_exists(holder_pid),
                                      'lock_held': checks['after_quit']['lock_held'],
                                      'tui_exited': tui_exited})
        completed = True
    except BaseException as error:
        run.log('exception', repr(error))
        raise
    finally:
        try:
            try:
                try:
                    if not completed:
                        checks['last_observed'] = check_registration(
                            run, ROLE, state_root, 'last_observed')
                finally:
                    run.stop()
            finally:
                path = run.cwd / 'tool-path.txt'
                lines = path.read_text().splitlines() if path.is_file() else []
                register_path = next((line for line in lines[1:]
                                      if line.endswith('/tower-register')), '')
                if os.path.isabs(register_path):
                    lib_dir = os.path.realpath(os.path.join(
                        os.path.realpath(os.path.dirname(register_path)), '..', 'lib'))
                    checks['after_cleanup'] = kill_holder(run, ROLE, state_root, lib_dir, holder_pid)
                else:
                    run.log('cleanup_skipped', {'reason': 'tower-register path unavailable'})
                run.log('summary', {stage: item['lock_held'] for stage, item in checks.items()})
        finally:
            finish(run)


if __name__ == '__main__':
    main()
