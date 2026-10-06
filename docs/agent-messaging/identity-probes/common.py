"""Throwaway T031 shared probe. Run only from a mktemp -d directory.

For live runs set CODEX_BIN=/Users/omriam/.codex/packages/standalone/releases/0.159.3-aarch64-apple-darwin/bin/codex.
"""
import fcntl
import json
import os
from pathlib import Path
import pty
import re
import select
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import time


MODEL = 'gpt-6-luna'
CHOICE = ('Would you like to run', 'Approval requested', 'Select model',
          'Allow', 'Trust this hook', 'Trust hook', 'Do you trust',
          'Choose an option', 'Select an option')
ANSI = re.compile(r'\x1b(?:\[[0-?]*[ -/]*[@-~]|\][^\x07]*(?:\x07|\x1b\\))')
SCREEN_CLEAR = re.compile(r'\x1b\[2J|\x1b\[1;1H\x1b\[J')
NUMBERED_OPTION = re.compile(r'(?<![\w.])\d+\.(?!\d)')
FOOTER = re.compile(r'(?:enter\s*(?:to\s*)?continue|esc\s*(?:to\s*)?(?:skip|quit|cancel))', re.I)
DIALOG_FOOTER = re.compile(r'(?:enter|esc)\s*(?:to\s*)?(?:continue|confirm|skip|quit|cancel)', re.I)
CONFIRMATION = re.compile(r'[\[(]\s*[yYnN]\s*/\s*[yYnN]\s*[\])]')


def detect_dialog(screen, cwd, scratch_path_seen=False):
    plain = ANSI.sub('', screen)
    compact = re.sub(r'\s+', '', plain).lower()
    old_choice = any(re.sub(r'\s+', '', word).lower() in compact for word in CHOICE)
    numbered = list(NUMBERED_OPTION.finditer(plain))
    footers = list(FOOTER.finditer(plain))
    questions = list(re.finditer(r'Trust\s*this\s*folder\?', plain, re.I))
    question = questions[-1].start() if questions else -1
    trust_path = scratch_path_seen or str(cwd) in plain or cwd.name in plain
    trust_option = 'trustandcontinue' in re.sub(r'\s+', '', plain[question:]).lower()
    first_options = [option for option in numbered if option.start() > question
                     and plain[option.start():option.end()].startswith('1.')]
    latest_first = first_options[-1].start() if first_options else -1
    latest_choice = (re.sub(r'\s+', '', plain[latest_first:]).lower()
                     if latest_first >= 0 else '')
    trusted_choice = latest_choice.startswith('1.trustandcontinue')
    quit_choice = '2.quit' in latest_choice
    trust_signature = question >= 0 and trust_path and trust_option and trusted_choice and quit_choice
    trust_footers = [footer for footer in footers if footer.start() > latest_first
                     and re.sub(r'\s+', '', footer.group()).lower() in ('escquit', 'esctoquit')]
    trust_footer = trust_footers[0] if trust_footers else None
    later_dialog = (trust_footer is not None and
                    (any(option.start() >= trust_footer.end() for option in numbered) or
                     any(footer.start() >= trust_footer.end() for footer in footers)))
    if old_choice or later_dialog or CONFIRMATION.search(plain):
        return 'other', plain
    if trust_signature and trust_footer is not None:
        return 'trust', plain
    if trust_signature:
        return 'pending_trust', plain
    if numbered or footers:
        return 'other', plain
    if 'folderaccess' in compact or 'trustthisfolder' in compact:
        return 'pending_trust', plain
    return None, plain


