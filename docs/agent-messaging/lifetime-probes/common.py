"""Throwaway T038 shared probe. Run only from a fresh ~/.cache/tower-t038-probes/tmp.* directory.

Set CODEX_BIN to ~/.codex/packages/standalone/current/bin/codex.
No dialog answered is enforced by replacing identity.detect_dialog for Run.pump and Run.paste.
"""
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time


sys.dont_write_bytecode = True
identity_path = Path(__file__).resolve().parent.parent / 'identity-probes' / 'common.py'
sys.path.insert(0, str(identity_path.parent))
identity_spec = importlib.util.spec_from_file_location('t031_identity_common', identity_path)
identity = importlib.util.module_from_spec(identity_spec)
identity_spec.loader.exec_module(identity)


MODEL = identity.MODEL
CHECKOUT = Path(__file__).resolve().parents[3]
_original_detect_dialog = identity.detect_dialog


def detect_dialog(screen, cwd, scratch_path_seen=False):
    kind, plain = _original_detect_dialog(screen, cwd, scratch_path_seen)
    return ('other' if kind in ('trust', 'pending_trust') else kind), plain


identity.detect_dialog = detect_dialog
resolve_codex = identity.resolve_codex
command = identity.command
parser = identity.parser


class Run(identity.Run):
    def __init__(self, cwd, path, fd, codex, deadline):
        super().__init__(cwd, path, fd, codex, deadline)
        self.screen_logged_at = {}
        self.screen_due = False

    def log(self, label, value):
        if label == 'screen_tail' and not self.screen_due:
            return
        super().log(label, value)

    def record_screen(self, child, data):
        now = time.monotonic()
        pid = child['pid']
        self.screen_due = now - self.screen_logged_at.get(pid, float('-inf')) >= 1
        try:
            super().record_screen(child, data)
        finally:
            if self.screen_due:
                self.screen_logged_at[pid] = now
            self.screen_due = False

    def launch(self, prompt=None, extra=()):
        # A dispatched worktree inherits trust from its trusted repository root. This run-only
        # override gives the fixture the same trust without answering the dialog or saving it.
        trust = 'projects={%s={trust_level="trusted"}}' % json.dumps(str(self.cwd.parent / 'repo'))
        return super().launch(prompt, ('-c', trust) + tuple(extra))

    def stop(self):
        for child in self.children:
            identity.Run.log(self, 'screen_tail', {
                'pid': child['pid'], 'text': identity.ANSI.sub('', child['screen'])[-4000:]})
        kept_fd = os.dup(self.fd)
        try:
            super().stop()
        finally:
            self.fd = kept_fd

    def close(self):
        os.close(self.fd)


def _checked(run, label, args):
    if run.cwd.is_dir():
        result = command(run, args)
    else:
        completed = subprocess.run(args, cwd=str(run.path.parent), stdin=subprocess.DEVNULL,
                                   capture_output=True, text=True, timeout=20)
        result = {'returncode': completed.returncode, 'stdout': completed.stdout,
                  'stderr': completed.stderr}
    run.log(label, {'argv': list(args), **result})
    if result['returncode']:
        raise RuntimeError('%s failed: %s' % (label, result['stderr']))
    return result['stdout'].strip()