def guard(name, deadline=300):
    os.umask(0o077)
    cwd = Path.cwd().resolve()
    result = subprocess.run(['git', 'rev-parse', '--show-toplevel'],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if result.returncode == 0:
        raise RuntimeError('run only from a mktemp -d directory outside git')
    scratch_root = Path(tempfile.gettempdir()).resolve()
    if (cwd.parent != scratch_root or not cwd.name.startswith('tmp.')
            or cwd.stat().st_mode & 0o777 != 0o700):
        raise RuntimeError('run from a fresh mktemp -d directory')
    path = cwd / (name + '.jsonl')
    fd = os.open(str(path), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    codex = resolve_codex()
    version = subprocess.run([codex, '--version'], capture_output=True,
                             text=True, timeout=10)
    run = Run(cwd, path, fd, codex, time.monotonic() + deadline)
    run.log('start', {'cwd': str(cwd), 'codex': codex,
                      'version': version.stdout.strip(), 'version_stderr': version.stderr.strip(),
                      'model': MODEL, 'deadline_seconds': deadline})
    if version.returncode != 0 or not re.search(r'\b0\.159\.3\b', version.stdout):
        run.log('version_stop', {'returncode': version.returncode})
        os.close(fd)
        raise RuntimeError('T031 live probes require Codex 0.159.3 through CODEX_BIN')
    return run


def resolve_codex():
    explicit = os.environ.get('CODEX_BIN')
    if explicit:
        path = Path(explicit).expanduser().resolve()
    else:
        excluded = Path.home() / '.superset'
        path = None
        for directory in os.environ.get('PATH', '').split(os.pathsep):
            root = Path(directory or '.').expanduser().resolve()
            if root == excluded or excluded in root.parents:
                continue
            candidate = root / 'codex'
            if candidate.is_file() and os.access(str(candidate), os.X_OK):
                path = candidate.resolve()
                break
        if path is None:
            raise RuntimeError('set CODEX_BIN to the real Codex binary')
    if Path.home() / '.superset' in path.parents:
        raise RuntimeError('CODEX_BIN resolved inside ~/.superset; use the real binary')
    if not path.is_file() or not os.access(str(path), os.X_OK):
        raise RuntimeError('Codex binary is not executable: ' + str(path))
    return str(path)


class Run:
    def __init__(self, cwd, path, fd, codex, deadline):
        self.cwd, self.path, self.fd, self.codex = cwd, path, fd, codex
        self.deadline = deadline
        self.children = []
        self.notify_offset = 0
        self.notifies = []

    def log(self, label, value):
        event = {'time': time.time(), 'monotonic': time.monotonic(), label: value}
        os.write(self.fd, (json.dumps(event, sort_keys=True) + '\n').encode())
        os.fsync(self.fd)

    def write_pty(self, child, label, data):
        self.log('pty_write', {'pid': child['pid'], 'label': label,
                               'bytes_text': data.decode('utf-8', errors='backslashreplace')})
        os.write(child['fd'], data)

    def check_time(self):
        if time.monotonic() >= self.deadline:
            raise TimeoutError('overall probe deadline')

    def setup_notify(self):
        script = self.cwd / 'record_notify.py'
        script.write_text('import json, pathlib, sys, time\n'
                          'with pathlib.Path("notify.jsonl").open("a") as out:\n'
                          '    out.write(json.dumps({"time": time.time(), "argv": sys.argv[1:], '
                          '"payload": json.loads(sys.argv[-1])}) + "\\n")\n'
                          '    out.flush()\n')
        return '-c', 'notify=' + json.dumps([sys.executable, str(script)])

    def launch(self, prompt=None, extra=()):
        notify = self.setup_notify()
        args = [self.codex, '-m', MODEL, '-c', 'approvals_reviewer="user"',
                '-c', 'check_for_update_on_startup=false',
                notify[0], notify[1]] + list(extra)
        pid, master = pty.fork()
        if pid == 0:
            os.environ['TERM'] = 'xterm-256color'
            os.chdir(str(self.cwd))
            os.execv(self.codex, args)
        fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack('HHHH', 40, 120, 0, 0))
        child = {'pid': pid, 'fd': master, 'screen': '', 'trusted': False,
                 'trust_seen': None, 'composer_seen': None,
                 'last_output_at': time.monotonic(), 'choice_seen': None,
                 'scratch_path_seen': False,
                 'after_trust_offset': None, 'input_offset': 0,
                 'prompt': prompt, 'prompt_sent': False,
                 'alive': True}
        self.children.append(child)
        self.log('launch', {'pid': pid, 'argv': args})
        return child

    def record_screen(self, child, data):
        child['screen'] += data.decode(errors='replace')
        child['last_output_at'] = time.monotonic()
        plain = ANSI.sub('', child['screen'])
        child['scratch_path_seen'] = (child['scratch_path_seen'] or
                                      str(self.cwd) in plain or self.cwd.name in plain)
        clears = list(SCREEN_CLEAR.finditer(child['screen']))
        if clears:
            child['screen'] = child['screen'][clears[-1].end():]
            child['input_offset'] = 0
            child['after_trust_offset'] = 0 if child['trusted'] else None
            child['trust_seen'] = None
            child['composer_seen'] = None
            self.log('screen_clear', child['pid'])
        self.log('screen_tail', {'pid': child['pid'],
                                 'text': ANSI.sub('', child['screen'])[-4000:]})

    def pump(self, children=None, seconds=0.2):
        self.check_time()
        children = children or self.children
        live = [child for child in children if child['alive']]
        ready = select.select([child['fd'] for child in live], [], [], seconds)[0] if live else []
        for child in live:
            if child['fd'] not in ready:
                continue
            try:
                data = os.read(child['fd'], 65536)
            except OSError:
                data = b''
            if not data:
                child['alive'] = False
                self.log('child_eof', child['pid'])
                continue
            self.record_screen(child, data)
        for child in live:
            if not child['alive']:
                continue
            dialog, plain = detect_dialog(child['screen'][child['input_offset']:], self.cwd,
                                          child['scratch_path_seen'])
            now = time.monotonic()
            has_choice = bool(NUMBERED_OPTION.search(plain) or DIALOG_FOOTER.search(plain)
                              or CONFIRMATION.search(plain))
            if has_choice and child['choice_seen'] is None:
                child['choice_seen'] = now
            if not has_choice:
                child['choice_seen'] = None
            settled = now - child['last_output_at'] >= 0.5
            if has_choice and not settled and now - child['choice_seen'] >= 10:
                self.log('dialog_stop', {'pid': child['pid'], 'screen': plain[-8000:],
                                         'reason': 'choice screen did not settle in 10 seconds'})
                raise RuntimeError('choice screen did not settle; sent no response')
            if dialog:
                child['composer_seen'] = None
            if not settled:
                continue
            if dialog == 'other':
                self.log('dialog_stop', {'pid': child['pid'], 'screen': plain[-8000:]})
                raise RuntimeError('choice dialog; sent no response')
            if dialog == 'trust' and not child['trusted'] and child['trust_seen'] is None:
                child['trust_seen'] = time.monotonic()
                child['composer_seen'] = None
            composer_screen = (plain if child['after_trust_offset'] is None else
                               ANSI.sub('', child['screen'][child['after_trust_offset']:]))
            composer_compact = re.sub(r'\s+', '', composer_screen)
            if (dialog is None and child['trust_seen'] is None and child['composer_seen'] is None
                    and ('Enteramessage' in composer_compact or
                         'AskCodextodoanything' in composer_compact)):
                child['composer_seen'] = time.monotonic()
        for child in live:
            if (child['alive'] and child['trust_seen'] is not None and not child['trusted']
                    and time.monotonic() - child['trust_seen'] >= 2):
                self.drain_screen(child)
                if time.monotonic() - child['last_output_at'] < 0.5:
                    continue
                dialog, plain = detect_dialog(child['screen'][child['input_offset']:], self.cwd,
                                              child['scratch_path_seen'])
                if dialog == 'other':
                    self.log('dialog_stop', {'pid': child['pid'], 'screen': plain[-8000:]})
                    raise RuntimeError('choice dialog; sent no response')
                if dialog != 'trust':
                    continue
                self.write_pty(child, 'workspace_trust_enter', b'\r')
                child['trusted'] = True
                child['trust_seen'] = None
                child['composer_seen'] = None
                child['after_trust_offset'] = len(child['screen'])
                child['input_offset'] = len(child['screen'])
                self.log('workspace_trust', {'pid': child['pid'], 'path': str(self.cwd)})
            if (child['alive'] and child['composer_seen'] is not None
                    and child['trust_seen'] is None and child['prompt'] and not child['prompt_sent']
                    and time.monotonic() - child['composer_seen'] >= (0 if child['trusted'] else 3)):
                self.paste(child, child['prompt'])
        self.read_notify()

    def drain_screen(self, child):
        for _ in range(20):
            if not select.select([child['fd']], [], [], 0)[0]:
                return
            try:
                data = os.read(child['fd'], 65536)
            except OSError:
                data = b''
            if not data:
                child['alive'] = False
                self.log('child_eof', child['pid'])
                raise RuntimeError('TUI exited before input')
            self.record_screen(child, data)
        raise RuntimeError('PTY output remained busy; sent no input')

    def paste(self, child, prompt):
        self.check_time()
        self.drain_screen(child)
        if time.monotonic() - child['last_output_at'] < 0.5:
            return
        dialog, plain = detect_dialog(child['screen'][child['input_offset']:], self.cwd,
                                      child['scratch_path_seen'])
        if dialog == 'other':
            self.log('dialog_stop', {'pid': child['pid'], 'screen': plain[-8000:]})
            raise RuntimeError('choice dialog; sent no response')
        if dialog:
            child['composer_seen'] = None
            if dialog == 'trust' and child['trust_seen'] is None:
                child['trust_seen'] = time.monotonic()
            return
        composer = ANSI.sub('', child['screen'][child['after_trust_offset'] or 0:])
        composer = re.sub(r'\s+', '', composer).lower()
        if 'enteramessage' not in composer and 'askcodextodoanything' not in composer:
            return
        self.write_pty(child, 'bracketed_paste', b'\x1b[200~' + prompt.encode() + b'\x1b[201~')
        time.sleep(0.2)
        self.drain_screen(child)
        dialog, plain = detect_dialog(child['screen'][child['input_offset']:], self.cwd,
                                      child['scratch_path_seen'])
        if dialog:
            self.log('dialog_stop', {'pid': child['pid'], 'screen': plain[-8000:]})
            raise RuntimeError('dialog appeared after paste; sent no Enter')
        self.write_pty(child, 'prompt_enter', b'\r')
        child['input_offset'] = len(child['screen'])
        child['prompt_sent'] = True
        self.log('prompt', {'pid': child['pid'], 'text': prompt})

    def read_notify(self):
        path = self.cwd / 'notify.jsonl'
        if not path.exists():
            return
        with path.open() as source:
            source.seek(self.notify_offset)
            while True:
                offset = source.tell()
                line = source.readline()
                if not line:
                    break
                try:
                    event = json.loads(line)
                except json.JSONDecodeError:
                    source.seek(offset)
                    break
                self.notifies.append(event)
                self.log('notify', event)
            self.notify_offset = source.tell()

    def wait_notify(self, count=1):
        while len(self.notifies) < count:
            self.pump()
            if not any(child['alive'] for child in self.children):
                raise RuntimeError('TUI exited before notify')
        return self.notifies[count - 1]

    def wait_marker(self, marker, expected_input):
        discarded = set()
        while True:
            self.pump()
            for index, event in enumerate(self.notifies):
                payload = event.get('payload', {})
                if marker not in str(payload.get('last-assistant-message', '')):
                    continue
                if expected_input in payload.get('input-messages', []):
                    return event
                if index not in discarded:
                    self.log('discarded_notify', {'reason': 'marker without expected input',
                                                  'thread_id': payload.get('thread-id'),
                                                  'marker': marker})
                    discarded.add(index)
            if not any(child['alive'] for child in self.children):
                raise RuntimeError('TUI exited before ' + marker)

    def thread_id(self, event):
        payload = event.get('payload', {})
        thread = payload.get('thread-id') or payload.get('threadId')
        if not thread:
            raise RuntimeError('notify lacked thread-id: ' + repr(payload))
        return thread

    def stop(self):
        for child in self.children:
            pid = child['pid']
            reaped = False
            wait_status = None
            try:
                os.killpg(pid, signal.SIGTERM)
            except OSError as error:
                self.log('killpg_error', {'pid': pid, 'signal': 'SIGTERM', 'error': repr(error)})
            end = time.monotonic() + 5
            while time.monotonic() < end:
                self.drain_exit_output(child)
                try:
                    waited_pid, wait_status = os.waitpid(pid, os.WNOHANG)
                    reaped = bool(waited_pid)
                except ChildProcessError:
                    reaped = True
                    wait_status = None
                if reaped:
                    break
                time.sleep(0.05)
            if not reaped:
                self.log('reap_timeout', {'pid': pid, 'after_signal': 'SIGTERM'})
                try:
                    os.killpg(pid, signal.SIGKILL)
                except OSError as error:
                    self.log('killpg_error', {'pid': pid, 'signal': 'SIGKILL', 'error': repr(error)})
                end = time.monotonic() + 2
                while time.monotonic() < end:
                    self.drain_exit_output(child)
                    try:
                        waited_pid, wait_status = os.waitpid(pid, os.WNOHANG)
                        reaped = bool(waited_pid)
                    except ChildProcessError:
                        reaped = True
                        wait_status = None
                    if reaped:
                        break
                    time.sleep(0.05)
            if not reaped:
                self.log('reap_timeout', {'pid': pid, 'after_signal': 'SIGKILL'})
            os.close(child['fd'])
            self.log('child_stop', {'pid': pid, 'reaped': reaped,
                                    'waitpid_status': wait_status if reaped else None})
        os.close(self.fd)

    def drain_exit_output(self, child):
        for _ in range(20):
            if not select.select([child['fd']], [], [], 0)[0]:
                return
            try:
                data = os.read(child['fd'], 65536)
            except OSError:
                return
            if not data:
                return
            self.record_screen(child, data)


def parser(name):
    import argparse
    result = argparse.ArgumentParser(description=name)
    result.add_argument('--deadline', type=int, default=300)
    return result


def command(run, args, timeout=20, env=None):
    run.check_time()
    result = subprocess.run(args, cwd=str(run.cwd), env=env, capture_output=True,
                            text=True, timeout=min(timeout, max(1, run.deadline-time.monotonic())))
    return {'returncode': result.returncode, 'stdout': result.stdout, 'stderr': result.stderr}