def guard(name, deadline=300):
    os.umask(0o077)
    root = Path.cwd().resolve()
    allowed_parent = Path.home() / '.cache' / 'tower-t038-probes'
    in_git = subprocess.run(['git', 'rev-parse', '--show-toplevel'], cwd=str(root),
                            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL)
    if (root.parent != allowed_parent.resolve() or not root.name.startswith('tmp.')
            or root.stat().st_mode & 0o777 != 0o700 or in_git.returncode == 0
            or any(root.iterdir())):
        raise RuntimeError('run from a fresh mode-0700 ~/.cache/tower-t038-probes/tmp.* outside git')
    explicit = os.environ.get('CODEX_BIN')
    if not explicit:
        raise RuntimeError('CODEX_BIN is required')
    current = Path.home() / '.codex' / 'packages' / 'standalone' / 'current'
    if Path(explicit).resolve() != current.resolve() / 'bin' / 'codex':
        raise RuntimeError('CODEX_BIN must resolve to the installed current/bin/codex')
    codex = resolve_codex()
    path = root / (name + '.jsonl')
    fd = os.open(str(path), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    run = Run(root / 'wt', path, fd, codex, time.monotonic() + deadline)
    run.started_at = time.time()
    run.current = current
    try:
        version = subprocess.run([codex, '--version'], stdin=subprocess.DEVNULL,
                                 capture_output=True, text=True, timeout=10)
        run.log('start', {'cwd': str(root), 'checkout': str(CHECKOUT),
                          'codex': codex, 'installed_before': str(current.resolve()),
                          'version': version.stdout.strip(),
                          'version_stderr': version.stderr.strip(),
                          'version_returncode': version.returncode,
                          'model': MODEL, 'deadline_seconds': deadline})
        if version.returncode:
            raise RuntimeError('codex --version failed')
        repo = root / 'repo'
        repo.mkdir()
        _checked(run, 'git_init', ['git', 'init', str(repo)])
        _checked(run, 'git_name', ['git', '-C', str(repo), 'config', 'user.name', 'T038 Probe'])
        _checked(run, 'git_email', ['git', '-C', str(repo), 'config', 'user.email', 't038@invalid.example'])
        (repo / 'README').write_text('Throwaway T038 fixture.\n')
        _checked(run, 'git_add', ['git', '-C', str(repo), 'add', 'README'])
        _checked(run, 'git_commit', ['git', '-C', str(repo), 'commit', '-m', 'Initial fixture'])
        (repo / '.tower').mkdir()
        (repo / '.tower' / 'README').write_text('Throwaway tower project.\n')
        with (repo / '.git' / 'info' / 'exclude').open('a') as exclude:
            exclude.write('\n.tower\n')
        _checked(run, 'git_worktree', ['git', '-C', str(repo), 'worktree', 'add', '../wt', '-b', 'probe'])
        (run.cwd / '.tower').symlink_to(repo / '.tower', target_is_directory=True)
        located = _checked(run, 'tower_locate', [str(CHECKOUT / 'bin' / 'tower-locate')]).splitlines()
        if len(located) != 2 or located[0] != str(run.cwd) or located[1] == 'copy':
            raise RuntimeError('tower-locate did not identify the linked worktree: ' + repr(located))
        common = Path(_checked(run, 'git_common_dir', [
            'git', '-C', str(run.cwd), 'rev-parse', '--path-format=absolute', '--git-common-dir']))
        state_root = common / 'tower' / 'root'
        run.log('fixture', {'checkout': str(CHECKOUT), 'tower_locate': located,
                            'git_common_dir': str(common), 'state_root': str(state_root)})
        return run, state_root
    except BaseException as error:
        run.log('setup_exception', repr(error))
        run.close()
        raise


def read_env(run, name):
    path = run.cwd / name
    if not path.is_file():
        run.log('environment_missing', str(path))
        return {}
    env = {}
    for entry in path.read_bytes().split(b'\0'):
        if b'=' in entry:
            key, value = entry.split(b'=', 1)
            env[os.fsdecode(key)] = os.fsdecode(value)
    run.log('environment', {'file': name, 'names': sorted(env),
                            'codex_variables': {key: value for key, value in env.items()
                                                if key.startswith('CODEX_')}})
    return env


def log_file(run, name):
    path = run.cwd / name
    run.log('file', {'name': name, 'exists': path.is_file(),
                     'text': path.read_text(errors='replace') if path.is_file() else None})


def check_registration(run, role, state_root, stage=None):
    agents = state_root / 'agents'
    path = agents / (role + '.json')
    event = {'role': role, 'stage': stage, 'record_exists': path.is_file(),
             'pid': None, 'session': None, 'thread': None,
             'pid_exists': None, 'ps': None, 'lsof_lock_paths': [],
             'lock_held': False, 'lock_content_matches_session': None}
    if path.is_file():
        record = json.loads(path.read_text())
        event.update({key: record.get(key) for key in ('pid', 'session', 'thread')})
    pid = event['pid']
    if isinstance(pid, int) and pid > 0:
        try:
            os.kill(pid, 0)
            event['pid_exists'] = True
        except PermissionError:
            event['pid_exists'] = True
        except ProcessLookupError:
            event['pid_exists'] = False
        ps = subprocess.run(['ps', '-o', 'pid,ppid,pgid,sess,stat,lstart,command', '-p', str(pid)],
                            stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=10)
        event['ps'] = ps.stdout
        event['ps_stderr'] = ps.stderr
        lsof = subprocess.run(['lsof', '-Fn', '-p', str(pid)], stdin=subprocess.DEVNULL,
                              capture_output=True, text=True, timeout=10)
        event['lsof_lock_paths'] = [line[1:] for line in lsof.stdout.splitlines()
                                    if line.startswith('n') and role + '.lock' in line]
        event['lsof_stderr'] = lsof.stderr
    lock_path = agents / (role + '.lock') / 'session'
    if lock_path.is_file():
        with lock_path.open('r') as stream:
            event['lock_content_matches_session'] = stream.read().strip() == event['session']
            try:
                fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                event['lock_held'] = True
            else:
                fcntl.flock(stream, fcntl.LOCK_UN)
    run.log('registration', event)
    return event


def kill_registrations(run, roles, state_root):
    for role in roles:
        path = state_root / 'agents' / (role + '.json')
        if not path.is_file():
            run.log('cleanup', {'role': role, 'result': 'record_missing'})
            continue
        pid = json.loads(path.read_text()).get('pid')
        if not isinstance(pid, int) or pid <= 0:
            run.log('cleanup', {'role': role, 'pid': pid, 'result': 'invalid_pid'})
            continue
        ps = subprocess.run(['ps', '-o', 'command=', '-p', str(pid)],
                            stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=10)
        command_line = ps.stdout.strip()
        # tower-register execs `python3 - <checkout>/lib <role> ...`, so its own name is gone.
        if ps.returncode or str(CHECKOUT / 'lib') not in command_line or role not in command_line:
            observed = check_registration(run, role, state_root, stage='cleanup_skipped')
            run.log('cleanup', {'role': role, 'pid': pid, 'command': command_line,
                                'result': 'command_mismatch_no_signal',
                                'exited': observed['pid_exists'] is False,
                                'lock_free': observed['lock_held'] is False})
            continue
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        exited = False
        end = time.monotonic() + 5
        while time.monotonic() < end:
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                exited = True
                break
            time.sleep(0.1)
        result = check_registration(run, role, state_root, stage='after_cleanup')
        run.log('cleanup', {'role': role, 'pid': pid, 'command': command_line,
                            'exited': exited,
                            'lock_free': result['lock_held'] is False})


def pump_for(run, seconds):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        run.pump(seconds=min(0.2, end - time.monotonic()))


def finish(run):
    home = Path(os.environ.get('CODEX_HOME', str(Path.home() / '.codex'))).expanduser()
    paths = []
    if home.is_dir():
        for base, dirs, files in os.walk(str(home)):
            dirs[:] = [name for name in dirs if not name.startswith('.')]
            for name in files:
                path = Path(base) / name
                try:
                    if path.stat().st_mtime >= run.started_at:
                        paths.append(str(path))
                except OSError:
                    pass
    run.log('modified_codex_home_paths', sorted(paths))
    run.log('installed_after', str(run.current.resolve()))
    run.close()
